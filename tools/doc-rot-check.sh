#!/bin/bash
# tools/doc-rot-check.sh -- the documentation cannot describe a tree that
# does not exist (2026-11-23 review item 3: the categorized README shipped
# a quick start pointing at ./curl after curl/ had moved to net/curl, and
# a "21-package matrix" while the matrix said 32).
#
#   tools/doc-rot-check.sh                # exit 1 on drift
#
# Checks:
#   1. every backtick path whose FIRST segment is a package name must
#      follow that package's categorized location (net/ tools/ lang/
#      data/); SDK/device/sysroot-relative paths (netinet/tcp.h, usr/lib,
#      sys/sysctl.h) are out of scope;
#   2. the generated docs/PACKAGES.md row count must equal the repo pool's
#      deb count (the table is the generated truth);
#   3. package counts written in prose ("N packages") must match the pool.

set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

# ---- --self-test: prove the gate catches what it claims to catch ---------
# The 2026-11-24 lesson is not "the fence scan was missing" -- it is that a
# BROKEN scanner printed OK for months because nothing ever fed it a bad
# tree.  Build a synthetic tree with two known drifts (a fenced `cd curl/`
# and a backtick `curl/build.sh` after curl moved to net/curl) and assert:
#   exit 1, both drifts named, and a clean tree passes.  gate.yml runs this
# BEFORE the real scan, so a future regression cannot go quietly green.
if [ "${1:-}" = "--self-test" ]; then
    st=0
    t=$(mktemp -d)
    mkdir -p "$t/docs" "$t/tools" "$t/net/curl"
    cp "$0" "$t/tools/doc-rot-check.sh"
    : > "$t/README.md"
    printf '## fake\n\n```sh\n(cd curl && ./build.sh)\n./curl/make-deb.sh\n```\n\nalso `curl/build.sh`.\n' > "$t/docs/fake.md"
    out=$(cd "$t" && bash tools/doc-rot-check.sh 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "SELF-TEST FAIL: the gate passed a tree with known drift"; st=1
    fi
    echo "$out" | grep -q "fenced 引用 'curl/'" || { echo "SELF-TEST FAIL: the fenced drift was not named"; st=1; }
    echo "$out" | grep -q '应为 `net/curl' || { echo "SELF-TEST FAIL: the backtick drift was not named"; st=1; }
    # clean tree must pass
    printf '## fake\n\n```sh\n(cd net/curl && ./build.sh)\n./net/curl/make-deb.sh\n```\n\nalso `net/curl/build.sh`.\n' > "$t/docs/fake.md"
    if (cd "$t" && bash tools/doc-rot-check.sh >/dev/null 2>&1); then
        echo "SELF-TEST OK: bad tree rejected, clean tree passes"
    else
        echo "SELF-TEST FAIL: the gate rejected a clean tree"; st=1
    fi
    rm -rf "$t"
    exit $st
fi

cd "$here"
rc=0

# the package name -> categorized directory map (from the tree itself)
CATMAP=$(python3 - <<'PY'
import glob, os
for cat in ('net', 'tools', 'lang', 'data'):
    for p in sorted(glob.glob(f'{cat}/*')):
        if os.path.isdir(p):
            print(os.path.basename(p), p)
PY
)

# ---- 1. package-name backtick paths follow the categorization ------------
DRF=$(mktemp)
for f in README.md docs/*.md; do
    grep -oP '(?<=`)[a-z0-9_-]+(/[a-z0-9_.-]+)+/?(?=`)' "$f" 2>/dev/null \
    | sort -u | while read -r p; do
        [ -e "$p" ] && continue
        seg1="${p%%/*}"
        dest=$(awk -v s="$seg1" '$1==s {print $2}' <<<"$CATMAP")
        [ -n "$dest" ] && echo "DRIFT $f: \`$p\` 应为 \`$dest${p#"$seg1"}\`"
    done
done > "$DRF"
if [ -s "$DRF" ]; then
    cat "$DRF"
    rc=1
else
    echo "OK: 包路径引用全部跟随分类"
fi
rm -f "$DRF"

# ---- 1b. fenced code blocks: `cd <pkg>/` and `./<pkg>/` ------------------
# the quick start shipped `(cd curl && ./build.sh)` for months inside a
# ```sh block -- plain backtick scans do not reach fenced code, and THAT
# blind spot is the gate's bug (2026-11-24 audit item 1)
DRF2=$(mktemp)
for f in README.md docs/*.md; do
    awk '/^```/{inb=!inb; next} inb' "$f" \
    | grep -oE '(cd |\./)[a-z0-9_-]+/' | sed -E 's#^(cd |\./)##; s#/$##' \
    | sort -u | while read -r seg; do
        dest=$(awk -v s="$seg" '$1==s {print $2}' <<<"$CATMAP")
        [ -z "$dest" ] && continue
        [ -d "$seg" ] && continue
        echo "DRIFT $f: fenced 引用 '$seg/' 应为 '$dest/'"
    done
done > "$DRF2"
if [ -s "$DRF2" ]; then
    cat "$DRF2"
    rc=1
else
    echo "OK: fenced 代码块包路径全部跟随分类"
fi
rm -f "$DRF2"

# ---- 2+3. the generated table equals the pool; prose counts match --------
# repo/ is untracked (build products live on gh-pages) -- a fresh CI
# checkout has no pool; the count comparisons only run where the pool
# exists (the author's machine / the publish job itself)
if [ -d repo/pool ] && [ "$(find repo/pool -name '*.deb' 2>/dev/null | wc -l)" -gt 0 ]; then
    real_debs=$(find repo/pool -name '*.deb' 2>/dev/null | wc -l)
    real_rows=$(awk -F'|' '/^\| package/{f=1;next} f&&/^\| /{c++} END{print c+0}' docs/PACKAGES.md)
    if [ "$real_rows" -ne "$real_debs" ]; then
        echo "DRIFT docs/PACKAGES.md: 表 $real_rows 行 ≠ 池 $real_debs debs -- 重跑 scripts/gen-package-table.sh"
        rc=1
    else
        echo "OK: PACKAGES.md $real_rows 行 = 池 $real_debs debs"
    fi
    while read -r n; do
        if [ "$n" -ne "$real_debs" ]; then
            echo "DRIFT: 文档写 '$n packages' 而池里是 $real_debs"
            rc=1
        fi
    done < <(grep -oP '\d+(?= packages)' README.md docs/*.md 2>/dev/null | cut -d: -f2 | sort -u)
    # 中文池规模计数("N 个包/N 包")。增量措辞(新上池/进池)不是规模声明,
    # 排除;只有行内同时出现"池"且非增量的计数才参与比对(2026-11-25 审计)。
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ "$n" = "$real_debs" ] || { echo "DRIFT: 文档写 '$n 包' 而池里是 $real_debs debs"; rc=1; }
    done < <(grep -nP '池' README.md docs/*.md 2>/dev/null \
             | grep -vP '新上池|进池|\) 上池' \
             | grep -oP '\d+(?=\s*个?包)' | sort -u)
else
    echo "SKIP: repo/pool absent or empty (untracked build products) -- 数字对账跳过"
fi

# README 包名 ⊆ 池:每一条 `apt-get install <pkgs>` 里的包名必须能在池里找到
# (2026-11-25:README 安装块里的 node4 在 node 迁出仓库后漂移了两周 ——
# doc-rot 只对路径和数量,包名没人看)。索引/Packages 存在才可判,否则跳过。
IDX="repo/dists/stable/main/binary-iphoneos-arm/Packages"
if [ -s "$IDX" ]; then
    bad=0
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        grep -q "^Package: $pkg\$" "$IDX" || { echo "DRIFT: README 安装行的包 '$pkg' 不在池内"; bad=1; }
    done < <(grep -oP '^apt-get install \K[^#]*' README.md \
             | tr ' ' '\n' | grep -oP '^[a-z0-9+._-]+' | sort -u)
    [ "$bad" = 0 ] && echo "OK: README 安装行包名全部在池内"
    [ "$bad" = 1 ] && rc=1
else
    echo "SKIP: Packages 索引不存在 -- README 包名校验跳过"
fi

exit $rc
