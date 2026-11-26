#!/bin/bash
# tests/fzf.sh -- fzf 0.75.0 smoke (device-verified 2026-11-25; audit item 4/5).
source "$(dirname "$0")/lib.sh"
B=/var/mobile/tools/fzf/bin/fzf
expect_ver "fzf: version" "$B --version 2>&1 | head -1" "0.75.0"
expect_rc0 "fzf: filter mode without tty" "printf 'alpha\nbeta\ngamma\n' | $B --filter=ga | grep -qx gamma"
summary fzf
