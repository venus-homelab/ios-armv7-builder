#!/bin/bash
# build.sh -- compile netstat.c (the self-contained source, previously a
# ~/scratch hand build) into the repo-root out/.  The kernel ABI offsets
# are baked into the source as static asserts (docs/netstat.md §3.7), so
# the compile is one TU with no configure.
#
# The sysctl struct offsets were measured on the device (2026-11-13) and
# cross-checked against lsof; if iOS ever changes them the static asserts
# fail the build loudly instead of printing garbage.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
SDK="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
export IOS_SYSROOT="$SDK"
export IOS_LD64="${IOS_LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}"
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
CC="$root/tools/cc-wrapper.sh"
mkdir -p "$OUT"

# the hand-rolled sysctl structs need the BSD net headers the SDK lacks;
# they live next to the source (include/)
# the SDK lacks net/route.h entirely; the overlay's copy is a MUSL-FLAVORED
# correction (includes <features.h>) and cannot mix with the SDK.  Use the
# RAW xnu headers through the verified fetch path (the same lock rows
# libpcap consumes), staged into a private include dir.
NETINC="$root/tmp/netstat-inc"
rm -rf "$NETINC"
mkdir -p "$NETINC/net"
for row in xnu-route.h xnu-if-arp.h xnu-if-types.h; do
    key="$row"
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock "$key")"
    hdr="$("$root/tools/fetch-src.sh" "$key" "$U" "$SHA")"
    cp "$hdr" "$NETINC/net/${row#xnu-}"
done
INC="-I$here/include -I$NETINC -I$root/tools/sysroot/libproc"
[ -d "$here/include" ] || INC=""
$CC -O2 -Wall -o "$OUT/netstat-1.0-armv7" "$here/netstat.c" $INC
ldid -S "$OUT/netstat-1.0-armv7"
echo "==> $OUT/netstat-1.0-armv7"
