#!/bin/bash
# tests/go.sh -- device acceptance for the Go toolchain (TESTING ONLY per
# the doc: device-side go build; hello/goroutine/sort verified 2026-11-17).
source "$(dirname "$0")/lib.sh"
G=/var/mobile/tools/goroot/bin/go
expect_ver "go: version" "$G version 2>&1 | head -1" "go1.27.2"
expect_out "go: env GOARM" "$G env GOARM 2>&1" "7"
summary go
