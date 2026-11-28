#!/bin/bash
# tests/ncdu.sh -- ncurses disk usage UI; the version banner is the
# deterministic probe (no TTY interaction in the suite).
source "$(dirname "$0")/lib.sh"
N=/var/mobile/tools/ncdu/ncdu
expect_out "ncdu: version banner" "$N --version 2>&1 | head -1" "1.20"
summary ncdu
