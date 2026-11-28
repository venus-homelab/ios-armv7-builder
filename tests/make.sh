#!/bin/bash
# tests/make.sh -- device acceptance for the make4 package (README: the
# device-side rebuild story).
source "$(dirname "$0")/lib.sh"
M=/var/mobile/tools/bin/make
expect_ver "make: version" "$M --version | head -1" "GNU Make 4.4.1"
expect_out "make: real rule run" "cd /tmp && printf 'a.txt:\n\t@echo built-ok\n' > Mk.mk && $M -f Mk.mk a.txt 2>&1 && rm -f Mk.mk" "built-ok"
summary make
