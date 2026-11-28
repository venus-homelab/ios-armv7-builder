#!/bin/bash
# tests/w.sh -- device acceptance for the w4 package (w only; the stock
# /usr/bin/uptime is NOT ours).
# README table: our header must byte-match the stock adv_cmds uptime line
# (docs/w.md format ruling); login rows appear when utmpx holds
# USER_PROCESS entries (interactive pty sessions; neither sshd writes
# utmpx for plain command-exec sessions -- tools/probes/probe-w.c), so
# the row case self-skips when there is nothing to assert.
source "$(dirname "$0")/lib.sh"

expect_rc0 "w: runs clean" "/usr/bin/w >/dev/null"
expect_out "w: header carries load average" "/usr/bin/w" "load average"
expect_out "w: header matches stock uptime" \
    'a="$(/usr/bin/w | head -1)"; b="$(/usr/bin/uptime)"; [ "$a" = "$b" ] && echo SAME' \
    "SAME"

# Login-row reality depends on utmpx USER_PROCESS entries at probe time.
# tail -n +3: line 1 is the uptime header, line 2 the column header --
# counting line 2 would fake a "row" even with zero sessions.
if dev_up; then
    n="$(devc "/usr/bin/w | tail -n +3 | wc -l" 2>/dev/null || echo 0)"
    case "$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    if [ "$n" -gt 0 ]; then
        expect_out "w: login rows carry all 6 columns" \
            "/usr/bin/w | tail -n +3 | awk 'NF>=6{c++} END{print c+0}'" \
            "$n"
    else
        skip "w: login rows (no utmpx USER_PROCESS entries at probe time; see docs/w.md)"
    fi
fi

summary w
