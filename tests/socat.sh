#!/bin/bash
# tests/socat.sh -- device acceptance (README: TCP relay into dropbear
# verified).  Loopback relay probe: socat echoes a line through a
# listener+connector pair, both cleaned up afterwards.
source "$(dirname "$0")/lib.sh"
S=/var/mobile/tools/socat/socat
expect_ver "socat: version" "$S -V 2>&1 | head -1" "socat by Gerhard Rieger"
expect_out "socat: loopback relay roundtrip" \
    "$S -T 3 TCP-LISTEN:39999,reuseaddr EXEC:cat & sleep 1; echo relay-ok | $S -T 3 - TCP:127.0.0.1:39999 2>/dev/null; kill %1 2>/dev/null" \
    "relay-ok"
summary socat
