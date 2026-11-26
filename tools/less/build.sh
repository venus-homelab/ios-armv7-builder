#!/bin/bash
# Build less v668 for armv7 iOS 10.x on Linux (SDK sysroot mode).
#
# Curses strategy -- same shape as the musl era, but every piece now lives
# where CI can see it:
#   * HEADERS: the iOS SDK ships no curses headers at all.  Without term.h,
#     less's configure probe calls tgetent(0,0) as an implicit declaration,
#     and modern clang makes implicit declarations a hard ERROR -- that is
#     the "Cannot find terminal libraries" wall (the link itself would pass:
#     cc-wrapper links with -undefined dynamic_lookup).  Fix: point CPPFLAGS
#     at the device-extracted ncurses 5.7 wide headers committed in
#     ncdu/devhdr (term.h declares the tgetent family).
#   * LINK: cc-wrapper drops -lncurses* from the link line outright
#     (cc-wrapper.sh discard list), and -undefined dynamic_lookup would leave
#     the binary with no LC_LOAD_DYLIB for libncursesw anyway.  So the device
#     dylib -- also committed, ncdu/devhdr/libncursesw.5.dylib -- is swapped
#     onto the link line explicitly: ld64 records
#     LC_LOAD_DYLIB /usr/lib/libncursesw.5.dylib, which the device provides.
#     Runtime terminfo comes from the device's /usr/share/terminfo.
#
# Source: the official release tarball via sources.lock (it ships the
#         pre-generated configure/funcs.h/help.c that the git tree lacks).
#
# Usage: ./build.sh          # output ../out/less-<ver>-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
LESS_VERSION="${LESS_VERSION:-668}"
SRC="${LESS_SRC:-$root/tmp/src/less-$LESS_VERSION}"
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

# 1. fetch the pinned release tarball
if [ ! -x "$SRC/configure" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock less)"
    tarball="$("$root/tools/fetch-src.sh" less "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -x "$SRC/configure" ] || { echo "less source layout unexpected (no configure)" >&2; exit 1; }

cd "$SRC"

# 2. configure in cross mode; DEVHDR makes the terminal-library probe
#    compile (term.h declarations) -- with -undefined dynamic_lookup the
#    probe's link then always "succeeds" and configure picks -lncursesw.
CC="$root/tools/cc-wrapper.sh" \
CFLAGS="-O2" \
CPPFLAGS="-I$DEVHDR" \
./configure --host=armv7-apple-darwin --prefix=/var/mobile/tools/less

# 3. curses: swap whatever curses -l flags configure picked for the device
#    dylib (cc-wrapper drops -lncurses*; a real .dylib on the link line
#    survives as an input and records the LC_LOAD_DYLIB -- the vim/ncdu
#    approach).
sed -i "s|-lncursesw|$NCDYLIB|g; s|-lncurses|$NCDYLIB|g; s|-lcurses|$NCDYLIB|g; s|-ltermcap|$NCDYLIB|g; s|-ltinfo|$NCDYLIB|g" Makefile
grep -n "^LIBS" Makefile | sed 's/^/    LIBS: /' || true

# 3.5. funcs.h is a generated file; the release tarball ships it, but keep
#      the git-tree fallback (grep the public declarations out of *.c).
[ -f funcs.h ] || grep -h '^public [^;]*$' ./*.c | sed 's/$/;/' > funcs.h

# 4. build + audit
make -j"$(nproc)"

BIN="$SRC/less"
[ -f "$BIN" ] || { echo "less was not built" >&2; exit 1; }
"$root/tools/check-undefined.sh" "$BIN"

mkdir -p "$root/out"
cp "$BIN" "$root/out/less-$LESS_VERSION-armv7"
echo "==> $root/out/less-$LESS_VERSION-armv7"
file "$root/out/less-$LESS_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copy;"
echo "     runtime terminfo comes from the device's /usr/share/terminfo)"
