#!/bin/bash
# Build Privoxy 4.1.0 (non-caching filtering HTTP proxy, ijbswa) for armv7
# iOS 10.x on Linux (SDK sysroot mode).
#
# Purpose on the device: local HTTP entry point -> upstream SOCKS5, covering
# the proxychains __RESTRICT blind spot.  Everything the proxy needs is
# statically embedded; the binary's only dynamic dependency is libSystem.
#
# configure package whose upstream tarball ships NEITHER a generated
# `configure` NOR config.h.in -- only configure.in (autoconf must run on the
# build host; automake is NOT involved, GNUmakefile.in is hand-written).
# Recipe glued from the accumulated walls:
#
#   * PCRE2 (hard configure requirement: "Failed to detect pcre2 library."
#     otherwise).  The privoxy tarball does NOT bundle pcre2, so we build a
#     PRIVATE static pcre2 from sources.lock's existing nmap 7.95 bundled
#     libpcre -- the nginx/build.sh recipe in a privoxy-owned tree.  Both
#     libpcre2-8 AND libpcre2-posix archives are provided because configure
#     bakes `-lpcre2-8 -lpcre2-posix` into LIBS unconditionally when pcre2
#     is found; a missing -l archive is a hard ld64 error (no dynamic_lookup
#     rescue for library files, only for symbols).  The private tree exists
#     because pointing a consumer at another build's tree invites a `make
#     distclean` massacre (nginx wall 2), and because a warm tree built
#     with other CFLAGS smuggles -g stabs into our link (tig wall 3.3 --
#     ld64 absolutizes OSO paths).  CFLAGS="-O2" here, and byte-ab --fresh
#     wipes the ABI dir for a fair A/B.
#   * zlib (FEATURE_ZLIB: decompress gzip/deflate responses BEFORE filtering;
#     without it privoxy cannot filter compressed content).  curl/build.sh's
#     zlib recipe in a privoxy-private tree, static libz.a -> zero runtime
#     deps.  NOTE: configure's AC_CHECK_LIB(z, ...) probe is trivially true
#     under -undefined dynamic_lookup (toolchain.md §8) -- the REAL gate is
#     that we supply zlib.h via CPPFLAGS and the archive via -L; the build
#     would otherwise bake -lz in and fail at link time (or worse, at
#     device launch if a wrong libz resolved).  --enable-compression
#     (re-compress output) is deliberately NOT enabled: one more feature to
#     validate on the device for little local-proxy benefit.
#   * https-inspection is OFF: upstream needs a TLS backend via explicit
#     --with-{mbedtls,openssl,wolfssl} (default no).  Asserted below by
#     grepping config.h.  Future work: link the repo's static openssl4
#     (docs/openssl.md consumers' convention) with --with-openssl and enable
#     FEATURE_HTTPS_INSPECTION; NOT this round (task decision).
#   * JIT off: --disable-pcre-jit-compilation (pcrs would mmap RWX memory on
#     iOS, a fragile place to be for a long-running daemon; interpretive
#     matching is plenty for ad filtering).
#   * user/group: --with-user/--with-group validate against the BUILD host's
#     /etc/passwd (meaningless cross-compiling) and only feed `make install`
#     init scripts, which we do not use -- manual staging instead, so both
#     are simply not passed.
#   * gethostbyname_r: iOS libSystem has no _r resolver variant (device-
#     verified absent from every tbd/verified list).  The link probe is
#     trivially true under dynamic_lookup, so seed ac_cv_func_gethostbyname_r=no
#     (seed = conclusion, tig wall 3.2); jbsockets.c falls back to plain
#     gethostbyname, which IS in the device whitelist.
#   * Paths: the binary finds its config via a CWD-relative default
#     ("./config") or an explicit argv path; confdir/logdir/templdir are
#     RUNTIME config-file directives, not compile-time constants -- so the
#     deb ships an edited `config` with absolute payload paths and the
#     daemon is started with the explicit config path (see make-deb.sh and
#     docs/privoxy.md §5).  Nothing is baked into /etc or /usr/share.
#
# Determinism: CFLAGS="-O2" everywhere (no -g -> no OSO stabs for ld64 to
# absolutize, quickjs/tig walls).  autoheader/autoconf output is timestamp-
# free.  LC_UUID: no suppression flag -- tig's double-link probe showed this
# ld64 emits stable UUIDs on identical input; byte-ab has the final word.
#
# Usage: ./build.sh          # output ../out/privoxy-<ver>-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"

PRIVOXY_VERSION="${PRIVOXY_VERSION:-4.1.0}"
SRC="${PRIVOXY_SRC:-$root/tmp/src/privoxy-$PRIVOXY_VERSION-stable}"
PCRE2ABI="$root/tmp/privoxy-pcre2-abi"
ZLIBABI="$root/tmp/privoxy-zlib-abi"
PREFIX="${PREFIX:-/var/mobile/tools/privoxy}"
JOBS="${JOBS:-$(nproc)}"
CC="$root/tools/cc-wrapper.sh"

# SDK sysroot (toolchain.md §16/§23), same defaults as tig/build.sh
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ---------------------------------------------------------------------------
# 1. private static pcre2 (libpcre2-8 + libpcre2-posix), seeded from nmap's
#    sources.lock-locked bundled libpcre (no new download, no bare clone).
# ---------------------------------------------------------------------------
if [ ! -f "$PCRE2ABI/lib/libpcre2-8.a" ] || [ ! -f "$PCRE2ABI/lib/libpcre2-posix.a" ]; then
    P2SRC="$root/tmp/src/privoxy-pcre2"
    read -r NU NSHA _ <<<"$("$root/tools/fetch-src.sh" --lock nmap)"
    ntar="$("$root/tools/fetch-src.sh" nmap "$NU" "$NSHA")"
    seed="$root/tmp/src/privoxy-pcre2-seed"
    rm -rf "$P2SRC" "$seed"
    mkdir -p "$P2SRC" "$seed" "$root/tmp/src"
    tar -C "$seed" -xf "$ntar" --wildcards "nmap-*/libpcre"
    pcre_tree="$(ls -d "$seed"/nmap-*/libpcre 2>/dev/null | head -1)"
    [ -n "$pcre_tree" ] && [ -f "$pcre_tree/configure" ] || {
        echo "could not extract bundled libpcre from the nmap tarball" >&2; exit 1; }
    cp -a "$pcre_tree/." "$P2SRC/"
    rm -rf "$seed"
    ( cd "$P2SRC" \
      && CC="$CC" AR="$root/tools/darwin-ar" RANLIB="$root/tools/darwin-ranlib" \
         CFLAGS="-O2" \
         ./configure --host=armv7-apple-darwin --prefix=/var/mobile/tools \
                     --disable-shared --enable-static --disable-cpp >/dev/null \
      && touch aclocal.m4 configure Makefile.in src/config.h.in m4/*.m4 2>/dev/null \
      && sleep 1 && touch aclocal.m4 configure Makefile.in src/config.h.in \
      && make -j"$JOBS" libpcre2-8.la libpcre2-posix.la >/dev/null )
    # ld64 silently ignores GNU-format archives (toolchain.md §2): repack the
    # libtool objects into Darwin flat archives.  Object layout differs
    # between libtool generations (src/.libs/*.o vs .libs/*.o), so discover,
    # sort, and fail loudly on nothing-found instead of trusting a glob.
    mkdir -p "$PCRE2ABI/lib" "$PCRE2ABI/include"
    p8="$(find "$P2SRC" -name '*pcre2*.o' ! -name '*posix*' | LC_ALL=C sort -u)"
    pp="$(find "$P2SRC" -name '*pcre2posix*.o' | LC_ALL=C sort -u)"
    [ -n "$p8" ] || { echo "no pcre2 8-bit objects found under $P2SRC" >&2; exit 1; }
    [ -n "$pp" ] || { echo "no pcre2posix object found under $P2SRC" >&2; exit 1; }
    # object lists are newline/space separated
    # shellcheck disable=SC2086
    "$root/tools/darwin-ar" rcs "$PCRE2ABI/lib/libpcre2-8.a.new" $p8
    [ "$("$root/tools/darwin-ar" t "$PCRE2ABI/lib/libpcre2-8.a.new" | wc -l)" -gt 10 ] \
        || { echo "libpcre2-8.a repack produced suspiciously few members" >&2; exit 1; }
    # shellcheck disable=SC2086
    "$root/tools/darwin-ar" rcs "$PCRE2ABI/lib/libpcre2-posix.a.new" $pp
    [ "$("$root/tools/darwin-ar" t "$PCRE2ABI/lib/libpcre2-posix.a.new" | wc -l)" -eq 1 ] \
        || { echo "libpcre2-posix.a repack produced wrong member count" >&2; exit 1; }
    mv "$PCRE2ABI/lib/libpcre2-8.a.new" "$PCRE2ABI/lib/libpcre2-8.a"
    mv "$PCRE2ABI/lib/libpcre2-posix.a.new" "$PCRE2ABI/lib/libpcre2-posix.a"
    # pcre2.h is GENERATED by pcre2's configure from pcre2.h.in
    cp -f "$P2SRC/src/pcre2.h" "$PCRE2ABI/include/"
    cp -f "$P2SRC/src/pcre2posix.h" "$PCRE2ABI/include/"
fi
[ -f "$PCRE2ABI/include/pcre2.h" ] || { echo "missing $PCRE2ABI/include/pcre2.h" >&2; exit 1; }
echo "==> pcre2 abi ready: $(ls "$PCRE2ABI/lib")"

# ---------------------------------------------------------------------------
# 2. private static zlib (FEATURE_ZLIB) -- curl/build.sh recipe, own tree
# ---------------------------------------------------------------------------
if [ ! -f "$ZLIBABI/lib/libz.a" ]; then
    ZSRC="$root/tmp/src/privoxy-zlib-1.3.1"
    if [ ! -f "$ZSRC/libz.a" ]; then
        read -r ZU ZSHA _ <<<"$("$root/tools/fetch-src.sh" --lock zlib)"
        ztar="$("$root/tools/fetch-src.sh" zlib "$ZU" "$ZSHA")"
        # extract into a private seed dir: the tarball's top dir is
        # zlib-1.3.1, and tar-ing straight into tmp/src would clobber
        # curl's cached build tree of the same name
        rm -rf "$ZSRC" "$root/tmp/src/privoxy-zlib-seed"
        mkdir -p "$root/tmp/src/privoxy-zlib-seed"
        tar -C "$root/tmp/src/privoxy-zlib-seed" -xzf "$ztar"
        mv "$root/tmp/src/privoxy-zlib-seed/zlib-1.3.1" "$ZSRC"
        rm -rf "$root/tmp/src/privoxy-zlib-seed"
        ( cd "$ZSRC" \
          && CC="$CC" AR="$root/tools/darwin-ar" RANLIB="$root/tools/darwin-ranlib" \
             CHOST=armv7-apple-darwin CFLAGS="-O2" ./configure --static >/dev/null \
          && make -j"$JOBS" libz.a >/dev/null )
        "$root/tools/darwin-ar" rcs "$ZSRC/libz.a.new" "$ZSRC"/*.o
        [ "$("$root/tools/darwin-ar" t "$ZSRC/libz.a.new" | wc -l)" -gt 0 ] \
            || { echo "libz.a conversion produced 0 members" >&2; exit 1; }
        mv "$ZSRC/libz.a.new" "$ZSRC/libz.a"
    fi
    mkdir -p "$ZLIBABI/lib" "$ZLIBABI/include"
    cp -f "$ZSRC/libz.a" "$ZLIBABI/lib/"
    cp -f "$ZSRC/zlib.h" "$ZSRC/zconf.h" "$ZLIBABI/include/"
fi
[ -f "$ZLIBABI/include/zlib.h" ] || { echo "missing $ZLIBABI/include/zlib.h" >&2; exit 1; }
echo "==> zlib abi ready: $(ls "$ZLIBABI/lib")"

# ---------------------------------------------------------------------------
# 3. fetch the pinned release tarball (config-verified)
# ---------------------------------------------------------------------------
if [ ! -f "$SRC/jcc.c" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock privoxy)"
    tarball="$("$root/tools/fetch-src.sh" privoxy "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/configure.in" ] || { echo "privoxy source layout unexpected" >&2; exit 1; }

cd "$SRC"

# ---------------------------------------------------------------------------
# 4. generate config.h.in + configure (tarball ships neither; host autoconf,
#    no automake).  autoheader MUST run first: configure.in has an
#    interactive "Shall I run autoheader (y/n)?" branch when config.h.in is
#    missing, which would hang a non-tty build.
# ---------------------------------------------------------------------------
if [ ! -f config.h.in ]; then autoheader >/dev/null; fi
if [ ! -x configure ]; then autoconf >/dev/null 2>&1; fi
[ -x configure ] || { echo "configure generation failed (host autoconf?)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. configure in cross mode
# ---------------------------------------------------------------------------
CC="$CC" \
CFLAGS="-O2" \
CPPFLAGS="-I$PCRE2ABI/include -I$ZLIBABI/include" \
LDFLAGS="-L$PCRE2ABI/lib -L$ZLIBABI/lib" \
ac_cv_func_gethostbyname_r=no \
./configure --host=armv7-apple-darwin --prefix="$PREFIX" \
    --disable-pcre-jit-compilation

# configure verdicts are assertions, not hopes: pcre2 must have been really
# detected (header probes are compile-real under cross mode), zlib feature
# on, https-inspection off.
grep -q '^#define HAVE_PCRE2' config.h || { echo "HAVE_PCRE2 not defined -- pcre2 detection failed" >&2; exit 1; }
grep -q '^#define FEATURE_ZLIB' config.h || { echo "FEATURE_ZLIB not defined -- zlib detection failed" >&2; exit 1; }
grep -q '^#define DISABLE_PCRE_JIT_COMPILATION' config.h || { echo "JIT disable did not land" >&2; exit 1; }
if grep -q '^#define FEATURE_HTTPS_INSPECTION' config.h; then
    echo "FEATURE_HTTPS_INSPECTION unexpectedly on (TLS backend detected?)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. build.  `all` = PROGRAM + default.action (the default actions file is
#    generated host-side by stripping #MASTER# comment lines; deterministic).
#    No `make install` -- manual staging in make-deb.sh.
# ---------------------------------------------------------------------------
make -j"$JOBS"

BIN="$SRC/privoxy"
[ -f "$BIN" ] || { echo "privoxy was not built" >&2; exit 1; }
[ -f "$SRC/default.action" ] || { echo "default.action was not generated" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 7. post-link audit (the dynamic_lookup gate -- porting-flow.md §5).
#    Expected dependency set: libSystem ONLY (+ nothing else; pcre2 and zlib
#    are static archives).  Anything UNRESOLVED here maps back to a lying
#    link probe -> seed ac_cv_*=no and rebuild, never whitelist-bend.
# ---------------------------------------------------------------------------
otool -L "$BIN" 2>/dev/null || true
"$root/tools/check-undefined.sh" "$BIN"

mkdir -p "$root/out"
cp "$BIN" "$root/out/privoxy-$PRIVOXY_VERSION-armv7"
echo "==> $root/out/privoxy-$PRIVOXY_VERSION-armv7"
file "$root/out/privoxy-$PRIVOXY_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copy;"
echo "     config paths are runtime directives, deb ships an edited"
echo "     config with absolute payload paths; next: make-deb.sh)"
