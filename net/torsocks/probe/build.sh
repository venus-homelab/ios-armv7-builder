#!/bin/bash
# Cross-build the torsocks feasibility probe (dylib + host) for armv7 iOS.
#
# The probe answers the torsocks lifeline question BEFORE any porting work:
#   does DYLD_INSERT_LIBRARIES (± DYLD_FORCE_FLAT_NAMESPACE, the mechanism
#   torsocks's own wrapper uses on Darwin) inject a library into a plain
#   armv7 binary on iOS 10.3.3, and under which signing state?
#
# Products are UNSIGNED by design; the device-side matrix script
# (devtest.sh) creates signed variants with the ON-DEVICE ldid (the
# host-side ldid signature is known untrusted on this target -- caddy
# postinst comment), so every signing state is produced where the kernel
# policy actually judges it.
#
# Products land in tmp/torsocks-probe/ (NOT out/ -- this is feasibility
# evidence, not a pool deliverable).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
WORK="$root/tmp/torsocks-probe"

export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}"
[ -x "$IOS_LD64" ] || { echo "missing IOS_LD64 (bootstrap-toolchain.sh)" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
CC="$root/tools/cc-wrapper.sh"

mkdir -p "$WORK"
# cc-wrapper's link mode derives intermediate .o paths from the source path
# (src.c -> src.o, absolute), so compile from COPIES inside $WORK -- keeps
# the probe source dir clean (first run littered probe/*.o, deleted 2026-11-25)
cp "$here/probe-lib.c" "$here/probe-host.c" "$WORK/"
cd "$WORK"
"$CC" -Wall -o libprobe.dylib -dynamiclib \
    -Wl,-install_name,libprobe.dylib probe-lib.c
"$CC" -Wall -o probe-host probe-host.c
echo "==> $WORK/{probe-host,libprobe.dylib} (unsigned)"
