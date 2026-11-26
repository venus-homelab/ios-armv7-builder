#!/bin/bash
# tools/sysroot-manifest.sh -- hash manifest for the committed sysroot
# trees + sentinel hashes for the SDK the toolchain cache carries.
#
#   tools/sysroot-manifest.sh                 # regenerate MANIFEST.sha256
#   tools/sysroot-manifest.sh --verify        # verify against it; exit 1 on drift
#
# Why (2026-11-23, the uuid/mach incidents): the CI toolchain cache carries
# an SDK extracted from the xybp888 mirror at whatever commit the cache was
# built at -- the mirror GAINS files over time, so a stale cache silently
# lacks headers the local SDK has (uuid/uuid.h died exactly this way).  The
# committed sysroot trees are hand-curated and must not drift either.  One
# manifest catches both classes:
#
#   * every file under tools/sysroot/** is hashed (drift = an unmanifested
#     edit) -- that single tree now holds BOTH header views in-tree:
#     musl-usr/ (node, the last musl-era build) and overlay/ (+compat,
#     wall #14's kevent fix and the libios-compat members);
#   * a pinned list of SDK sentinel headers is hashed from
#     $IOS_SYSROOT_SDK (default ~/ios-tool/iPhoneOS10.3.sdk) -- on CI the
#     toolchain cache must carry byte-identical copies.
#
# NOTE (2026-11-24, audit item 4): the old claim that the overlay lives in
# a SIBLING repo is obsolete -- the categorization moved everything in-tree
# and the manifest below covers it.  The full "one source + generate"
# convergence is a later refactor; this manifest is the detection layer
# that keeps the two header views from silently drifting apart.

set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
MODE=verify; [ "${1:-}" = "--verify" ] || MODE=gen
MANIFEST="$here/tools/sysroot/MANIFEST.sha256"
SDK="${IOS_SYSROOT_SDK:-$HOME/ios-tool/iPhoneOS10.3.sdk}"

# only trees that exist (a missing dir must not kill the run)
TREES=""
for t in tools/sysroot; do
    [ -d "$here/$t" ] && TREES="$TREES $t"
done

SENTINELS="uuid/uuid.h mach/mach.h mach/std_types.h TargetConditionals.h sys/sysctl.h net/if_dl.h sys/event.h"

gen() {
    # staging via mktemp: tmp/ is gitignored and absent on a CI checkout
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/sysroot-manifest.XXXXXX")
    ( cd "$here" && find $TREES -type f ! -name MANIFEST.sha256 | sort \
        | xargs sha256sum ) > "$tmp"
    {
        echo "# SDK sentinels: the CI toolchain cache must carry"
        echo "# byte-identical copies of these (paths under usr/include):"
        for h in $SENTINELS; do
            f="$SDK/usr/include/$h"
            [ -f "$f" ] || { echo "MISSING SDK sentinel: $h" >&2; exit 1; }
            printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "SDK:$h"
        done
    } >> "$tmp"
    mv "$tmp" "$MANIFEST"
    echo "==> $MANIFEST ($(grep -c . "$MANIFEST") entries)"
}

verify() {
    local rc=0 tmpf
    # the manifest's SDK: sentinel lines are labels, not files -- filter
    # them out for the tree check.  Staging via mktemp: tmp/ is gitignored
    # and absent on a CI checkout (the jq dispatch died exactly here).
    tmpf=$(mktemp "${TMPDIR:-/tmp}/sysroot-manifest.XXXXXX")
    grep -v '  SDK:' "$MANIFEST" > "$tmpf"
    if ( cd "$here" && sha256sum --quiet -c "$tmpf" >/dev/null 2>&1 ); then
        echo "OK: committed sysroot trees match the manifest"
    else
        echo "DRIFT: committed sysroot trees differ from the manifest:" >&2
        ( cd "$here" && sha256sum --quiet -c "$tmpf" 2>/dev/null \
            | grep -av ': OK$' | head -10 ) >&2
        rc=1
    fi
    rm -f "$tmpf"
    for h in $SENTINELS; do
        want=$(awk -v h="SDK:$h" '$NF==h {print $1}' "$MANIFEST")
        f="$SDK/usr/include/$h"
        if [ ! -f "$f" ]; then
            echo "SDK sentinel MISSING: $h" >&2; rc=1
        elif [ -z "$want" ]; then
            echo "manifest entry MISSING: SDK:$h" >&2; rc=1
        elif [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$want" ]; then
            echo "SDK sentinel DRIFT: $h" >&2; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "OK: SDK sentinels match"
    return $rc
}

case "$MODE" in
    gen)    gen ;;
    verify) verify ;;
esac
