#!/bin/bash
# tests/openssh.sh -- device acceptance for the openssh4 package (README:
# 10.6p2 on its own port 22226, com.hesper.osshd; does not touch the
# system sshd).  Read-only: banner + client identity.
source "$(dirname "$0")/lib.sh"
S=/var/mobile/tools/ossh-ssh
expect_ver "openssh: client version" "$S -V 2>&1 | head -1" "OpenSSH_10.6"
expect_out "openssh: 22226 answers with SSH banner" \
    "(exec 3<>/dev/tcp/127.0.0.1/22226 && head -c 20 <&3) 2>/dev/null | grep -c SSH" "1"
summary openssh
