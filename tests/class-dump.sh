#!/bin/bash
# tests/class-dump.sh -- device acceptance for the class-dump package
# (README: the real-SDK breakthrough, 3.5.2).
source "$(dirname "$0")/lib.sh"
C=/var/mobile/tools/bin/class-dump
expect_out "class-dump: usage banner" "$C 2>&1 | head -1" "class-dump"
summary class-dump
