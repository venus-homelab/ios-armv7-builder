#!/bin/bash
# tests/whois.sh -- device acceptance for the whois package (README: the
# cleanest port, zero patches).  The device has no outbound internet, so
# the deterministic probe is the usage banner; the live registry query is
# a NETWORK-dependent case and stays out (see proxychains-e2e for the
# loopback pattern).
source "$(dirname "$0")/lib.sh"
W=/var/mobile/tools/bin/whois
expect_out "whois: usage banner" "$W 2>&1 | head -1" "Usage: whois"
summary whois
