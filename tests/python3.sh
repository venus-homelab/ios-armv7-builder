#!/bin/bash
# tests/python3.sh -- the 3.13/3.14 dual track + the pip milestone
# (ensurepip/_sysconfigdata/_scproxy shim, shipped in -6).
source "$(dirname "$0")/lib.sh"
expect_ver "python3: 3.13 version" "/var/mobile/tools/bin/python3 --version 2>&1 | head -1" "Python 3.13.18"
expect_ver "python3: 3.14 version" "/var/mobile/tools/bin/python3.14 --version 2>&1 | head -1" "Python 3.14"
expect_out "python3: pip entry (3.13)" "/var/mobile/tools/bin/python3 -m pip --version 2>&1 | head -1" "pip 26"
expect_out "python3: 3.14 own pip" "/var/mobile/tools/bin/python3.14 -m pip --version 2>&1 | head -1" "pip"
summary python3
