#!/bin/bash
# tools/inventory-gate.sh -- the build-inventory contract.
#
# History: this gate once policed the full-build.yaml strategy matrix
# (deleted 2026-11-25 -- one matrix build was more than the flow needed, and
# the GH runner could not reach the LAN device for nightly anyway).  With
# GitHub suspended and the githooks battery local, EVERY build.sh dir is by
# default locally buildable, so the inventory contract simplifies to:
#
#   * the skip list declares what the auto-build sweep deliberately does NOT
#     build, each with a current, honest reason;
#   * a skip entry whose build.sh vanished        -> red (stale skip);
#   * a duplicate skip entry                      -> red;
#   * every other build.sh dir needs no declaration (local build is the CI).
#
# The skip list is the contract: a reason that is no longer true must be
# fixed, not ignored.
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0

# The documented skip list: "<dir> <reason ...>".  One line per package.
skip_list=$(cat <<'EOF'
data/ca-certificates data-only refresh (no compilation); single-build on demand
ffmpeg root straggler, hours-long build; single-build on demand
lang/go bootstraps host+device Go toolchains (dual artifacts); on-demand
lang/python3 multi-hour build; single-build on demand
net/ifconfig Apple network_cmds-457 family; single-build on demand
net/privoxy configure+static-pcre2, device-verified locally (2026-11-25); single-build on demand
net/tailcat Go template canary #2; single-build on demand
net/tailscale Go, heavy build; single-build on demand
tools/fzf Go template canary (fzf4), device-verified locally; single-build on demand
tools/git-lfs Go template canary (git-lfs4), device-verified locally; single-build on demand
tools/tig configure+ncurses, device-verified locally (2026-11-25); single-build on demand
tools/entr tiny C, kqueue probe on device, device-verified locally; single-build on demand
tools/caddy Go template (quic-go compiles, http3 runtime untested), device-verified locally; single-build on demand
tools/lz4 plain-make CLI, device-verified locally; single-build on demand
tools/lsof small tool; single-build on demand
tools/ncdu small tool; single-build on demand
tools/patch small tool; single-build on demand
tools/pgrep small tool; single-build on demand
tools/smalltools small-tool bundle; single-build on demand
tools/uuid small tool; single-build on demand
tools/zstd shared-tree CLI on the curl zstd lock row, device-verified locally; single-build on demand
tweak/nocablewarn iOS tweak (dylib deb), dispatched on demand
EOF
)

# every tracked build.sh outside imported upstream / vendored trees
dirs=$(git ls-files '*/build.sh' | grep -vE '/(src|godeps)/' | sed 's|/build\.sh$||' | sort -u)

# 1. skip-list hygiene: build.sh must exist; no duplicate entries
seen=""
s_n=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    d=${line%% *}
    s_n=$((s_n+1))
    [ -f "$d/build.sh" ] || { echo "STALE SKIP: $d 已无 build.sh,删掉这行"; rc=1; }
    if grep -qx "$d" <<<"$seen"; then echo "DUPLICATE SKIP: $d 两次声明"; rc=1; fi
    seen="$seen"$'\n'"$d"
done <<<"$skip_list"

# 2. inventory count: everything not skip-declared is local-buildable by default
d_n=0
while IFS= read -r d; do
    [ -n "$d" ] || continue
    d_n=$((d_n+1))
done <<<"$dirs"

echo "build.sh dirs=$d_n skip-declared=$s_n local-buildable=$((d_n-s_n))"
if [ "$rc" = 0 ]; then
    echo "INVENTORY OK: skip 清单条条有据,其余本地即建"
else
    echo "INVENTORY FAIL: 见上" >&2
fi
exit $rc
