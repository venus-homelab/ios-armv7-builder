#!/bin/bash
# tests/rsync.sh -- device acceptance for the rsync package (README:
# incremental sync verified).
source "$(dirname "$0")/lib.sh"
R=/var/mobile/tools/bin/rsync
expect_ver "rsync: version protocol" "$R --version | head -1" "rsync  version 3.3.0"
expect_out "rsync: local copy roundtrip" "$R -a --delete /etc/hosts /tmp/.rsync-probe 2>&1 && cmp -s /etc/hosts /tmp/.rsync-probe && echo same && rm -f /tmp/.rsync-probe" "same"
summary rsync
