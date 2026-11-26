#!/bin/bash
# scripts/tor-bridge-swap.sh -- swap the obfs4 bridges on the device's tor4
# and verify bootstrap, end to end.
#
# Usage:
#   scripts/tor-bridge-swap.sh <bridges-file>     # one "Bridge obfs4 ..." line each
#   curl -s <bridge source> | scripts/tor-bridge-swap.sh -
#
# The bridge lines are semi-sensitive (usable for a while, then dead):
# they are written ONLY to the device's torrc -- never commit them.
#
# What it does:
#   1. filters valid obfs4 Bridge lines from the input,
#   2. writes the full torrc (SocksPort + UseBridges + our obfs4proxy
#      transport + DataDirectory) to the device,
#   3. restarts tor as the mobile user,
#   4. watches the Bootstrapped progression for up to 90s and prints the
#      verdict (100% = working; otherwise the last reached phase).
#
# Env overrides (defaults match the shipped packages):
#   DEVICE      ssh alias for the device (default: ipad, mobile user)
#   ROOT_TARGET ssh target with root (default: root@ipad)
#   TOR_PREFIX  /var/mobile/tools/tor
#   PT_BIN      /var/mobile/tools/obfs4proxy/bin/obfs4proxy
set -euo pipefail

DEVICE="${DEVICE:-ipad}"
ROOT_TARGET="${ROOT_TARGET:-root@ipad}"
TOR_PREFIX="${TOR_PREFIX:-/var/mobile/tools/tor}"
PT_BIN="${PT_BIN:-/var/mobile/tools/obfs4proxy/bin/obfs4proxy}"
TORRC="$TOR_PREFIX/torrc"
DATA_DIR="$TOR_PREFIX/data"
LOG="/var/mobile/tmp/tor-bridged.log"

[ $# -ge 1 ] || { echo "usage: $0 <bridges-file | ->" >&2; exit 2; }
SRC="$1"

# ---- 1. collect valid obfs4 Bridge lines -----------------------------------
if [ "$SRC" = "-" ]; then
    BRIDGES=$(grep -E '^Bridge obfs4 ' || true)
else
    BRIDGES=$(grep -E '^Bridge obfs4 ' "$SRC" || true)
fi
N=$(printf '%s\n' "$BRIDGES" | grep -c . || true)
[ "${N:-0}" -ge 1 ] || { echo "no 'Bridge obfs4 ...' lines found in $SRC" >&2; exit 1; }
echo "== $N obfs4 bridge line(s) collected"

# ---- 2. build the torrc locally, push, fix ownership -----------------------
TMPRC=$(mktemp)
trap 'rm -f "$TMPRC"' EXIT
{
    echo "SocksPort 127.0.0.1:9050"
    echo "UseBridges 1"
    echo "ClientTransportPlugin obfs4 exec $PT_BIN"
    echo "DataDirectory $DATA_DIR"
    printf '%s\n' "$BRIDGES"
} > "$TMPRC"

scp -q "$TMPRC" "$ROOT_TARGET:$TORRC.new"
ssh "$ROOT_TARGET" "mkdir -p '$DATA_DIR' && mv '$TORRC.new' '$TORRC' && chown -R mobile:mobile '$TOR_PREFIX'"
echo "== torrc written to $TORRC ($(wc -l < "$TMPRC") lines)"

# ---- 3. restart tor as the mobile user --------------------------------------
ssh "$ROOT_TARGET" 'for p in $(pgrep -x tor); do kill -9 $p; done; sleep 1' 2>/dev/null || true
ssh "$DEVICE" "rm -f $LOG; nohup /var/mobile/tools/bin/tor -f $TORRC > $LOG 2>&1 &"
echo "== tor restarted (log: $LOG)"

# ---- 4. watch the Bootstrapped progression ---------------------------------
LAST="0% (starting)"
for i in $(seq 1 18); do
    sleep 5
    CUR=$(ssh "$DEVICE" "grep -a 'Bootstrapped' $LOG 2>/dev/null | tail -1" 2>/dev/null | grep -oP 'Bootstrapped \d+%[^)]*' | tail -1)
    [ -n "$CUR" ] || continue
    if [ "$CUR" != "$LAST" ]; then
        echo "  $CUR"
        LAST="$CUR"
    fi
    case "$CUR" in
        *"100%"*) echo "== VERDICT: BOOTSTRAP-100 -- bridges work"; exit 0;;
    esac
    # die early if the daemon is gone
    ssh "$DEVICE" "pgrep -x tor" >/dev/null 2>&1 || { echo "== VERDICT: tor DIED -- check $LOG"; exit 1; }
done
echo "== VERDICT: STUCK at $LAST -- bridges likely dead/blocked, fetch a fresh batch and rerun"
exit 1
