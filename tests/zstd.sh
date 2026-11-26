#!/bin/bash
# tests/zstd.sh -- zstd 1.5.7 smoke (device-verified 2026-11-25; audit item 4/5).
source "$(dirname "$0")/lib.sh"
B=/var/mobile/tools/zstd/bin/zstd
expect_ver "zstd: version" "$B --version 2>&1 | head -1" "v1.5.7"
expect_rc0 "zstd: aliases resolve" "unzstd --version >/dev/null 2>&1 && zstdcat --version >/dev/null 2>&1"
expect_rc0 "zstd: tar.zst roundtrip" "rm -rf /tmp/zt.a /tmp/zt.b /tmp/zt.t.tar.zst && mkdir -p /tmp/zt.a /tmp/zt.b && echo hello > /tmp/zt.a/a.txt && tar -C /tmp/zt.a -cf - . | $B -q -o /tmp/zt.t.tar.zst && $B -dcq /tmp/zt.t.tar.zst | tar -C /tmp/zt.b -xf - && cmp /tmp/zt.a/a.txt /tmp/zt.b/a.txt && rm -rf /tmp/zt.a /tmp/zt.b /tmp/zt.t.tar.zst"
summary zstd
