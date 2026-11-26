#!/bin/bash
# tests/dns.sh -- device acceptance for the dns4 package (dig/nslookup/host,
# one argv[0]-dispatched binary).  The device has no outbound internet: the
# deterministic probe is the usage banner of all three spellings.
source "$(dirname "$0")/lib.sh"
B=/var/mobile/tools/dns
expect_out "dns: dig banner"     "$B/dig 2>&1 | head -1" "dig"
expect_out "dns: nslookup banner" "$B/nslookup 2>&1 | head -1" "nslookup"
expect_out "dns: host banner"     "$B/host 2>&1 | head -1" "host"
summary dns
