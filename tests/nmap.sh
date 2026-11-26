#!/bin/bash
# tests/nmap.sh -- device acceptance for the nmap package (README: the
# most invasive port, 7.95).  Offline-safe: version + a localhost scan.
source "$(dirname "$0")/lib.sh"
N=/var/mobile/tools/nmap
expect_ver "nmap: version" "$N --version | head -1" "Nmap version 7.95"
expect_out "nmap: localhost scan finds ssh" "$N -p 22 --open 127.0.0.1 2>&1 | grep -c 'open'" "1"
summary nmap
