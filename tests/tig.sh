#!/bin/bash
# tests/tig.sh -- tig 2.6.1 smoke (device-verified 2026-11-25; audit item 4/5).
source "$(dirname "$0")/lib.sh"
B=/usr/bin/tig
expect_ver "tig: version (reports device ncursesw too)" "$B --version 2>&1 | head -1" "tig version 2.6.1"
expect_ver "tig: ncursesw linkage live" "$B --version 2>&1 | tail -1" "ncursesw"
summary tig
