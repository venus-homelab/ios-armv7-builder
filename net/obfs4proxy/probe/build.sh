#!/bin/bash
# Cross-build the obfs4proxy loopback-E2E probes.
#
# Products land in tmp/obfs4-e2e/ (NOT out/ -- this is E2E evidence
# tooling, not a pool deliverable; net/torsocks/probe precedent):
#   obfs4proxy-host        GOOS=linux GOARCH=amd64 build of the SAME
#                          pristine tag tree -- the server half of the
#                          loop.  Proves the obfs4 SERVER role end to end
#                          even though the device only ever runs the
#                          client role.
#   pt-driver-armv7        device pt manager (GOOS=darwin GOARCH=arm).
#   pt-driver-host         linux/amd64 twin, lets the whole loop be
#                          rehearsed host-side before touching the
#                          device.
#
# Source: the same sources.lock row and extraction-dir rule as
# net/obfs4proxy/build.sh (tmp/src/<top-level> reuse is intentional --
# the trees are identical).
#
# Usage: ./obfs4proxy/probe/build.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
WORK="$root/tmp/obfs4-e2e"
GO_VERSION="${GO_VERSION:-1.27.2}"

source "$root/tools/go-env.sh"

mkdir -p "$WORK"
read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock obfs4proxy)"
tarball="$("$root/tools/fetch-src.sh" obfs4proxy "$U" "$SHA")"
tf="$(mktemp "$root/tmp/obfs4-tf.XXXXXX")"; trap 'rm -f "$tf"' EXIT
tar tf "$tarball" >"$tf"
top="$(head -1 "$tf" | cut -d/ -f1)"
SRC="$root/tmp/src/$top"
if [ ! -f "$SRC/go.mod" ]; then
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi

# godeps replaces, same wiring as the package build (relative to go.mod).
python3 - "$SRC/go.mod" "$root/godeps" <<'PY'
import os, re, sys
gomod, godeps = sys.argv[1], sys.argv[2]
srcdir = os.path.dirname(gomod)
s = open(gomod).read()
base_pat = 'module gitlab.com/yawning/obfs4.git\n'
mapping = {'golang.org/x/sys': os.path.join(godeps, 'xsys-darwin-arm'),
           'golang.org/x/net': os.path.join(godeps, 'xnet-darwin-arm')}
for mod, path in mapping.items():
    rel = os.path.relpath(path, srcdir)
    line = 'replace %s => %s' % (mod, rel)
    s = re.sub(r'^replace %s => .*$' % re.escape(mod),
               line.replace('\\', '\\\\'), s, flags=re.M)
    if ('replace %s =>' % mod) not in s:
        s = s.replace(base_pat, base_pat + line + '\n', 1)
open(gomod, 'w').write(s)
print('probe: go.mod replaces -> godeps/ (x/sys, x/net)')
PY

export GOFLAGS=-mod=mod
cd "$SRC"

# host server (linux/amd64) -- explicit GOOS/GOARCH override of the
# darwin/arm defaults exported by go-env.sh
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
    "$GOPORT" build -trimpath -buildvcs=false -ldflags "-s -w" \
    -o "$WORK/obfs4proxy-host" ./obfs4proxy
file "$WORK/obfs4proxy-host" | grep -q "ELF 64-bit" || {
    echo "obfs4proxy-host is not an ELF binary" >&2; exit 1; }

# pt drivers
GOOS=darwin GOARCH=arm GOARM=7 CGO_ENABLED=0 \
    "$GOPORT" build -trimpath -buildvcs=false -ldflags "-s -w" \
    -o "$WORK/pt-driver-armv7" "$here/pt-driver.go"
file "$WORK/pt-driver-armv7" | grep -q "Mach-O armv7 executable" || {
    echo "pt-driver-armv7 is not a Mach-O armv7 executable" >&2; exit 1; }
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
    "$GOPORT" build -trimpath -buildvcs=false -ldflags "-s -w" \
    -o "$WORK/pt-driver-host" "$here/pt-driver.go"

echo "==> $WORK/{obfs4proxy-host,pt-driver-armv7,pt-driver-host}"
