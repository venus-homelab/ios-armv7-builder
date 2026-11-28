#!/bin/bash
# tests/torsocks.sh -- device acceptance for the torsocks4 package.
# Read-only cases against the INSTALLED package (SKIP until torsocks4 is
# deployed; same case style as tests/proxychains.sh -- bare `ldid` head
# skips pre-deploy by the lib.sh not-installed heuristic, and passes once
# the signed dylib is in place).  The interposition mechanism itself was
# verified live on <device> before the deb existed: docs/torsocks.md §4,
# net/torsocks/probe/ (matrix + real-library E2E transcripts).
source "$(dirname "$0")/lib.sh"
T=/var/mobile/tools/torsocks
W=/var/mobile/tools/bin/torsocks

expect_ver "torsocks: wrapper version"     "$W --version" "Torsocks 2.5.0"
expect_rc0 "torsocks: show exports DYLD_INSERT" "$W show | grep -q 'DYLD_INSERT_LIBRARIES='"
expect_rc0 "torsocks: wrapper references its dylib" "grep -q 'libtorsocks' /var/mobile/tools/bin/torsocks"
expect_rc0 "torsocks: dylib is on-device signed" "ldid -e $T/lib/torsocks/libtorsocks.dylib >/dev/null"
expect_rc0 "torsocks: conf present, tor4 port"   "test -f $T/etc/tor/torsocks.conf && grep -q '^TorPort 9050' $T/etc/tor/torsocks.conf"

summary torsocks
