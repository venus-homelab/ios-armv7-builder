#!/bin/bash
# tests/lz4.sh -- lz4 1.11.1 smoke (device-verified 2026-11-25; audit item 4/5).
source "$(dirname "$0")/lib.sh"
B=/var/mobile/tools/lz4/bin/lz4
expect_ver "lz4: version" "$B --version 2>&1 | head -1" "1.11.1"
expect_rc0 "lz4: aliases resolve" "/var/mobile/tools/lz4/bin/lz4c --version >/dev/null 2>&1 && /var/mobile/tools/lz4/bin/unlz4 --version >/dev/null 2>&1"
expect_rc0 "lz4: roundtrip" "echo lz4-rt > /tmp/lt.t && $B -q -f -9 /tmp/lt.t /tmp/lt.t.lz4 && $B -d -q -f /tmp/lt.t.lz4 /tmp/lt.t && grep -q lz4-rt /tmp/lt.t && $B -t /tmp/lt.t.lz4 && rm -f /tmp/lt.t /tmp/lt.t.lz4"
summary lz4
