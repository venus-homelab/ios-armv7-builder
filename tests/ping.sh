#!/bin/bash
# tests/ping.sh -- device acceptance for the ping4 package (setuid root,
# SOCK_DGRAM ICMP delivery policy verified on device).  Loopback only.
source "$(dirname "$0")/lib.sh"
P=/usr/bin/ping
expect_out "ping: loopback roundtrip" "$P -c 1 -W 2000 127.0.0.1 2>&1 | tail -2 | head -1" "1 packets transmitted, 1 received"
summary ping
