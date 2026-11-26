#!/bin/bash
# tests/proxychains-e2e.sh -- deterministic full-chain acceptance for the
# proxychains4 package (2026-11-23 backlog: "本地回环确定性验收").
#
# tests/proxychains.sh proves the chain is WALKED (dead-port test); this
# one proves it WORKS end to end without touching the internet:
#
#   1. this host runs a canned SOCKS5+HTTP endpoint (pc-e2e-server.py):
#      any CONNECT is answered with a known body, and the requested ATYP
#      is logged -- a DOMAIN target is the remote-DNS proof (the client
#      handed the proxy the NAME, not a resolved IP);
#   2. the device gets a throwaway proxychains.conf pointing at this
#      host's LAN address (written to /tmp, removed afterwards -- the
#      shipped config at /var/mobile/tools/proxychains/etc is untouched);
#   3. proxychains4 + the system curl fetch http://e2e.invalid/probe --
#      e2e.invalid does not exist anywhere, so a body can only come back
#      through the chain.
#
# Writes: /tmp/pc-e2e.conf on the device (removed at the end).  Reads: none.
source "$(dirname "$0")/lib.sh"
P=/var/mobile/tools/proxychains/bin/proxychains4

# the host address the device can reach: ask the device what address this
# host's ssh connection comes from ($SSH_CONNECTION's client field) --
# never hardcode a LAN address (AGENTS.md rule 3), and ssh -G's hostname
# is the DEVICE's own address, not ours.
HOST_IP=$(devc "echo \$SSH_CONNECTION" 2>/dev/null | awk '{print $1}')
[ -n "$HOST_IP" ] || { echo "cannot determine this host's address as seen by $IPAD_HOST" >&2; exit 1; }

PORT=39550
LOGF="$(mktemp)"
rm -f "$LOGF"
python3 "$(dirname "$0")/pc-e2e-server.py" "$PORT" "$LOGF" &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null; ssh $SSH_OPTS "$IPAD_HOST" "rm -f /tmp/pc-e2e.conf" 2>/dev/null' EXIT
sleep 1

# throwaway device config: chain = this host's SOCKS5, remote DNS on
devc "cat > /tmp/pc-e2e.conf <<'EOF'
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 10000
[ProxyList]
socks5 $HOST_IP $PORT
EOF"

expect_out "proxychains e2e: body via the chain" \
    "PROXYCHAINS_CONF_FILE=/tmp/pc-e2e.conf $P /bin/sh -c '/usr/bin/curl -s -m 10 http://e2e.invalid/probe'" \
    "PROXYCHAINS-E2E-OK"
# the remote-DNS proof lives on THIS host (the server's log), not the device
sleep 1
if grep -q 'DOMAIN:e2e.invalid' "$LOGF" 2>/dev/null; then
    pass "proxychains e2e: remote DNS (server saw DOMAIN:e2e.invalid)"
else
    fail "proxychains e2e: remote DNS (server log: $(tr '\n' ' ' < "$LOGF" 2>/dev/null || echo empty))"
fi

ssh $SSH_OPTS "$IPAD_HOST" "rm -f /tmp/pc-e2e.conf" 2>/dev/null
summary proxychains-e2e
