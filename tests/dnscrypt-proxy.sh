#!/bin/bash
# tests/dnscrypt-proxy.sh -- dnscrypt-proxy 2.1.21 smoke (device-verified
# 2026-11-25: full DoH loop, see docs/dnscrypt-proxy.md §3).  The regression
# suite keeps to read-only checks: version, config sanity, mobile exec.
source "$(dirname "$0")/lib.sh"
B=/var/mobile/tools/dnscrypt-proxy/bin/dnscrypt-proxy
C=/var/mobile/tools/dnscrypt-proxy/etc/dnscrypt-proxy.toml
expect_ver "dnscrypt-proxy: version" "$B --version 2>&1 | head -1" "2.1.21"
expect_rc0 "dnscrypt-proxy: config sanity" "$B -config $C -check"
expect_rc0 "dnscrypt-proxy: binary executes as mobile" "test -x $B"
summary dnscrypt-proxy
