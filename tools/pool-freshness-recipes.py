#!/usr/bin/env python3
# tools/pool-freshness-recipes.py -- emit the recipe index (TSV) for
# pool-freshness.sh: package -> "version" -> ca-flag -> make-deb path.
#
# Source of truth: tools/recipe-pkgs.txt (the authoritative recipe->package
# mapping, 2026-11-25).  The previous source -- heuristic parsing of the
# generated docs/PACKAGES.md table -- capped at 41% coverage and left the 8
# packages of 2026-11-25 completely unchecked (audit).
#
# Version resolution rules (each learned from a false FATAL or a real miss):
#   * "Version: $VAR-..." with VAR="x.y" and DEBREV:-N  -> "x.y-N"
#   * "Version: $VAR"    with VAR="3.13.18-6" (rev baked) -> as-is
#   * env-reread definitions (VAR="${VAR:-x.y}") resolve RECURSIVELY
#     (two-level was not enough: whois/ffmpeg/tor/... all use it)
#   * variable names carry digits (IPERF3_VERSION) -- [A-Z0-9_]+
#   * multi-deb recipes (net/curl ships curl4 AND openssl4): the Version
#     line is anchored AFTER the "Package: <pkg>" occurrence; recipes that
#     build the control as "Package: $PKG" fall back to PKG:-default
#     matching (whole file = stanza, one deb per file by construction)
#   * literal "Version: 1.0-1" (netstat4) passes through as-is
#   * variant recipes: python314 -> lang/python3/make-deb-314.sh
import re, sys, os

def resolve(val, s, depth=0):
    if depth > 3:
        return val
    m = re.match(r'^\$\{([A-Z0-9_]+):-(.*)\}$', val)
    if m:
        return resolve(m.group(2), s, depth + 1)
    m = re.match(r'^\$([A-Z0-9_]+)$', val)
    if m:
        d = re.search(rf'^{m.group(1)}="?([^"\n]*)"?', s, re.M)
        return resolve(d.group(1), s, depth + 1) if d else val
    return val

for line in open(sys.argv[1]):
    line = line.rstrip('\n')
    if not line or line.startswith('#'):
        continue
    recipe, pkgs = line.split('\t', 1)
    for pkg in pkgs.split(','):
        cands = [f'{recipe}/make-deb.sh']
        mm = re.match(r'^(.*?)(\d+)$', pkg)
        if mm and mm.group(2):
            v = f'{recipe}/make-deb-{mm.group(2)}.sh'
            if os.path.exists(v):
                cands.insert(0, v)
        mk = next((c for c in cands if os.path.exists(c)), None)
        if not mk:
            print(f'NO-RECIPE-FILE: {recipe} for {pkg}', file=sys.stderr)
            continue
        s = open(mk, errors='ignore').read()
        pm = re.search(rf'^Package: {re.escape(pkg)}\s*$', s, re.M)
        if not pm:
            # recipes that build the control as "Package: $PKG" with the
            # package name only in the PKG default -- whole file is the
            # stanza (one deb per file by construction)
            if re.search(rf'^PKG="(\$\{{PKG:-)?{re.escape(pkg)}\}}?"', s, re.M):
                pm = re.match(r'^', s)
                nm = None
            else:
                print(f'NO-PACKAGE-LINE: {pkg} not declared in {mk}', file=sys.stderr)
                continue
        else:
            nm = re.search(r'^Package: ', s[pm.end():], re.M)
        body = s[pm.end(): pm.end() + nm.start()] if nm else s[pm.end():]
        vm = re.search(r'^Version: \$\{?([A-Z0-9_]+)\}?(?:-([0-9]+))?', body, re.M)
        if vm:
            var = vm.group(1)
            literal_rev = vm.group(2)
            dm = re.search(rf'^{var}="?([^"\n]*)"?', s, re.M)
            if not dm:
                print(f'NO-VARDEF: {var} undefined in {mk}', file=sys.stderr)
                continue
            ver = resolve(dm.group(1), s)
            if literal_rev:
                ver = f'{ver}-{literal_rev}'
            else:
                rm_ = re.search(r'DEBREV:-([0-9]+)', s)
                if rm_:
                    ver = f'{ver}-{rm_.group(1)}'
        else:
            lm = re.search(r'^Version: (\d[^\s]*)\s*$', body, re.M)
            if not lm:
                print(f'NO-VERSION: {pkg} in {mk} has no parseable Version line', file=sys.stderr)
                continue
            ver = lm.group(1)
        if ver.startswith('$') or '${' in ver:
            # version derived from build outputs at runtime (UPSTREAM pulled
            # from artifact names / source headers) -- statically unknown.
            # Emit DYN: pool-freshness skips the version compare (the deb IS
            # whatever the tree builds) and keeps the ca-consistency check.
            print(f'DYNAMIC-VER: {pkg} version derived from build outputs in {mk}', file=sys.stderr)
            ver = 'DYN'
        # ca-flag is STANZA-scoped: net/curl/make-deb.sh ships curl4 (ca ✓) AND
        # openssl4 (a lib, ca ✗) -- a whole-file grep inherited curl4's answer
        ca = 1 if 'ca-certificates4' in body else 0
        fw = 1 if 'firmware (>= 10.3)' in body else 0
        print(f'{pkg}\t{ver}\t{ca}\t{fw}\t{mk}')
