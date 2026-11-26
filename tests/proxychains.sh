#!/bin/bash
# tests/proxychains.sh -- device acceptance for the proxychains4 package.
# Claims verified 2026-11-22 on the device:
#   * usage banner (proxychains4 has no --version; bare invocation prints it);
#   * exec path works through the hook (echo via DYLD_INSERT, exit 0);
#   * dylib signature + config presence;
#   * the interposition itself -- a hooked curl to a dead port negotiates
#     the configured chain ("Strict chain ... 9050 ... timeout") instead of
#     failing directly; piped through tail so the rc is tail's (curl's 7
#     would otherwise mask the output assertion).
source "$(dirname "$0")/lib.sh"
P=/var/mobile/tools/proxychains/bin/proxychains4
LIB=/var/mobile/tools/proxychains/lib/libproxychains4.dylib

expect_out "proxychains: usage banner"  "$P 2>&1 | grep -c program_name" "1"
expect_out "proxychains: exec through hook" "$P /bin/echo hook-ok 2>&1" "hook-ok"
expect_rc0 "proxychains: dylib signed"   "ldid -e $LIB"
expect_rc0 "proxychains: config present" "test -f /var/mobile/tools/proxychains/etc/proxychains.conf"
expect_out "proxychains: interposition fires (chain walked)" \
    "$P /bin/sh -c '/usr/bin/curl -s -m 6 http://127.0.0.1:9/ 2>&1 | tail -1'" "Strict chain"

summary proxychains
