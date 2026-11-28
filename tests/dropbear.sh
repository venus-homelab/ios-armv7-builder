#!/bin/bash
# tests/dropbear.sh -- device acceptance for the dropbear package (README:
# the device's actual sshd, port 22).  The running service IS this ssh
# session's transport -- probe it by listening port + binary identity,
# never by restarting it.
source "$(dirname "$0")/lib.sh"
expect_rc0 "dropbear: binary present" "test -x /var/mobile/tools/db-dropbear"
expect_out "dropbear: port 22 answers with SSH banner" \
    "(exec 3<>/dev/tcp/127.0.0.1/22 && head -c 20 <&3) 2>/dev/null | grep -c SSH" "1"
expect_rc0 "dropbear: sftp-server shipped" "test -x /var/mobile/tools/db-sftp-server"
summary dropbear
