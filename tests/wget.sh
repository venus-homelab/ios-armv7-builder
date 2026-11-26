#!/bin/bash
# tests/wget.sh -- GNU Wget with the openssl self-subbuild; the -2 metadata
# (CA dependency) ships via republish, the binary version string is stable.
source "$(dirname "$0")/lib.sh"
W=/var/mobile/tools/wget
expect_ver "wget: version" "$W --version 2>&1 | head -1" "GNU Wget 1.25.0"
expect_out "wget: https-capable build" "$W --version 2>&1 | grep -c https" "1"
summary wget
