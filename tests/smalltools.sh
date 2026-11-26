#!/bin/bash
# tests/smalltools.sh -- tree/watch/realpath/hexdump, one binary dispatched
# by argv[0] (the central smalltools binary is the signed one).
source "$(dirname "$0")/lib.sh"
B=/var/mobile/tools/smalltools
expect_out "smalltools: realpath resolves" "$B/realpath /etc/hosts 2>&1" "/private/etc/hosts"
expect_out "smalltools: hexdump dispatch" "printf ab | $B/hexdump 2>&1 | head -1" "61 62"
expect_rc0 "smalltools: tree dispatch" "$B/tree -L 1 /var/mobile/tools >/dev/null 2>&1"
expect_rc0 "smalltools: watch dispatch" "test -x $B/watch"
summary smalltools
