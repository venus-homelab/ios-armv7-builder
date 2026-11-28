#!/bin/bash
# tests/git-lfs.sh -- git-lfs 3.8.1 smoke (device-verified 2026-11-25; audit item 4/5).
source "$(dirname "$0")/lib.sh"
B=/var/mobile/tools/git-lfs/bin/git-lfs
expect_ver "git-lfs: version" "$B version 2>&1 | head -1" "git-lfs/3.8.1"
expect_rc0 "git-lfs: env finds the device git" "PATH=/var/mobile/tools/bin:\$PATH $B env >/dev/null 2>&1"
summary git-lfs
