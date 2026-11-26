#!/bin/bash
# tools/gate-local.sh -- the single local-gate entry point.
#
# 2026-11-25 audit item 7: this script used to be a WEAKER duplicate of the
# githooks battery (bash -n + shellcheck + sources.lock only), so two doors
# claimed to be "the local gate" and the weaker one could pass what the real
# one rejects.  It now delegates to the canonical chain: githooks/pre-push
# runs the pre-commit battery (doc-rot self-test, doc-rot, layout, matrix
# coverage, lock coverage, bash -n) plus the pool battery (sign-audit +
# pool-freshness over the real pool; both skip cleanly on a fresh checkout),
# and adds shellcheck at error level, which the hooks do not carry.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

rc=0
if command -v shellcheck >/dev/null; then
    echo "== shellcheck (error level), maintained scripts =="
    if ! shellcheck -S error $(git ls-files '*.sh' | grep -v '/src/'); then
        rc=1
    fi
else
    echo "   shellcheck not installed, skipped"
fi

echo "== githooks battery (pre-commit + pre-push) =="
if ! bash githooks/pre-push; then
    rc=1
fi

[ "$rc" = 0 ] && echo "GATE OK" || echo "GATE FAILED"
exit "$rc"
