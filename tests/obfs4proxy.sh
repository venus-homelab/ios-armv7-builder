#!/bin/bash
# tests/obfs4proxy.sh -- device acceptance for the obfs4proxy4 package.
# Read-only cases against the INSTALLED package (SKIP until obfs4proxy4
# is deployed; same case style as tests/torsocks.sh).  The transport
# mechanism itself was verified live on <device> before the deb existed:
# docs/obfs4proxy.md §4, net/obfs4proxy/probe/e2e-20261125.log (loopback
# E2E: pt spawn -> CMETHOD -> RFC1929 cert args -> obfs4 -> host server
# -> canary, canned body verified).
source "$(dirname "$0")/lib.sh"
T=/var/mobile/tools/obfs4proxy
W=/var/mobile/tools/bin/obfs4proxy

expect_ver "obfs4proxy: version"           "$T/bin/obfs4proxy --version" "obfs4proxy-0.0.14"
expect_rc0 "obfs4proxy: on-device signed"  "ldid -e $T/bin/obfs4proxy >/dev/null"
expect_rc0 "obfs4proxy: entry symlink"     "test -x $W"
expect_rc0 "obfs4proxy: refuses w/o pt env" "$T/bin/obfs4proxy 2>/dev/null; rc=\$?; test \$rc -eq 1"

summary obfs4proxy
