#!/bin/bash
# tests/privoxy.sh -- privoxy 4.1.0 smoke (device-verified 2026-11-25; audit item 4/5).
source "$(dirname "$0")/lib.sh"
B=/var/mobile/tools/privoxy/bin/privoxy
expect_ver "privoxy: version" "$B --version 2>&1 | head -1" "4.1.0"
expect_rc0 "privoxy: config templates present" "test -f /var/mobile/tools/privoxy/etc/config && test -d /var/mobile/tools/privoxy/etc/templates"
summary privoxy
