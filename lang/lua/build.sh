#!/bin/bash
# Build Lua 5.4.7 (interpreter + compiler + static lib) for armv7 iOS 10.x
# on Linux (SDK sysroot mode).
#
# Lua is the easiest port in this repo: no configure, pure C89, zero
# external deps.  Decisions:
#   * no LUA_USE_POSIX / LUA_USE_READLINE: those drag popen/readline walls;
#     the interpreter is fully functional without them (io.popen still works
#     via the plain build -- it is libc popen, present on iOS).
#   * the static archive is repacked with tools/darwin-ar (GNU ar writes no
#     Darwin TOC -- see zsh/build.sh for the same wall with libiconv).
#   * luac compiles Lua source to portable bytecode; the cross-built luac
#     runs on the device like lua does.
#
# Source: official tarball via sources.lock (lua.org).
#
# Usage: ./build.sh          # outputs ../out/lua-<ver>-armv7 and
#                                 ../out/luac-<ver>-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
LUA_VERSION="${LUA_VERSION:-5.4.7}"
SRC="${LUA_SRC:-$root/tmp/src/lua-$LUA_VERSION}"

# SDK sysroot (toolchain.md §16/§23)
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 1. fetch the pinned tarball
if [ ! -f "$SRC/src/lua.h" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock lua)"
    tarball="$("$root/tools/fetch-src.sh" lua "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/src/lua.h" ] || { echo "lua source layout unexpected" >&2; exit 1; }

cd "$SRC"

# 2. build (vars propagate through the sub-make; liblua.a must be a Darwin
#    archive, hence darwin-ar/darwin-ranlib).  PLAT=generic: the default
#    "guess" target detects the HOST (Linux) and picks linux-noreadline,
#    whose SYSLDFLAGS=-Wl,-E reaches ld64 as -E ("unknown option").
make -j"$(nproc)" generic \
    CC="$root/tools/cc-wrapper.sh -std=gnu99" \
    AR="$root/tools/darwin-ar rcu" \
    RANLIB="$root/tools/darwin-ranlib" \
    MYCFLAGS="-O2" \
    MYLIBS="" >/dev/null

# 3. audit both executables
"$root/tools/check-undefined.sh" src/lua
"$root/tools/check-undefined.sh" src/luac

mkdir -p "$root/out"
cp src/lua "$root/out/lua-$LUA_VERSION-armv7"
cp src/luac "$root/out/luac-$LUA_VERSION-armv7"
echo "==> $root/out/lua-$LUA_VERSION-armv7"
echo "==> $root/out/luac-$LUA_VERSION-armv7"
file "$root/out/lua-$LUA_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copies;"
echo "     liblua.a + headers staged by make-deb.sh for embedders)"
