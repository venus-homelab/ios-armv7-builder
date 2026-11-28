#!/bin/bash
# tests/iperf3.sh -- device acceptance (offline-safe: version only; the
# bandwidth numbers need a peer, out of scope for a read-only suite).
source "$(dirname "$0")/lib.sh"
I=/var/mobile/tools/iperf3/iperf3
expect_ver "iperf3: version" "$I --version | head -1" "iperf 3.22.1"
summary iperf3
