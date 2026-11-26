#!/bin/bash
# Build tailcat (Go 1.27.2 darwin/arm revived port) for armv7 iOS 10.x.
#
# tailcat is the first real Go program to run on this target, and it is only
# possible because of the runtime fixes recorded in ../docs/tailcat-porting.md
# (the go/patches/ set): without them every libc call trashed the
# trampoline's return address and died at pc=0xc.
#
# Fully fetch-src-wired (2026-11-23; corrected the same day -- the first
# cut vendored the upstream tree into the repo, which is exactly what the
# fetch-src rule exists to prevent):
#   * pristine source from the upstream tag (sources.lock row tailcat) --
#     tailcat is github.com/tailscale/tailcat, a real upstream with
#     releases, NOT our code;
#   * the darwin/arm dependency adaptations come from ../godeps/ and are
#     wired in by ADDING go.mod replace lines after extraction (the
#     upstream go.mod has none);
#   * the revived host toolchain builds on demand via ../go/build.sh.
#
# Toolchain notes that must stay true:
#   * GOTOOLCHAIN=local -- the patched go.mod says `go 1.27.2`; with the
#     default `auto` go would fetch an UPSTREAM 1.27.x toolchain, which has
#     no darwin/arm target at all.
#   * TMPDIR off /tmp -- the host tmpfs quota killed a tailscaled compile
#     once (wall #2); the same applies here.
#   * -s -w is required: without it the linker emits a __DWARF segment with
#     filesize > vmsize and dyld refuses the image (known linker bug, see
#     docs/tailcat-porting.md).
#
# Usage:
#   ./tailcat/build.sh                    # -> ../out/tailcat-<ver>-armv7
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
GO_VERSION="${GO_VERSION:-1.27.2}"
SRC="$here/src"
VER="${TCT_VERSION:-0.7.0}"

# ---- pristine source via the verified path -------------------------------
SRC="$root/tmp/src/tailcat-$VER"
if [ ! -f "$SRC/go.mod" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock tailcat)"
    tarball="$("$root/tools/fetch-src.sh" tailcat "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/go.mod" ] || { echo "tailcat source layout unexpected" >&2; exit 1; }

# ---- revived toolchain + env iron rules (shared snippet, 2026-11-25 extraction) ----
source "$root/tools/go-env.sh"

# ---- wire the adapted dependency trees (godeps/) into go.mod -------------
# The UPSTREAM go.mod has no replace lines; ours are ADDITIONS pointing at
# the in-repo adapted trees.  Paths are RELATIVE to go.mod on purpose
# (2026-11-24 byte-A/B wall #5): Go burns replace targets into the binary's
# build info and -trimpath does not clean BuildInfo, so an absolute path
# would ship the build host's layout inside the payload.
# -trimpath ON THE BUILD LINE is the other half (byte-A/B wall #9,
# 2026-11-25): without it pclntab carries absolute source paths and the
# payload bytes depend on the extraction location.
python3 - "$SRC/go.mod" "$root" <<'PY'
import os, sys
gomod, root = sys.argv[1], sys.argv[2]
s = open(gomod).read()
base = os.path.dirname(os.path.abspath(gomod))
def rel(tree):
    return os.path.relpath(os.path.join(root, 'godeps', tree), base)
lines = [f'replace {mod} => {rel(tree)}'
         for mod, tree in [('golang.org/x/sys', 'xsys-darwin-arm'),
                           ('golang.org/x/net', 'xnet-darwin-arm'),
                           ('github.com/u-root/u-root', 'uroot-darwin-arm')]]
if not any('replace golang.org/x/sys' in l for l in s.splitlines()):
    s = s.replace('module github.com/tailscale/tailcat\n',
                  'module github.com/tailscale/tailcat\n\n' + '\n'.join(lines) + '\n', 1)
open(gomod, 'w').write(s)
print("go.mod replace lines -> godeps/ (added)")
PY

# the upstream v0.7.0 go.sum misses entries for parts of the module graph
# (golang.org/x/tools' mod file) -- let the toolchain resolve and record
# them instead of failing loud mid-build
export GOFLAGS=-mod=mod

mkdir -p "$OUT"

cd "$SRC"
"$GOPORT" mod download >/dev/null 2>&1 || true
GOOS=darwin GOARCH=arm GOARM=7 CGO_ENABLED=0 \
    "$GOPORT" build -trimpath -tags netgo -ldflags "-s -w" \
    -o "$OUT/tailcat-$VER-armv7" ./cmd/tailcat

# The output must be a Mach-O executable; building the repo root instead of
# ./cmd/tailcat would hand back an ar archive for the library, and this check
# keeps that mistake loud instead of shipping it.
file "$OUT/tailcat-$VER-armv7" | grep -q "Mach-O armv7 executable" || {
    echo "output is not a Mach-O armv7 executable:" >&2
    file "$OUT/tailcat-$VER-armv7" >&2
    exit 1
}

echo "==> $OUT/tailcat-$VER-armv7"
echo "    deploy: scp it to the device, then (as root) chmod 755 + chown mobile:mobile + ldid -S"
