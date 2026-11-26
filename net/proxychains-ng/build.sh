#!/bin/bash
# Build proxychains-ng 4.18 for armv7 iOS 10.x on Linux (SDK sysroot mode).
#
# What it is: the LD_PRELOAD-family proxy hooker -- on Darwin via the
# NATIVE mechanism: src/libproxychains.c's DYLD_INTERPOSE block, injected
# into any dynamic binary with DYLD_INSERT_LIBRARIES (proxychains4 sets
# that env and execs the command).  Covers SOCKS4/5 + HTTP proxies and
# therefore the device's tor (SOCKS5 127.0.0.1:9050).
#
# iOS notes:
#   * the configure detects the darwin target through the COMPILER probe
#     (check_define __APPLE__ -- the wrapper targets armv7-apple-ios, so
#     __APPLE__ is defined): it picks LDSO_SUFFIX=dylib, -DIS_MAC=1 and
#     probes the linker itself (-install_name; --no-as-needed cleared).
#     No config.mak overrides needed.
#   * hooking LIMITATION shared by the whole LD_PRELOAD family: Apple's
#     own binaries (/usr/bin/ssh ...) carry __RESTRICT and dyld ignores
#     DYLD_INSERT for them; our self-built packages are hookable.
#   * MONTEREY_HOOKING must stay OFF (iOS 10.3.3's dyld predates it; the
#     configure only enables it when the macOS 12 min-version macro is
#     present, which our target never defines -- verified by reading
#     configure and by the device test).
#
# Source: official release asset via sources.lock (ships configure).
#
# Usage: ./build.sh   # outputs ../out/proxychains4-<ver>-armv7 (+ -daemon,
#                          + libproxychains4-<ver>-armv7; UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
PC_VERSION="${PC_VERSION:-4.18}"
SRC="${PC_SRC:-$root/tmp/src/proxychains-ng-$PC_VERSION}"

# SDK sysroot (toolchain.md §16/§23) -- NEW ports are SDK-mode (AGENTS.md 5)
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}"
[ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 1. fetch the pinned release asset (xz)
if [ ! -f "$SRC/configure" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock proxychains-ng)"
    tarball="$("$root/tools/fetch-src.sh" proxychains-ng "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xJf "$tarball"
fi
[ -f "$SRC/configure" ] || { echo "proxychains-ng source layout unexpected" >&2; exit 1; }

cd "$SRC"

# 2. configure: the install paths are DEVICE paths (proxychains4 computes
#    DYLD_INSERT_LIBRARIES from libdir at compile time; the conf file is
#    searched under sysconfdir and $HOME/.proxychains).
CC="$root/tools/cc-wrapper.sh" \
./configure \
    --prefix=/var/mobile/tools/proxychains \
    --libdir=/var/mobile/tools/proxychains/lib \
    --sysconfdir=/var/mobile/tools/proxychains/etc

grep -E '^LDSO_SUFFIX|^MAC_CFLAGS|^LD_SET_SONAME|^NO_AS_NEEDED' config.mak || true

# 3. build
make -j"$(nproc)" >/dev/null

# 4. audit all three products
"$root/tools/check-undefined.sh" proxychains4
"$root/tools/check-undefined.sh" proxychains4-daemon
"$root/tools/check-undefined.sh" libproxychains4.dylib

mkdir -p "$root/out"
cp proxychains4 "$root/out/proxychains4-$PC_VERSION-armv7"
cp proxychains4-daemon "$root/out/proxychains4-daemon-$PC_VERSION-armv7"
cp libproxychains4.dylib "$root/out/libproxychains4-$PC_VERSION-armv7"
echo "==> $root/out/proxychains4-$PC_VERSION-armv7 (+ daemon, + lib)"
file "$root/out/proxychains4-$PC_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copies;"
echo "     the dylib is injected with DYLD_INSERT_LIBRARIES by proxychains4)"
