#!/bin/bash
# tests/lsof.sh -- libproc route (4.99.7-2, SDK rebuilt, device verified).
source "$(dirname "$0")/lib.sh"
L=/var/mobile/tools/lsof
expect_ver "lsof: version" "$L -v 2>&1 | head -3" "4.99.7"
expect_rc0 "lsof: lists a pid" "$L -p \$$ >/dev/null 2>&1"
summary lsof
