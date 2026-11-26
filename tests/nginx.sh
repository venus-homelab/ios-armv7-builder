#!/bin/bash
# tests/nginx.sh -- device acceptance (README: kqueue engine + static
# OpenSSL; the daemon is DEACTIVATED on the device by choice -- config
# check only, no service start).
source "$(dirname "$0")/lib.sh"
N=/var/mobile/tools/nginx/bin/nginx
expect_ver "nginx: version" "$N -v 2>&1 | head -1" "nginx version: nginx/1.31.9"
expect_rc0 "nginx: config parses" "$N -t 2>&1 | grep -q 'syntax is ok'"
summary nginx
