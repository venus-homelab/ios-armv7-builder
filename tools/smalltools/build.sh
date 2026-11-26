#!/bin/bash
# Build smalltools (tree/watch/realpath/hexdump, one binary, argv[0] dispatch)
# for armv7 iOS 10.x.  SDK sysroot mode per the 2026-11-15 ruling.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
CC="$root/tools/cc-wrapper.sh"
mkdir -p "$OUT"
"$CC" -O2 -Wall -o "$OUT/smalltools-armv7" "$here/smalltools.c"
# the CENTRAL binary ships as the dispatcher -- it used to be the only
# unsigned payload member (2026-11-24 pool audit, smalltools4 1.0-1);
# sign + prove, no || true (the silent-failure rule)
ldid -S "$OUT/smalltools-armv7"
ldid -e "$OUT/smalltools-armv7" >/dev/null
for n in tree watch realpath hexdump; do
    cp "$OUT/smalltools-armv7" "$OUT/$n-armv7"
    ldid -S "$OUT/$n-armv7"
    ldid -e "$OUT/$n-armv7" >/dev/null
done
echo "==> $OUT/{tree,watch,realpath,hexdump}-armv7"
