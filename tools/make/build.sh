#!/bin/bash
# Build GNU make 4.4.1 for armv7 iOS 10.x on Linux.
#
# Device-side rebuilds of small projects without a round-trip to the host.
# Zero external deps (NLS off -- no gettext on the device; guile off).
#
# Source: https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz
#
# Usage: ./build.sh          # output ../out/make-<ver>-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
MAKE_VERSION="${MAKE_VERSION:-4.4.1}"
SRC="${MAKE_SRC:-$root/tmp/src/make-$MAKE_VERSION}"

[ -f "$SRC/configure" ] || {
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock make)"
    tarball="$("$root/tools/fetch-src.sh" make "$U" "$SHA")"
    rm -rf "$SRC"
    tar -C "$root/tmp/src" -xzf "$tarball"
}
[ -f "$SRC/configure" ] || { echo "make source layout unexpected" >&2; exit 1; }

# SDK sysroot (toolchain.md §16/§23)
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export LD_LIBRARY_PATH="${LD64_LIBS:-$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$SRC"
make distclean >/dev/null 2>&1 || true

# arscan.c includes <ar.h>, which the SDK does not ship.  Its BeOS/Android
# else-branch carries the same struct definitions (taken from GNU binutils) --
# route __APPLE__ into that branch instead of maintaining an ar.h copy.
sed -i 's|^# if !defined (__ANDROID__) \&\& !defined (__BEOS__) \&\& !defined(MK_OS_ZOS)$|#  if !defined (__ANDROID__) \&\& !defined (__BEOS__) \&\& !defined(MK_OS_ZOS) \&\& !defined(__APPLE__)|' src/arscan.c
grep -q '!defined(__APPLE__)' src/arscan.c || { echo "arscan.c ar.h sed did not match -- upstream changed?" >&2; exit 1; }

# eaccess: glibc 同义词（= faccessat/access），设备 libSystem 没有——
# 恒真探针会把它放进 gnulib findprog-in；压掉走 access 回退。
# （dynamic_lookup 恒真探针陷阱：见 toolchain.md §15）
#
# SDK mode: gnu-versions.h is GNU-only, so the cross-compile glob probe can
# never pass and make always compiles its bundled glob/glob.c -- which uses
# mempcpy (GNU extension, absent from the SDK's string.h; the CI run died on
# exactly that implicit declaration).  Force the system-glob answer: Apple's
# BSD glob covers everything make calls, and the bundled file is skipped.
#
# os-compat.h (force-included) declares mempcpy -- the exact function make's
# "options needed to detect all undeclared functions" probe uses as its
# undeclared target, so the probe finds nothing to detect and hard-errors.
# Pre-seed the answer it reaches without the header.
#
# (Keep every comment ABOVE this chain: a comment between a trailing
# backslash and the command word splits the prefix assignments off -- this
# has now bitten three build.sh files in one day.)
ac_cv_func_eaccess=no \
ac_cv_func_memrchr=no \
make_cv_sys_gnu_glob=yes \
ac_cv_c_undeclared_builtin_options=-Werror=implicit-function-declaration \
CC="$root/tools/cc-wrapper.sh" \
CFLAGS="-O2 -D_POSIX_VERSION=200809L -D_CS_PATH=1" \
./configure \
    --host=armv7-apple-darwin \
    --prefix=/var/mobile/tools/make \
    --disable-nls

# GNU ar 归档被 ld64 整体无视（"ignoring file ... building for iOS-armv7 but
# attempting to link with file built for iOS-armv7"——自相矛盾的警告，实为
# 归档格式问题，toolchain.md §2 同族坑）→ AR/RANLIB 必须 darwin 变体。
#
# The mempcpy compat (-include os-compat.h) is injected HERE, not into
# configure's CFLAGS: gnulib's GL_CFLAG_GNULIB_WARNINGS probe captures
# preprocessed header text into a variable when -include rides the probe
# compile, and the polluted flag list then explodes inside the recipe
# (observed: the whole typedef soup, glob-expanded, pasted into /bin/bash -c).
make -j"$(nproc)" AR="$root/tools/darwin-ar" RANLIB="$root/tools/darwin-ranlib" \
    CFLAGS="-O2 -D_POSIX_VERSION=200809L -D_CS_PATH=1 -include $here/os-compat.h"

BIN="$SRC/make"
[ -f "$BIN" ] || { echo "make was not built" >&2; exit 1; }
"$root/tools/check-undefined.sh" "$BIN"

mkdir -p "$root/out"
cp "$BIN" "$root/out/make-$MAKE_VERSION-armv7"
echo "==> $root/out/make-$MAKE_VERSION-armv7"
file "$root/out/make-$MAKE_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copy)"
