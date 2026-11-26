#!/bin/bash
# tests/p7zip.sh -- device acceptance for the p7zip17 package (17.05).
source "$(dirname "$0")/lib.sh"
Z=/var/mobile/tools/bin/7za
expect_ver "p7zip: version banner" "$Z 2>&1 | grep -c 'p7zip Version 17.05'" "1"
expect_out "p7zip: roundtrip archive" "cd /tmp && echo payload > .7z-probe && $Z a -bso0 .7z-probe.7z .7z-probe >/dev/null 2>&1 && rm -f .7z-probe && $Z e -bso0 -o/tmp .7z-probe.7z >/dev/null 2>&1 && cat /tmp/.7z-probe && rm -f /tmp/.7z-probe /tmp/.7z-probe.7z" "payload"
summary p7zip
