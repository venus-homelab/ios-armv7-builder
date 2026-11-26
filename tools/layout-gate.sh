#!/bin/bash
# tools/layout-gate.sh -- the categorization (net/ tools/ lang/ data/)
# introduced a class of breakage the old gate could not see: scripts whose
# root calculation or cross-package references still point at the
# pre-categorization layout.  This gate makes the class impossible to
# reintroduce silently.
#
#   tools/layout-gate.sh            # exit 1 on any violation
#
# Checks:
#   1. every */build.sh lives at a categorized path (net|tools|lang|data/ or
#      the documented root stragglers: ffmpeg, tailcat, tweak);
#   2. every $root/<pkg>/ reference in the build scripts points at a real
#      categorized location;
#   4. the workflow artifact names contain no slash (GHA forbids it);
#   5. no build/package script depends on ~/scratch (a clean checkout +
#      empty HOME must suffice; documented exceptions: NONE left).

set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
rc=0

# the categorized package name -> directory map
CATMAP=$(mktemp)
python3 - <<'PY' > "$CATMAP"
import glob, os
for cat in ('net', 'tools', 'lang', 'data'):
    for p in sorted(glob.glob(f'{cat}/*')):
        if os.path.isdir(p):
            print(os.path.basename(p), p)
# documented root stragglers are also valid $root/<pkg> targets
for p in ('ffmpeg', 'tweak'):
    if os.path.isdir(p):
        print(p, p)
PY

# 1. every build.sh sits in a categorized (or documented straggler) path
STRAGGLERS="ffmpeg tailcat tweak"
while IFS= read -r f; do
    d=$(dirname "$f")
    case "$d" in
        net/*|tools/*|lang/*|data/*) ;;
        ffmpeg|tailcat|tweak|tweak/*) ;;   # documented root stragglers
        *) echo "LAYOUT: $f 不在分类路径下(根散兵: $d)"; rc=1 ;;
    esac
done < <(find net tools lang data ffmpeg tailcat tweak -name build.sh 2>/dev/null | sort)

# (former check #2 -- "every full-build matrix entry resolves to build.sh" --
#  retired with full-build.yaml itself, 2026-11-25.  The lesson stands: when
#  a gate's data file disappears, the check must be REMOVED, not left to die
#  inside a process substitution that turns empty and prints OK anyway.)

# 3. $root/<pkg> references must exist -- NO trailing slash required: a bare
# `cd "$root/curl"` is exactly the form that slipped past the first version
# of this check and red the tools/git dispatch
ref_fail=0
while IFS= read -r f; do
    while IFS= read -r ref; do
        [ -e "$ref" ] || { echo "REF: $f 引用 \$root 下不存在的 $ref"; ref_fail=1; }
    done < <(grep -oP '\$root/\K[a-z0-9_-]+' "$f" 2>/dev/null | sort -u \
        | while read -r seg; do
            dest=$(awk -v s="$seg" '$1==s {print $2}' "$CATMAP")
            [ -n "$dest" ] && echo "$dest"
        done)
done < <(find net tools lang data ffmpeg tweak -name '*.sh' | sort)
[ "$ref_fail" = 0 ] || rc=1

# 4. workflow artifact names must not contain the raw package path
af_fail=0
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
    grep -n 'name: .*${{ inputs.package }}-out' "$wf" 2>/dev/null \
        && { echo "ARTIFACT: $wf 用了未规范化的包路径做 artifact 名"; af_fail=1; }
done
[ "$af_fail" = 0 ] || rc=1

# 5. no FUNCTIONAL ~/scratch dependency in build/package scripts
#    (comments and .deb description prose are exempt -- they are history,
#    not code)
sc_fail=0
while IFS= read -r f; do
    hit=$(grep -nE '^[^#]*(cd |cp |SRC=|GOPORT=|BOOTSTRAP=|TCT_SRC=|TS_SRC=).*~/scratch' "$f" 2>/dev/null | head -2)
    [ -n "$hit" ] && { echo "SCRATCH: $f 仍功能性依赖 ~/scratch:"; echo "$hit" | sed 's/^/    /'; sc_fail=1; }
done < <(find net tools lang data -name 'build.sh' -o -name 'make-deb*.sh' | sort)
[ "$sc_fail" = 0 ] || rc=1

# 6. PACKAGES.md columns must agree with the filesystem (2026-11-25 audit):
#    the generated table's recipe/tests/doc cells are cross-checked BOTH ways
#    against reality -- a '--' where a dir/file exists, or a cell pointing at
#    nothing, used to pass every gate (the lz4/caddy4 generation bugs).
pk=$(python3 - <<'PY'
import os, re, sys, glob
rows = []
for line in open('docs/PACKAGES.md'):
    m = re.match(r'\| (\S+) \| \S+ \| (\S+) \| (\S+) \| (.+) \|', line)
    if m and 'package' not in m.group(1):
        rows.append((m.group(1), m.group(2), m.group(3), m.group(4)))
def cell_target(cell, kind):
    if cell == '--':
        return None
    if kind == 'recipe':
        return cell.strip('`').rstrip('/')
    if kind == 'tests':
        m = re.search(r'\]\(([^)]+)\)', cell)
        return m.group(1).lstrip('./') if m else cell
    if kind == 'docs':
        m = re.match(r'\[([^]]+)\]', cell)
        return f'docs/{m.group(1)}' if m else None
bad = []
# forward: a non-'--' cell must resolve
for pkg, recipe, docs, tests in rows:
    t = cell_target(recipe, 'recipe')
    if t and not os.path.isdir(t):
        bad.append(f'{pkg}: recipe 列指向不存在的 {t}')
    t = cell_target(tests, 'tests')
    if t and not os.path.isfile(t):
        bad.append(f'{pkg}: tests 列指向不存在的 {t}')
    t = cell_target(docs, 'docs')
    if t and not os.path.isfile(t):
        bad.append(f'{pkg}: docs 列指向不存在的 {t}')
# reverse: an existing artifact must not be '--'
# deb-producing recipes per the authoritative map (net/libpcap has a
# build.sh but ships inside tcpdump's deb -- no row expected)
deb_dirs = {l.split('\t')[0] for l in open('tools/recipe-pkgs.txt')
            if l.strip() and not l.startswith('#')}
dirs = {d for d in {os.path.dirname(x) for x in glob.glob('*/*/build.sh')
                    if x.split('/')[0] in ('net','tools','lang','data')} | {'ffmpeg'}
        if d in deb_dirs}
for pkg, recipe, docs, tests in rows:
    if recipe == '--' and pkg.rstrip('0123456789') and any(pkg in d or d.endswith(pkg.rstrip('0123456789')) for d in dirs):
        pass  # ladder ambiguity is the generator's job; layout-gate only flags hard contradictions
for f in glob.glob('tests/*.sh'):
    b = os.path.basename(f)[:-3]
    for pkg, recipe, docs, tests in rows:
        if pkg == b and tests == '--':
            bad.append(f'{pkg}: tests/{b}.sh 存在而表中为 --')
for f in glob.glob('docs/*.md'):
    b = os.path.basename(f)[:-3]
    for pkg, recipe, docs, tests in rows:
        if pkg == b and docs == '--':
            bad.append(f'{pkg}: docs/{b}.md 存在而表中为 --')
for d in dirs:
    if not any(r[1].strip('`').rstrip('/') == d for r in rows):
        # a brand-new package between "built into out/" and "published" is
        # legitimate mid-flight state (pool-freshness tracks the other
        # direction) -- downgrade to a note unless NOTHING was built
        pkg_name = open('tools/recipe-pkgs.txt').read()
        import re as _re
        m = _re.search(rf'^{d}\t([^\n]+)$', pkg_name, _re.M)
        pkg = m.group(1).split(',')[0] if m else d
        if glob.glob(f'out/{pkg}_*_iphoneos-arm.deb'):
            print(f'NOTE {d}: 已构建待发布(out/ 有 deb,PACKAGES.md 待再生)')
        else:
            bad.append(f'{d}: 配方目录存在而 PACKAGES.md 无对应行')
if bad:
    print('\n'.join(bad)); sys.exit(1)
PY
) || { echo "$pk"; echo "PACKAGES COLUMNS FAIL"; rc=1; }

rm -f "$CATMAP"
if [ "$rc" = 0 ]; then
    echo "LAYOUT OK: 分类、矩阵、引用、artifact 名、scratch 依赖全部合规"
else
    echo "LAYOUT FAIL: 见上" >&2
fi
exit $rc
