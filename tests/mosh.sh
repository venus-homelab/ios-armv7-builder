#!/bin/bash
# tests/mosh.sh -- device acceptance for the mosh package (README: Termius
# verified).  Offline-safe: version + the client's help path.
source "$(dirname "$0")/lib.sh"
M=/var/mobile/tools/bin/mosh-client
expect_ver "mosh: client version" "$M --version 2>&1 | head -1" "mosh-client (mosh 1.4.0)"
expect_rc0 "mosh: server binary present" "test -x /var/mobile/tools/bin/mosh-server"
summary mosh
