#!/bin/bash
# Host-side orchestration of the obfs4proxy loopback E2E.
#
#   e2e-run.sh --host-only      full loop inside the build host:
#     pt-driver-host -> obfs4proxy-host (client) --obfs4--> obfs4proxy-host
#     (server) -> canary
#   e2e-run.sh --device         the acceptance loop:
#     pt-driver-armv7 + out/obfs4proxy-<ver>-armv7 on <device> (temporary
#     scp'd copies, on-device ldid, no deb deploy) -> host obfs4proxy
#     server -> canary
#
# pt protocol in play (verified against obfs4proxy's own pt plumbing in
# goptlib v1.0.0, see docs/obfs4proxy.md §3):
#   client side  env TOR_PT_MANAGED_TRANSPORT_VER / TOR_PT_STATE_LOCATION /
#                TOR_PT_CLIENT_TRANSPORTS; stdout "VERSION 1",
#                "CMETHOD obfs4 socks5 <addr>", "CMETHODS DONE"
#   server side  env TOR_PT_SERVER_TRANSPORTS / TOR_PT_SERVER_BINDADDR /
#                TOR_PT_ORPORT; stdout "SMETHOD obfs4 <addr>
#                ARGS=cert=...,iat-mode=n", "SMETHODS DONE"
#
# Heavy artifacts live under $root/tmp (AGENTS.md rule 0: no host /tmp).
# Cleanup kills by recorded PID only (never pkill with a pattern that
# matches this script's own command line).
#
# Usage: e2e-run.sh [--host-only|--device]
#   E2E_HOSTADDR=ip  override the address the device connects to
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
WORK="$root/tmp/obfs4-e2e"
VER="${OBFS4_VERSION:-0.0.14}"
DEVICE="${IPAD_HOST:-ipad}"
DEVDIR="/var/tmp/obfs4-e2e"

MODE="--host-only"
[ $# -ge 1 ] && MODE="$1"
case "$MODE" in
    --host-only|--device) ;;
    *) echo "usage: $0 [--host-only|--device]" >&2; exit 2;;
esac

bash "$here/build.sh" >/dev/null
mkdir -p "$WORK"

SERVER_PORT="${E2E_SERVER_PORT:-$((20000 + RANDOM % 20000))}"
CANARY_PORT="${E2E_CANARY_PORT:-$((20000 + RANDOM % 20000))}"

# ---- assemble the obfs4 cert from the server statefile --------------------
# cert = base64(node-id(20B) || public-key(32B)) with the "==" suffix
# stripped (transports/obfs4/statefile.go: obfs4ServerCert.String()).
cert_from_state() { # <statefile>
    python3 - "$1" <<'PY'
import base64, json, sys
st = json.load(open(sys.argv[1]))
raw = bytes.fromhex(st["node-id"]) + bytes.fromhex(st["public-key"])
print(base64.b64encode(raw).decode().rstrip("="))
PY
}

HOSTADDR=""
if [ "$MODE" = "--device" ]; then
    if [ -n "${E2E_HOSTADDR:-}" ]; then
        HOSTADDR="$E2E_HOSTADDR"
    else
        # from the device's ssh session, field 1 is the address the device
        # sees the host coming from -- exactly what the device will dial
        HOSTADDR="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEVICE" 'echo $SSH_CONNECTION' | awk '{print $1}' | sed 's/^::ffff://')"
    fi
    [ -n "$HOSTADDR" ] || { echo "cannot determine host address for the device (set E2E_HOSTADDR)" >&2; exit 1; }
fi

LISTEN="127.0.0.1"
[ "$MODE" = "--device" ] && LISTEN="0.0.0.0"
BINDHOST="127.0.0.1"
[ "$MODE" = "--device" ] && BINDHOST="$HOSTADDR"

pids=()
cleanup() {
    for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$WORK/host-state" "$WORK/driver-state"
mkdir -p "$WORK/host-state"

# ---- canary target (TOR_PT_ORPORT slot) ------------------------------------
python3 "$here/canary-server.py" 127.0.0.1 "$CANARY_PORT" 2>"$WORK/canary.log" &
pids+=($!)

# ---- obfs4proxy server (host half of the loop) ------------------------------
env TOR_PT_MANAGED_TRANSPORT_VER=1 \
    TOR_PT_STATE_LOCATION="$WORK/host-state" \
    TOR_PT_SERVER_TRANSPORTS=obfs4 \
    TOR_PT_SERVER_BINDADDR="obfs4-$LISTEN:$SERVER_PORT" \
    TOR_PT_ORPORT="127.0.0.1:$CANARY_PORT" \
    "$WORK/obfs4proxy-host" -enableLogging -unsafeLogging -logLevel DEBUG \
    >"$WORK/host-server.out" 2>&1 &
pids+=($!)

for _ in $(seq 1 50); do
    grep -q "SMETHODS DONE" "$WORK/host-server.out" 2>/dev/null && break
    sleep 0.2
done
grep -q "SMETHODS DONE" "$WORK/host-server.out" || {
    echo "server never reported SMETHODS DONE:" >&2; cat "$WORK/host-server.out" >&2; exit 1; }
echo "== host server pt output:"; cat "$WORK/host-server.out"

CERT="$(cert_from_state "$WORK/host-state/obfs4_state.json")"
[ -n "$CERT" ] || { echo "empty cert from statefile" >&2; exit 1; }
echo "== cert: ${CERT:0:16}... (len ${#CERT})"

# ---- drive the loop ---------------------------------------------------------
DRIVER="$WORK/pt-driver-host"
# The SOCKS CONNECT target is the BRIDGE address (that is what tor sends
# for a `Bridge obfs4 <ip>:<port> cert=...` line): the obfs4 client dials
# it, the server relays the de-obfuscated stream to TOR_PT_ORPORT, and
# the canary sits there -- never in the SOCKS target.
TARGET="$BINDHOST:$SERVER_PORT"
if [ "$MODE" = "--device" ]; then
    # temporary on-device copies (NOT a deb deploy -- main agent installs);
    # signing follows the deploy three-pack rule (chmod/chown/on-device ldid)
    ssh -o BatchMode=yes "$DEVICE" "rm -rf '$DEVDIR' && mkdir -p '$DEVDIR/state'"
    scp -q -o BatchMode=yes "$WORK/pt-driver-armv7" \
        "$root/out/obfs4proxy-$VER-armv7" "$DEVICE:$DEVDIR/"
    ssh -o BatchMode=yes "$DEVICE" "chmod 755 '$DEVDIR/pt-driver-armv7' '$DEVDIR/obfs4proxy-$VER-armv7' && \
        chown mobile:mobile '$DEVDIR'/* 2>/dev/null; \
        [ -x '$DEVDIR/obfs4proxy-$VER-armv7' ] || exit 1; \
        ln -sf '$DEVDIR/obfs4proxy-$VER-armv7' '$DEVDIR/obfs4proxy'; \
        command -v ldid >/dev/null && ldid -S '$DEVDIR/pt-driver-armv7' '$DEVDIR/obfs4proxy' || true"
    DRIVER="$DEVDIR/pt-driver-armv7"
    rc=0
    ssh -o BatchMode=yes "$DEVICE" \
        "$DRIVER -obfs4proxy '$DEVDIR/obfs4proxy' -cert '$CERT' -iat 0 \
         -target '$HOSTADDR:$SERVER_PORT' -statedir '$DEVDIR/state' -obfs4log" \
        2>&1 | tee "$WORK/device-run.log" || rc=$?
    ssh -o BatchMode=yes "$DEVICE" "rm -rf '$DEVDIR'" || true
    [ "$rc" -eq 0 ] || { echo "== DEVICE LOOP FAILED (rc=$rc)" >&2; exit 1; }
    echo "== DEVICE LOOP OK (see $WORK/device-run.log)"
    exit 0
fi

# host-only: the whole loop on the build host
if "$DRIVER" -obfs4proxy "$WORK/obfs4proxy-host" -cert "$CERT" -iat 0 \
        -target "$TARGET" -statedir "$WORK/driver-state" -obfs4log \
        2>&1 | tee "$WORK/host-run.log"; then
    :
else
    echo "== HOST LOOP FAILED" >&2
    exit 1
fi
grep -q "PT-DRIVER PASS" "$WORK/host-run.log" || {
    echo "== HOST LOOP FAILED (no PASS marker)" >&2; exit 1; }
echo "== HOST LOOP OK (see $WORK/host-run.log)"
