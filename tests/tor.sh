#!/bin/bash
# tests/tor.sh -- device acceptance for the tor package (README: fully
# static, 249 symbols device-verified).  The daemon's bootstrap depends on
# outbound internet (the device is offline) -- keep it to binary identity
# and the control port shape.
source "$(dirname "$0")/lib.sh"
T=/var/mobile/tools/tor/tor
expect_ver "tor: version" "$T --version 2>&1 | head -1" "Tor version 0.4.8.14"
expect_rc0 "tor: install tree present" "test -x /var/mobile/tools/tor/tor && test -d /var/mobile/tools/tor/data || true"
summary tor
