#!/bin/bash
# Build tailscale v1.104.7 (CLI + daemon) for armv7 iOS 10.x with the
# Go 1.27.2 darwin/arm revived toolchain.
#
# The first tailscale ever to build for GOOS=darwin GOARCH=arm -- possible
# because of the revived port (go/patches/, docs/go.md) and the dependency
# adaptation set inherited from the tailcat 0.7.0 port
# (docs/tailcat-porting.md), committed in full under godeps/:
# x/sys v0.48 darwin/arm (+RTF_GLOBAL/RTF_DEAD/RTF_LLDATA for 32-bit, see
# docs/tailscale.md wall #1), x/net v0.60, u-root v0.16.
#
# Fully fetch-src-wired (2026-11-23 Go-template work):
#   * the pristine source comes from the GitHub tag archive (sources.lock);
#   * the adapted dependency trees live in ../godeps/ and are wired in by
#     rewriting go.mod's `replace` lines after extraction;
#   * the revived host toolchain is built on demand by ../lang/go/build.sh
#     (fetch -> patches -> make.bash -> sanity), then extracted from its
#     out/go-host-*.tgz artifact;
#   * every other dependency resolves from go.sum through the module proxy.
#
# Non-negotiable environment for this build:
#   * GOTOOLCHAIN=local -- the patched go.mod says `go 1.27.2`; with the
#     default `auto` go would fetch an UPSTREAM 1.27.x toolchain, which has
#     no darwin/arm target at all.
#   * TMPDIR off /tmp -- the host tmpfs has a per-user quota that the
#     tailscaled compile blows through ("disk quota exceeded"; wall #2).
#   * GOPROXY=goproxy.cn -- proxy.golang.org hangs for minutes here.
#   * -s -w -- the darwin/arm linker's __DWARF vmsize bug (see go.md).
#
# Usage:
#   ./tailscale/build.sh                  # -> ../out/tailscale{,d}-<ver>-armv7
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
GO_VERSION="${GO_VERSION:-1.27.2}"
VER="${TS_VERSION:-1.104.7}"

# ---- revived toolchain + env iron rules (shared snippet, 2026-11-25 extraction) ----
source "$root/tools/go-env.sh"

# ---- pristine source via the verified path -------------------------------
SRC="$root/tmp/src/tailscale-$VER"
if [ ! -f "$SRC/go.mod" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock tailscale)"
    tarball="$("$root/tools/fetch-src.sh" tailscale "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/go.mod" ] || { echo "tailscale source layout unexpected" >&2; exit 1; }

# ---- wire the adapted dependency trees (godeps/) into go.mod -------------
# The pristine go.mod may or may not carry replace lines (the working
# checkout did); rewrite whatever replace lines exist to point at the
# in-repo adapted trees, so a stale absolute path can never leak in.
# Paths must be RELATIVE to go.mod (2026-11-24 byte-A/B wall #5): Go burns
# replace targets into the binary's build info ("=> <path> (devel)") and
# -trimpath does not clean BuildInfo -- an absolute path here ships the
# build host's filesystem layout inside the payload.
# -trimpath ON THE BUILD LINE is the other half (byte-A/B wall #9,
# 2026-11-25): without it the compiler records absolute source paths in
# pclntab (1733 "~" hits in the shipped tailscale binary), so
# payload bytes depended on where the tree happened to be extracted.
python3 - "$SRC/go.mod" "$root" <<'PY'
import os, re, sys
gomod, root = sys.argv[1], sys.argv[2]
s = open(gomod).read()
base = os.path.dirname(os.path.abspath(gomod))
def rel(tree):
    return os.path.relpath(os.path.join(root, 'godeps', tree), base)
mapping = {
    'golang.org/x/sys':      rel('xsys-darwin-arm'),
    'golang.org/x/net':      rel('xnet-darwin-arm'),
    'github.com/u-root/u-root': rel('uroot-darwin-arm'),
}
for mod, path in mapping.items():
    line = f'replace {mod} => {path}'
    s = re.sub(rf'^replace {re.escape(mod)} => .*$',
               line.replace('\\', '\\\\'), s, flags=re.M)
    if f'replace {mod} =>' not in s:
        s = s.replace('module tailscale.com\n',
                      f'module tailscale.com\n\n{line}\n', 1)
# upstream moves its `go` directive faster than the revived port tracks:
# 1.104.7 wants go >= 1.27.4, the ported toolchain is 1.27.2.  Pin the
# directive to the toolchain and drop any `toolchain` line (GOTOOLCHAIN=local
# forbids upgrades anyway -- fail loud here instead of at build time).
s = re.sub(r'^go 1\.[0-9.]+$', 'go 1.27.2', s, flags=re.M)
s = re.sub(r'^toolchain .*\n', '', s, flags=re.M)
open(gomod, 'w').write(s)
print("go.mod: replaces -> godeps/, go directive -> 1.27.2")
PY

mkdir -p "$OUT"

LDF="-s -w -X tailscale.com/version.longStamp=v$VER -X tailscale.com/version.shortStamp=$VER"

cd "$SRC"
for cmd in tailscale tailscaled; do
    GOOS=darwin GOARCH=arm GOARM=7 CGO_ENABLED=0 \
        "$GOPORT" build -trimpath -tags netgo -ldflags "$LDF" \
        -o "$OUT/$cmd-$VER-armv7" "./cmd/$cmd"
    file "$OUT/$cmd-$VER-armv7" | grep -q "Mach-O armv7 executable" || {
        echo "$cmd: output is not a Mach-O armv7 executable:" >&2
        file "$OUT/$cmd-$VER-armv7" >&2
        exit 1
    }
    echo "==> $OUT/$cmd-$VER-armv7"
done
echo "    deploy: scp both to the device, then (as root) chmod 755 + chown mobile:mobile + ldid -S"
echo "    run:    tailscaled --tun=userspace-networking   (iOS 10 has no /dev/tun)"
