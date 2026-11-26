#!/bin/bash
# tests/entr.sh -- entr 5.9 smoke (device-verified 2026-11-25; audit item 4/5).
source "$(dirname "$0")/lib.sh"
B=/usr/bin/entr
expect_ver "entr: release banner (no --version upstream)" "$B 2>&1 | head -1" "release: 5.9"
summary entr
