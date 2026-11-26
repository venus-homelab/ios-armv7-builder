#!/bin/bash
# Build tig 2.6.1 (jonas/tig, the git TUI) for armv7 iOS 10.x on Linux
# (SDK sysroot mode).
#
# tig is a configure package whose curses/iconv/readline story needs the
# repo's accumulated walls, so this script is mostly "whois + less + zsh"
# glued together:
#
#   * CURSES (the less/ncdu recipe): AX_WITH_CURSES probes ncursesw with a
#     headerless `char initscr(void)` LINK probe, and cc-wrapper drops
#     -lncurses* outright -- so the probe passes trivially and configure
#     bakes CURSES_LIBS=-lncursesw into config.make's LDLIBS.  The headers
#     come from the committed device-extracted ncurses 5.7 wide headers
#     (ncdu/devhdr, -I$DEVHDR); the LIBRARY is the committed device dylib
#     (ncdu/devhdr/libncursesw.5.dylib) swapped onto the link line so ld64
#     records LC_LOAD_DYLIB /usr/lib/libncursesw.5.dylib.  Runtime terminfo
#     comes from the device's /usr/share/terminfo.
#   * ICONV (the zsh recipe): tig's AM_ICONV is a HARD requirement (no
#     iconv -> configure AC_MSG_FAILURE).  Left alone, the probe "finds"
#     iconv in libc through -undefined dynamic_lookup and the calls land in
#     flat-namespace limbo -- and the device has NO libiconv.2.dylib at all
#     (zsh/build.sh proved it on-device; the SDK's libiconv.2.tbd is a
#     whitelist artifact, not a runtime file).  Fix: build static GNU
#     libiconv 1.17 first (sources.lock row shared with zsh), put ITS
#     iconv.h first in CPPFLAGS (GNU's header renames iconv_open/iconv/
#     iconv_close to the libiconv_-prefixed trio), and seed the cache with
#     am_cv_func_iconv=no so the probe takes the -liconv branch and resolves
#     against our static archive.  Result: zero iconv runtime deps, zero
#     undefined _libiconv_* symbols (asserted below).
#   * READLINE/PCRE: --without-readline (device has no libreadline; tig's
#     prompt falls back to plain getc -- all readline use is #ifdef'd) and
#     --without-pcre (the SDK has no pcre2posix.h anyway; explicit beats
#     accidental).
#   * wordexp/mkstemps: AC_CHECK_FUNCS link probes are always-true under
#     dynamic_lookup (toolchain.md §9), but neither symbol is in any device
#     whitelist (device-exports/ has no _wordexp/_mkstemps) and "白名单不许
#     绕".  Seed ac_cv_func_*=no: tig's compat/ has complete fallbacks
#     (compat_wordexp does tilde expansion only, exactly how tig uses it --
#     io.c constrains it to WRDE_NOCMD tilde expansion).  setenv/strndup
#     stay real (both in the curated libSystem.tbd AND the device-verified
#     list).  environ is in both too; execinfo.h/paths.h exist in the SDK.
#   * Docs: asciidoc/xmlto/docbook2pdf default to "false" in configure --
#     `make src/tig` never builds the man pages, nothing to escape.
#
# Determinism: CFLAGS="-O2" for both trees -- no -g means no OSO stabs for
# ld64 to absolutize (the quickjs -g0 wall, docs/tig.md WALL 2).  LC_UUID is
# handled in byte-ab (WALL 1 there).
#
# Source: the official release tarball via sources.lock (it ships the
#         pre-generated configure; the git tree needs autogen.sh).
#
# Usage: ./build.sh          # output ../out/tig-<ver>-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
TIG_VERSION="${TIG_VERSION:-2.6.1}"
SRC="${TIG_SRC:-$root/tmp/src/tig-$TIG_VERSION}"
NCDYLIB="${NCDYLIB:-$root/tools/ncdu/devhdr/libncursesw.5.dylib}"
DEVHDR="${DEVHDR:-$root/tools/ncdu/devhdr}"
ICONV_VERSION="${ICONV_VERSION:-1.17}"
IPREFIX="$root/tmp/iconv-prefix"

[ -s "$NCDYLIB" ] || { echo "missing $NCDYLIB (committed device dylib)" >&2; exit 1; }
[ -f "$DEVHDR/term.h" ] || { echo "missing $DEVHDR/term.h (committed device ncurses headers)" >&2; exit 1; }

# SDK sysroot (toolchain.md §16/§23)
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 1. static GNU libiconv (zsh/build.sh recipe verbatim): the device ships
#    NO libiconv.2.dylib, so tig's hard iconv requirement can only be met
#    statically.  Only libcharset + lib are built (srclib is for the
#    command-line tools we do not ship).  CFLAGS="-O2": autoconf would
#    otherwise default to "-g -O2" and the archive's stabs would absolutize
#    this build path into tig's binary (byte-ab wall -- see quickjs -g0).
if [ ! -f "$IPREFIX/lib/libiconv.a" ]; then
    ISRC="$root/tmp/src/libiconv-$ICONV_VERSION"
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock libiconv)"
    tarball="$("$root/tools/fetch-src.sh" libiconv "$U" "$SHA")"
    rm -rf "$ISRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
    ( cd "$ISRC" \
      && CC="$root/tools/cc-wrapper.sh" CFLAGS="-O2" ./configure --host=armv7-apple-darwin \
             --enable-static --disable-shared --prefix="$IPREFIX" \
      && make -C libcharset -j"$(nproc)" >/dev/null \
      && cp libcharset/include/localcharset.h lib/ \
      && make -C lib -j"$(nproc)" >/dev/null \
      && mkdir -p "$IPREFIX/include" "$IPREFIX/lib" \
      && cp include/iconv.h "$IPREFIX/include/" \
      && cp lib/.libs/libiconv.a "$IPREFIX/lib/" )
    # GNU libtool's ar wrote the archive WITHOUT a Darwin table of contents
    # -- ld64 rejects it ("archive has no table of contents").  Repack the
    # Mach-O members with darwin-ar (llvm-ar emits the darwin format for
    # Mach-O inputs automatically).
    ( cd "$IPREFIX/lib" && rm -rf .repack && mkdir .repack && cd .repack \
      && "$root/tools/darwin-ar" x ../libiconv.a \
      && rm -f ../libiconv.a \
      && "$root/tools/darwin-ar" cr ../libiconv.a *.o \
      && cd .. && rm -rf .repack )
fi
[ -f "$IPREFIX/lib/libiconv.a" ] || { echo "static libiconv build failed" >&2; exit 1; }

# 2. fetch the pinned release tarball
if [ ! -x "$SRC/configure" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock tig)"
    tarball="$("$root/tools/fetch-src.sh" tig "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -x "$SRC/configure" ] || { echo "tig source layout unexpected (no configure)" >&2; exit 1; }

cd "$SRC"

# 3. configure in cross mode.  The host pkg-config must never leak host
#    -I/-L (whois rule) -- but tig's AX_WITH_CURSES calls PKG_PROG_PKG_CONFIG
#    and HARD-FAILS ("pkg-config not found") when $PKG_CONFIG fails the
#    0.9.0 version handshake, which is exactly what /bin/false does.  So
#    hand it a fake that completes the handshake and then answers "module
#    not found" to every query: configure takes its STANDARD fallback
#    (headerless link probe -> -lncursesw), no host state involved.
fakepc="$root/tmp/tig-fake-pkg-config.sh"
cat > "$fakepc" <<'FAKEPC'
#!/bin/sh
case "$1" in
    --version|--atleast-pkgconfig-version) exit 0 ;;
esac
exit 1
FAKEPC
chmod +x "$fakepc"

# AM_ICONV cannot be steered under dynamic_lookup: probe 1 (iconv "in
# libc") links successfully no matter what, and seeding the result var with
# "no" makes configure SKIP the probes entirely and hard-fail (both rounds
# proved it).  So seed am_cv_func_iconv=yes (HAVE_ICONV=1 -- which is true:
# iconv comes from our static GNU archive via the header rename) and bind
# the archive onto the link line ourselves in step 4; the nm assertion in
# step 6 verifies the truth.  wordexp/mkstemps go to tig's own compat
# (their device symbols are not in any whitelist and the whitelist must not
# be bent).
CC="$root/tools/cc-wrapper.sh" \
CFLAGS="-O2" \
CPPFLAGS="-I$DEVHDR -I$IPREFIX/include" \
PKG_CONFIG="$fakepc" \
ac_cv_func_wordexp=no \
ac_cv_func_mkstemps=no \
am_cv_func_iconv=yes \
./configure --host=armv7-apple-darwin --prefix=/var/mobile/tools/tig \
    --without-readline --without-pcre

# 4. curses + iconv on the FINAL link.  -lncursesw would be silently
#    dropped by cc-wrapper, so it MUST become the device dylib (less
#    recipe).  configure never emits a libiconv reference at all (branch 1
#    adds no -l flag), so append the repacked static archive to LDLIBS
#    (LDLIBS = @LIBS@ @CURSES_LIBS@) -- guarded to stay idempotent across
#    re-runs of this script.
sed -i "s|-lncursesw|$NCDYLIB|g; s|-lncurses|$NCDYLIB|g; s|-lcurses|$NCDYLIB|g; s|-ltermcap|$NCDYLIB|g; s|-ltinfo|$NCDYLIB|g" config.make
ICONV_A="$IPREFIX/lib/libiconv.a"
if ! grep -q "libiconv.a" config.make; then
    sed -i "s|^LDLIBS *=\(.*\)$|LDLIBS =\1 $ICONV_A|" config.make
fi
grep -n "^LDLIBS\|^CFLAGS\|^CPPFLAGS" config.make | sed 's/^/    config.make: /'
grep -q "$NCDYLIB" config.make || { echo "curses dylib missing from LDLIBS" >&2; exit 1; }
grep -q "libiconv.a" config.make || { echo "libiconv.a missing from LDLIBS" >&2; exit 1; }

# 5. build only the real binary (`all` would also link test-graph and
#    doc-gen as armv7 dead weight; src/builtin-config.c is regenerated from
#    tigrc by the host-side sed script tools/make-builtin-config.sh)
make -j"$(nproc)" src/tig

BIN="$SRC/src/tig"
[ -f "$BIN" ] || { echo "tig was not built" >&2; exit 1; }

# 6. assertions: tig must depend on libSystem + libncursesw.5 ONLY.
#    - no undefined libiconv symbol: the static archive must have satisfied
#      them all (a leftover _libiconv_open would abort at device launch --
#      the device has no libiconv.2.dylib to resolve it from);
#    - the ncurses dylib must be a recorded load command, not a dropped flag.
if "$root/tools/llvm-nm" -u "$BIN" | grep -q libiconv; then
    echo "FAIL: undefined libiconv symbols remain (static iconv did not resolve):" >&2
    "$root/tools/llvm-nm" -u "$BIN" | grep libiconv >&2
    exit 1
fi
otool -L "$BIN" 2>/dev/null || true

# 7. post-link audit (the dynamic_lookup gate -- porting-flow.md §5)
"$root/tools/check-undefined.sh" "$BIN"

mkdir -p "$root/out"
cp "$BIN" "$root/out/tig-$TIG_VERSION-armv7"
echo "==> $root/out/tig-$TIG_VERSION-armv7"
file "$root/out/tig-$TIG_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copy;"
echo "     runtime terminfo comes from the device's /usr/share/terminfo;"
echo "     tig shells out to the device's git at runtime -- tig4 Depends git4)"
