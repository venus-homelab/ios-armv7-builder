#!/bin/bash
# tests/uuid.sh -- uuidgen (e2fsprogs libuuid route; replaces the BigBoss
# ossp-uuid that dyld-aborts on iOS 10.3.3).
source "$(dirname "$0")/lib.sh"
U=/var/mobile/tools/bin/uuidgen
expect_out "uuidgen: 37 bytes (36 + newline)" "$U | wc -c" "37"
expect_out "uuidgen: uuid shape" "$U | grep -icE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'" "1"
summary uuid
