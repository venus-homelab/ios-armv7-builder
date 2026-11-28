#!/bin/bash
# tests/tcpdump.sh -- device acceptance (README: -D lists en0, live capture
# needs root; keep it read-only: version + -D).
source "$(dirname "$0")/lib.sh"
T=/var/mobile/tools/tcpdump
expect_ver "tcpdump: version" "$T --version 2>&1 | head -1" "tcpdump version 4.99.5"
expect_out "tcpdump: -D lists en0" "$T -D 2>&1 | grep -c en0" "1"
summary tcpdump
