#!/bin/bash
# Build zsh 5.9 for armv7 iOS 10.x on Linux (SDK sysroot mode).
#
# Decisions:
#   * --disable-dynamic: the binary carries all modules (zle, complist,
#     zpty, ...) statically.  Dynamic modules would mean signed Mach-O
#     bundles dlopen-able from the install tree -- a farm of signing/path
#     walls for zero benefit on a single-user phone shell; static modules
#     are zsh's historical default anyway.
#   * Curses: zle (the line editor) needs term.h/tgetent.  Same recipe as
#     less/vim/mosh: CPPFLAGS -> ncdu/devhdr (committed device ncurses 5.7
#     wide headers), then the committed device dylib is swapped onto the
#     link line so ld64 records LC_LOAD_DYLIB /usr/lib/libncursesw.5.dylib
#     (cc-wrapper drops bare -lncurses*; a real .dylib input survives).
#     Runtime terminfo comes from the device's /usr/share/terminfo.
#   * --enable-multibyte: wchar support from the Darwin libc; UTF-8 locales
#     are the device default.
#   * fpath: --prefix=/var/mobile/tools/zsh bakes the functions dir; the
#     deb ships share/zsh/<ver>/functions (the completion system is
#     scripts, not modules -- without it zsh is only half a shell).
#
# Source: official release tarball via sources.lock (pre-generated
#         configure; the GitHub mirror tag needs Util/preconfig + yodl).
#
# Usage: ./build.sh          # output ../out/zsh-<ver>-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
ZSH_VERSION="${ZSH_VERSION:-5.9}"
ICONV_VERSION="${ICONV_VERSION:-1.17}"
SRC="${ZSH_SRC:-$root/tmp/src/zsh-$ZSH_VERSION}"
NCDYLIB="${NCDYLIB:-$root/tools/ncdu/devhdr/libncursesw.5.dylib}"
DEVHDR="${DEVHDR:-$root/tools/ncdu/devhdr}"

[ -s "$NCDYLIB" ] || { echo "missing $NCDYLIB (committed device dylib)" >&2; exit 1; }
[ -f "$DEVHDR/term.h" ] || { echo "missing $DEVHDR/term.h (committed device ncurses headers)" >&2; exit 1; }

# SDK sysroot (toolchain.md §16/§23)
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 1. auto-build static GNU libiconv.  The device ships NO libiconv.2.dylib
#    (iOS 10.3.3 removed it; not in the shared cache either -- the SDK's
#    libiconv.2.tbd names /usr/lib/libiconv.2.dylib but the file is not
#    there).  zsh calls iconv() internally (utils.c multibyte helpers on the
#    completion path -- without a library those calls sat in flat-namespace
#    limbo and compinit died with "Symbol not found: _iconv_open").
#    Statically linking GNU libiconv fixes it with zero runtime deps.  The
#    archive exports the libiconv_-prefixed trio and its iconv.h renames
#    calls to match -- so zsh must include THIS header, not the SDK's.
#    Only libcharset + lib are built (srclib is for the command-line tools
#    we do not ship).
IPREFIX="$root/tmp/iconv-prefix"
if [ ! -f "$IPREFIX/lib/libiconv.a" ]; then
    ISRC="$root/tmp/src/libiconv-$ICONV_VERSION"
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock libiconv)"
    tarball="$("$root/tools/fetch-src.sh" libiconv "$U" "$SHA")"
    rm -rf "$ISRC"
    tar -C "$root/tmp/src" -xzf "$tarball"
    ( cd "$ISRC" \
      && CC="$root/tools/cc-wrapper.sh" ./configure --host=armv7-apple-darwin \
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

# 2. fetch the pinned release tarball (xz)
if [ ! -x "$SRC/configure" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock zsh)"
    tarball="$("$root/tools/fetch-src.sh" zsh "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xJf "$tarball"
fi
[ -x "$SRC/configure" ] || { echo "zsh source layout unexpected (no configure)" >&2; exit 1; }

cd "$SRC"

# 3. configure in cross mode; DEVHDR makes the terminal-library probe
#    compile (term.h declarations) -- with -undefined dynamic_lookup the
#    probe's link always "succeeds" and configure picks a curses -l flag.
CC="$root/tools/cc-wrapper.sh" \
CFLAGS="-O2" \
CPPFLAGS="-I$DEVHDR -I$IPREFIX/include" \
LDFLAGS="-L$IPREFIX/lib" \
LIBS="$NCDYLIB" \
ac_cv_func_open_memstream=no \
ac_cv_func_getutent=no \
ac_cv_func_faccessx=no \
ac_cv_func_srand_deterministic=no \
ac_cv_func_canonicalize_file_name=no \
ac_cv_func_setproctitle=no \
ac_cv_search_setproctitle=no \
ac_cv_func_prctl=no \
ac_cv_search_prctl=no \
ac_cv_func_setresuid=no \
ac_cv_func_setresgid=no \
ac_cv_func_iconv=no \
./configure --host=armv7-apple-darwin --prefix=/var/mobile/tools/zsh \
    --disable-dynamic --enable-multibyte \
    --disable-sttyufmt --disable-maildir-support
# Pre-seeded, device-verified (dlsym MISS unless noted): open_memstream,
# getutent (device only has the utmpx family -- setutxent/getutxent/
# endutxent all OK), faccessx (cond.c ACC_SELF path, legacy Darwin API),
# srand_deterministic (plain srand fallback compiles in), setproctitle and
# prctl (jobs -Z falls back to the hackzero copy), setresuid/setresgid
# (openssh/dropbear precedent), canonicalize_file_name (glibc-only).
# iconv=no is HONEST for the device libc and forces configure down
# AC_CHECK_LIB(iconv, libiconv) -- which now finds our static archive.
# Without it the dynamic_lookup probe "finds" a device iconv that does not
# exist and the calls end in flat-namespace limbo.

# 4. curses: swap whatever curses -l flags configure picked for the device
#    dylib, in EVERY generated Makefile (Src + module subdirs).
find . -name Makefile -exec sed -i \
    "s|-lncursesw|$NCDYLIB|g; s|-lncurses|$NCDYLIB|g; s|-lcurses|$NCDYLIB|g; s|-ltermcap|$NCDYLIB|g; s|-ltinfo|$NCDYLIB|g" {} +
grep -h "^INSTLIB\|^LINKMOD\|^LIBS" Src/Makefile 2>/dev/null | head -3 || true

# 5. build; then put curses on the FINAL link.  configure's curses probe
#    was "won" by -undefined dynamic_lookup, so NO Makefile carries a
#    curses -l flag at all (nothing for a sed to swap, unlike less) and the
#    tgetent/boolcodes/... references stay in flat-namespace limbo -- the
#    device answered with "dyld: Symbol not found: _boolcodes".  Inject the
#    device dylib into Src/Makefile's LIBS (the binary link line) and force
#    the relink: make does not track lib changes (git EXTLIBS precedent),
#    so rm the binary.  HOST NOTE: the injection rides configure's LIBS env
#    (post-make Makefile edits get wiped by Makemod's regeneration -- one
#    wasted round proved it); if a HOST-side tool ever links with $(LIBS),
#    GNU ld will choke on the Mach-O and this needs a different carrier.
make -j"$(nproc)" >/dev/null
if ! grep -q 'devhdr' Src/Makefile; then
    echo "curses dylib missing from LIBS" >&2
    exit 1
fi

BIN="$SRC/Src/zsh"
[ -f "$BIN" ] || { echo "zsh was not built" >&2; exit 1; }

# 6. audit
"$root/tools/check-undefined.sh" "$BIN"

mkdir -p "$root/out"
cp "$BIN" "$root/out/zsh-$ZSH_VERSION-armv7"
echo "==> $root/out/zsh-$ZSH_VERSION-armv7"
file "$root/out/zsh-$ZSH_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copy;"
echo "     functions tree staged by make-deb.sh via make install.fns)"
