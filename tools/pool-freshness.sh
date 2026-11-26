#!/bin/bash
# tools/pool-freshness.sh -- the pool users install from must not lag the
# recipes behind it (2026-11-24 audit item 2: wget4/tailscale4/go4 fixes
# lived only in make-deb.sh while devices installed the old metadata, and
# dropbear/mosh/openssh/jq recipe revs sat BELOW the pool -- a clean
# rebuild would regress the version and make-repo's newest-wins would
# silently keep the fix from ever reaching the pool).
#
#   POOL_DIR=repo/pool tools/pool-freshness.sh
#
# Checks per package that has a pool deb AND a make-deb recipe:
#   1. recipe default version  ==  pool version   (a lower recipe rev means
#      a clean rebuild regresses -- FATAL; a higher one = republish pending)
#   2. ca-certificates4 dependency consistency: declared in the recipe's
#      control block XOR present in the pool deb's Depends is a FATAL
#      (the CA-chain fix must reach users, and must not regress)
# Recipe association comes from the GENERATED docs/PACKAGES.md table via
# tools/pool-freshness-recipes.py (self-parsing control blocks capped at
# 41% coverage).  Exits 1 on any finding.  Skips cleanly when the pool is
# absent (fresh CI checkout -- the live gate runs at make-repo time).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
POOL="${POOL_DIR:-repo/pool}"
rc=0

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "SKIP: dpkg-deb unavailable"; exit 0
fi
if [ ! -d "$POOL" ] || [ "$(find "$POOL" -name '*.deb' 2>/dev/null | wc -l)" -eq 0 ]; then
    echo "SKIP: pool absent or empty at $POOL"; exit 0
fi

# ---- recipe index via the generated table + the per-recipe parser --------
recipe_index=$(mktemp)
python3 tools/pool-freshness-recipes.py tools/recipe-pkgs.txt >> "$recipe_index"

# ---- pool side + comparison ----------------------------------------------
# out/ side: newest deb per package name.  DYN rows skip the recipe-version
# compare below, but a built-but-unpublished deb in out/ must still surface
# (2026-11-25: ffmpeg_9.0.2-2 sat in out/ while the pool kept -1 for a day
# because the DYN skip hid the drift from check 1).
declare -A OUT_NEWEST
for odebs in out/*_iphoneos-arm.deb; do
    [ -e "$odebs" ] || continue
    b="$(basename "$odebs")"; opkg="${b%%_*}"
    over="${b#${opkg}_}"; over="${over%_iphoneos-arm.deb}"
    prev="${OUT_NEWEST[$opkg]:-}"
    if [ -z "$prev" ] || [ "$(printf '%s\n%s\n' "$prev" "$over" | sort -V | tail -1)" = "$over" ]; then
        OUT_NEWEST[$opkg]="$over"
    fi
done
drift=$(mktemp)
unmatched=0; dyn_n=0
for deb in $(find "$POOL" -name '*.deb' | sort); do
    pkg=$(dpkg-deb -f "$deb" Package)
    ver=$(dpkg-deb -f "$deb" Version)
    dep=$(dpkg-deb -f "$deb" Depends)
    row=$(awk -F'\t' -v p="$pkg" '$1==p {print; exit}' "$recipe_index")
    if [ -z "$row" ]; then
        unmatched=$((unmatched+1))
        continue
    fi
    rver=$(cut -f2 <<<"$row"); rca=$(cut -f3 <<<"$row"); rfw=$(cut -f4 <<<"$row"); rmk=$(cut -f5 <<<"$row")
    if [ "$rver" = "DYN" ]; then
        dyn_n=$((dyn_n+1))
        if [ -n "${OUT_NEWEST[$pkg]:-}" ] && [ "${OUT_NEWEST[$pkg]}" != "$ver" ]; then
            newest="$(printf '%s\n%s\n' "$ver" "${OUT_NEWEST[$pkg]}" | sort -V | tail -1)"
            if [ "$newest" = "${OUT_NEWEST[$pkg]}" ]; then
                echo "DRIFT $pkg: 池 $ver 落后于 out/ 最新 ${OUT_NEWEST[$pkg]} (DYN 行,build 已跑未 publish) -- $rmk"
                echo "$pkg" >> "$drift"
            fi
        fi
    elif [ "$rver" != "$ver" ]; then
        if [[ "$rver" > "$ver" ]]; then
            echo "DRIFT $pkg: 池 $ver 落后于配方默认 $rver -- 需重新 build+publish ($rmk)"
            echo "$pkg" >> "$drift"
        else
            echo "FATAL $pkg: 配方默认 $rver 低于池内 $ver -- 干净重建会回退版本 ($rmk)"
            rc=1
        fi
    fi
    if [ "$pkg" != "ca-certificates4" ]; then
        if [ "$rca" -gt 0 ] && ! grep -q 'ca-certificates4' <<<"$dep"; then
            echo "FATAL $pkg: 配方声明 ca-certificates4 而池内 Depends 缺失(修复没到用户) -- $deb"
            rc=1
        fi
        if [ "$rca" -eq 0 ] && grep -q 'ca-certificates4' <<<"$dep"; then
            echo "FATAL $pkg: 池内 Depends 有 ca-certificates4 而配方已无 -- 重建会回退 -- $deb"
            rc=1
        fi
    fi
    # firmware (>= 10.3) XOR: same contract as the ca check (2026-11-25 --
    # the nine-package Depends round shipped recipes without the debs).
    if [ "$pkg" != "firmware" ]; then
        if [ "$rfw" -gt 0 ] && ! grep -q 'firmware' <<<"$dep"; then
            echo "FATAL $pkg: 配方声明 firmware (>= 10.3) 而池内 Depends 缺失(修复没到用户) -- $deb"
            rc=1
        fi
        if [ "$rfw" -eq 0 ] && grep -q 'firmware' <<<"$dep"; then
            echo "FATAL $pkg: 池内 Depends 有 firmware 而配方已无 -- 重建会回退 -- $deb"
            rc=1
        fi
    fi
done
rm -f "$recipe_index"

# ---- completeness: the explicit recipe->package contract -------------------
# tools/recipe-pkgs.txt is the authoritative mapping (2026-11-25 audit):
#   * every package a recipe produces must have a pool deb -- a recipe whose
#     output never reached the pool is invisible to users (fresh-out blues);
#   * every pool deb must be claimed by a recipe -- a pool deb no recipe
#     produces cannot be rebuilt.
declare -A IN_POOL IN_RECIPE
for d in "$POOL"/main/*/*/; do
    [ -d "$d" ] || continue
    p="$(dpkg-deb -f "$d"*.deb Package 2>/dev/null)" && IN_POOL[$p]=1
done
while IFS=$'\t' read -r recipe pkgs; do
    case "$recipe" in ''|'#'*) continue;; esac
    IFS=',' read -ra pl <<<"$pkgs"
    for p in "${pl[@]}"; do
        IN_RECIPE[$p]=$recipe
        if [ -z "${IN_POOL[$p]:-}" ]; then
            echo "POOL-COMPLETENESS FAIL: $recipe produces $p but the pool has no $p deb (run scripts/make-repo.sh)" >&2
            rc=1
        fi
    done
done < tools/recipe-pkgs.txt
for p in "${!IN_POOL[@]}"; do
    if [ -z "${IN_RECIPE[$p]:-}" ]; then
        echo "POOL-COMPLETENESS FAIL: pool deb $p is claimed by no recipe in tools/recipe-pkgs.txt (add the mapping or the recipe)" >&2
        rc=1
    fi
done
[ "$rc" = 0 ] || echo "(completeness map: tools/recipe-pkgs.txt)" >&2
[ "$unmatched" -gt 0 ] && echo "NOTE: $unmatched 个池内包未能关联配方(PACKAGES.md 无 recipe 列或 make-deb 缺失)"
[ "$(wc -l < "$drift")" -gt 0 ] && { echo "--"; echo "待重新 build+publish:$(wc -l < "$drift") 个包(见 DRIFT 行)"; }
[ "$rc" -ne 0 ] && echo "存在 FATAL:先修配方或补发布,再重跑本门禁"
[ "$rc" -eq 0 ] && [ "$(wc -l < "$drift")" -eq 0 ] && echo "OK: 池与配方版本/依赖一致 (版本比对 $(( $(find "$POOL" -name '*.deb' | wc -l) - dyn_n ))/$(find "$POOL" -name '*.deb' | wc -l),$dyn_n 个动态推导跳过)"
rm -f "$drift"
exit $rc
