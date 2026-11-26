#!/bin/bash
# tests/patch.sh -- GNU patch (config.sub upgraded to know armv7-apple-ios).
# Payload is flat at /var/mobile/tools/patch/patch (no bin/ symlink).
source "$(dirname "$0")/lib.sh"
P=/var/mobile/tools/patch/patch
expect_out "patch: version banner" "$P --version 2>&1 | head -1" "GNU patch"
expect_out "patch: applies a diff" "printf 'a\n' > /tmp/.p-probe && printf 'a\nb\n' > /tmp/.p-want && diff -u /tmp/.p-probe /tmp/.p-want > /tmp/.p-diff; $P -s /tmp/.p-probe < /tmp/.p-diff && cat /tmp/.p-probe && rm -f /tmp/.p-probe /tmp/.p-want /tmp/.p-diff" "b"
summary patch
