#!/bin/bash
# tools/bootstrap-hooks.sh -- one-time hooks activation for a fresh clone.
#
# Why: core.hooksPath is repo-local config and is NOT part of history -- a
# fresh clone has no hooks, so the commit-content gates (doc-rot, layout,
# matrix coverage, lock coverage, bash -n) silently never run and "the local
# gate only exists on one machine" (2026-11-25 audit item 1).  Run this once
# after cloning:
#
#   tools/bootstrap-hooks.sh
#
# Idempotent.  The pre-commit hook also self-checks and warns when hooks are
# somehow disabled again.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
[ -d githooks ] || { echo "no githooks/ directory -- not the builder repo?" >&2; exit 1; }
git config core.hooksPath githooks
echo "hooks active: $(git config --get core.hooksPath) ($(ls githooks | paste -sd' '))"
