#!/bin/bash
# tests/caddy.sh -- caddy 2.11.9 smoke (device-verified 2026-11-25; audit item 4/5).
source "$(dirname "$0")/lib.sh"
B=/var/mobile/tools/caddy/bin/caddy
expect_ver "caddy: version" "$B version 2>&1 | head -1" "v2.11.9"
expect_rc0 "caddy: binary executes as mobile" "test -x $B"
summary caddy
