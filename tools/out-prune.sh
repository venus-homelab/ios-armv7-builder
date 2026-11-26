#!/bin/bash
# tools/out-prune.sh -- keep the newest revision of each package in out/,
# move superseded revisions to out/archive/<pkg>/.
#
# Why (2026-11-25 audit item 7): out/ accumulates every build -- 106 debs by
# 2026-11-25, and nothing consumed the old ones: the pool takes the
# newest-per-package (scripts/make-repo.sh), and every gate globs only the
# top level.  Policy: newest stays, history moves to out/archive/<pkg>/ --
# a top-level subdirectory the out/*.deb globs never descend into (same
# trick as out/custom/).  Idempotent; dry-run with DRY=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p out/archive

declare -A BEST_VER BEST_FILE total=0
for f in out/*_iphoneos-arm.deb; do
    [ -e "$f" ] || continue
    pkg="$(dpkg-deb -f "$f" Package)"
    v="$(dpkg-deb -f "$f" Version)"
    total=$((total+1))
    if [ -z "${BEST_VER[$pkg]:-}" ] || dpkg --compare-versions "$v" gt "${BEST_VER[$pkg]}"; then
        BEST_VER[$pkg]="$v"; BEST_FILE[$pkg]="$f"
    fi
done

moved=0
for f in out/*_iphoneos-arm.deb; do
    [ -e "$f" ] || continue
    pkg="$(dpkg-deb -f "$f" Package)"
    [ "${BEST_FILE[$pkg]:-}" = "$f" ] && continue
    if [ "${DRY:-0}" = 1 ]; then
        echo "would archive: $f"
    else
        mkdir -p "out/archive/$pkg"
        mv "$f" "out/archive/$pkg/"
    fi
    moved=$((moved+1))
done

if [ "${DRY:-0}" = 1 ]; then
    echo "DRY: $total debs in out/, $moved would move to out/archive/"
else
    echo "pruned: $total -> $((total-moved)) kept in out/, $moved archived under out/archive/"
    echo "kept: $(for p in "${!BEST_FILE[@]}"; do basename "${BEST_FILE[$p]}"; done | LC_ALL=C sort | paste -sd' ')"
fi
