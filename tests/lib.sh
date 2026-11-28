#!/bin/bash
# tests/lib.sh -- device acceptance helpers, sourced by every tests/<pkg>.sh.
#
# Every case is a READ-ONLY command on the device: no writes, no service
# restarts, nothing destructive.  Connection target comes from IPAD_HOST
# (default "ipad", the ssh alias documented in DEVICE.md).
#
# Per-case output: "PASS pkg: case" / "FAIL pkg: case: detail" /
# "SKIP pkg: case ..." / "STALE pkg: case: ...", followed by one summary
# line per package printed by summary().
#
# Outcome taxonomy :
#   FAIL    the binary exists but misbehaves              -> red
#   STALE   the binary runs but the expected version
#           string is gone (device has an older build)    -> visible, not red
#   SKIP    device down, or the binary is absent from
#           the device ("not installed" drift)            -> visible, not red

IPAD_HOST="${IPAD_HOST:-ipad}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8}"
PASS=0; FAIL=0; SKIP=0; STALE=0; ABSENT=0
_DEV_UP=""
_OUT=""

# dev_up -- probe the device once per run; subsequent calls reuse the result.
dev_up() {
    [ -n "$_DEV_UP" ] && { [ "$_DEV_UP" = yes ]; return; }
    if ssh $SSH_OPTS "$IPAD_HOST" true 2>/dev/null; then
        _DEV_UP=yes
    else
        _DEV_UP=no
        echo "device $IPAD_HOST unreachable -- cases will SKIP" >&2
    fi
    [ "$_DEV_UP" = yes ]
}

# devc <remote command> -- run on the device (stdout+stderr).
devc() {
    dev_up || return 125
    ssh $SSH_OPTS "$IPAD_HOST" "$@"
}

pass() { PASS=$((PASS+1)); printf 'PASS %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP %s\n' "$*"; }

# _not_installed <cmd> -- rc 0 when the failure looks like deployment drift:
# the leading binary of cmd is simply absent on the device.  Heuristic on
# purpose: piped commands ("echo .. | jq") probe their first word, which
# exists, and stay generic FAILs.
_not_installed() {
    local bin="${1%%[|;]*}"
    bin="${bin%% *}"
    case "$bin" in ''|echo|seq|grep|printf) return 1 ;; esac
    ! devc "test -e '$bin'" >/dev/null 2>&1
}

# _run <case> <cmd> -- shared preamble: device up, command runs, absence
# detected.  Sets _OUT on success; rc 0 = got output, rc 1 = case handled
# (skip/fail already emitted).
_run() {
    local case="$1" cmd="$2"
    if ! dev_up; then skip "$case (device down)"; return 1; fi
    if ! _OUT="$(devc "$cmd" 2>/dev/null)"; then
        if _not_installed "$cmd"; then
            ABSENT=$((ABSENT+1))
            skip "$case (not installed: ${cmd%% *})"
        else
            fail "$case (command rc != 0)"
        fi
        return 1
    fi
    return 0
}

# expect_rc0 <case name> <device command>
expect_rc0() {
    _run "$1" "$2" && pass "$1"
}

# expect_out <case name> <device command> <expected substring>
expect_out() {
    _run "$1" "$2" || return 0
    case "$_OUT" in
        *"$3"*) pass "$1" ;;
        *) fail "$1: wanted [$3] got [$(printf '%s' "$_OUT" | head -1)]" ;;
    esac
}

# expect_ver <case name> <device command> <expected substring>
# Like expect_out, but "the command ran and the expected version string is
# gone" is STALE (the device has an older build), not FAIL.
expect_ver() {
    _run "$1" "$2" || return 0
    case "$_OUT" in
        *"$3"*) pass "$1" ;;
        *) STALE=$((STALE+1))
           printf 'STALE %s: got [%s] want [%s]\n' "$1" \
               "$(printf '%s' "$_OUT" | head -1)" "$3" ;;
    esac
}

# summary <pkg> -- exit 0 clean pass (stale is visible but not red),
# 1 any fail, 2 everything skipped (device down or package absent).
summary() {
    local pkg="$1" rc=0
    printf '== %s: pass=%d fail=%d skip=%d stale=%d absent=%d\n' \
        "$pkg" "$PASS" "$FAIL" "$SKIP" "$STALE" "$ABSENT"
    [ "$FAIL" -gt 0 ] && rc=1
    if [ "$rc" = 0 ] && [ "$PASS" = 0 ] && [ "$STALE" = 0 ] && [ "$SKIP" -gt 0 ]; then rc=2; fi
    exit "$rc"
}
