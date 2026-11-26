#!/bin/bash
# gen-package-table.sh -- generate docs/PACKAGES.md from the APT Packages
# index, so the "what exists" documentation cannot drift from what the repo
# actually ships.  Regenerate on every repo rebuild.
#
# Columns: package | version | build recipe | docs | device acceptance
#   - build recipe: <base>/ directory when present, else '--'
#   - docs: docs/<base>.md when present (a few names need a manual mapping)
#   - device acceptance: tests/<base>.sh + its case count, when present
#
# Usage: scripts/gen-package-table.sh [out-file]   (default docs/PACKAGES.md)
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$here/docs/PACKAGES.md}"
idx="$here/repo/dists/stable/main/binary-iphoneos-arm/Packages"
[ -f "$idx" ] || { echo "repo not built; run scripts/make-repo.sh first" >&2; exit 1; }

python3 - "$here" "$idx" "$out" <<'PY'
import re, sys, os
repo, idx_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

stanzas = []
for stanza in open(idx_path).read().split('\n\n'):
    if not stanza.strip():
        continue
    get = lambda k: (re.search(rf'^{k}: (.*)$', stanza, re.M) or [None, ''])[1]
    stanzas.append((get('Package'), get('Version'), get('Description')))

DOC_MAP = {'python314': 'python', 'whois4': 'whois', 'netstat4': 'netstat',
           'ifconfig4': 'ifconfig', 'traceroute4': 'traceroute',
           'wget4': 'wget', 'tor4': 'tor', 'openssh4': 'openssh',
           'dropbear4': 'dropbear', 'dns4': 'dns',
           'lua54': 'lua', 'p7zip17': 'p7zip', 'sqlite3': 'sqlite'}

# deb/doc base name -> recipe DIRECTORY name, when the two differ
# (python314's docs live in python.md, its recipe in lang/python3/)
DIR_MAP = {'python': 'python3', 'proxychains': 'proxychains-ng',
           'uuidgen': 'uuid'}

def cands_of(pkg):
    # candidate ladder (audit 2026-11-25): DOC_MAP alias -> pkg -> strip the
    # trailing rev digit -> DIR_MAP alias of the stripped base.  The old
    # single-guess base_of() turned lz4 into 'lz' and left its recipe/doc
    # columns '--' (tests column used the same broken base).
    out, seen = [], set()
    def add(x):
        if x and x not in seen:
            seen.add(x); out.append(x)
    add(DOC_MAP.get(pkg))
    add(pkg)
    if pkg.endswith('4'):
        stripped = pkg[:-1]
        add(stripped)
        add(DIR_MAP.get(stripped))
    return out

# the categorized layout: <pkg> dirs live one level down (net/, tools/,
# lang/, data/) except the root stragglers (ffmpeg, tailcat)
def dir_of(pkg):
    for c in cands_of(pkg):
        d = DIR_MAP.get(c, c)
        for cat in ('net', 'tools', 'lang', 'data'):
            p = os.path.join(repo, cat, d)
            if os.path.isdir(p):
                return f'{cat}/{d}'
        if os.path.isdir(os.path.join(repo, d)):
            return d
    return None

rows = []
for pkg, ver, desc in sorted(stanzas):
    dpath = dir_of(pkg)
    recipe = f'`{dpath}/`' if dpath else '--'
    # PACKAGES.md lives IN docs/ -- its links must be relative to docs/,
    # not to the repo root (the user caught the doubled prefix)
    docs_cell = '--'
    for c in cands_of(pkg) + [(dpath or '').split('/')[-1]]:
        if c and os.path.exists(os.path.join(repo, 'docs', f'{c}.md')):
            docs_cell = f'[{c}.md]({c}.md)'; break
    # test column: candidate ladder over the same names (audit 2026-11-24
    # item 5 + 2026-11-25: one guess missed lz4 and every X4 package whose
    # tests file uses the stripped base)
    acc = '--'
    for c in cands_of(pkg) + [(dpath or '').split('/')[-1]]:
        if c and os.path.exists(os.path.join(repo, 'tests', f'{c}.sh')):
            n = len(re.findall(r'expect_', open(os.path.join(repo, 'tests', f'{c}.sh')).read()))
            acc = f'[../tests/{c}.sh](../tests/{c}.sh), {n} cases'
            break
    d = (desc or '').split('.')[0].strip()[:64]
    rows.append(f'| {pkg} | {ver} | {recipe} | {docs_cell} | {acc} |')

open(out_path, 'w').write('\n'.join([
    '# Package index (generated)',
    '',
    'Generated from the APT `Packages` index by',
    '`scripts/gen-package-table.sh` -- do not edit by hand; it regenerates',
    'on every repo rebuild.',
    '',
    f'{len(stanzas)} debs in `repo/pool`:',
    '',
    '| package | version | build recipe | docs | device acceptance |',
    '|---|---|---|---|---|',
    *rows,
]) + '\n')
print(f'==> {out_path}: {len(stanzas)} packages')

# 断言:recipe 列(第 3 列)为 -- 的行即 FATAL——每个 deb 都必须能定位到
# build.sh 所在目录。只看 recipe 列:'| -- |' 全行匹配会把没有验收测试或
# 文档的包也误杀(第一次真池子上闸就炸,ffmpeg/go4/lsof... 12 个假阳性;
# 2026-11-23 第三轮评审第 6 条 + 第四轮修)
bad = []
for r in rows:
    cells = [c.strip() for c in r.split('|')[1:-1]]
    if cells[2] == '--':
        bad.append(r)
if bad:
    print('FATAL: rows with no recipe dir:', *bad, sep='\n  ', file=sys.stderr)
    sys.exit(1)
PY