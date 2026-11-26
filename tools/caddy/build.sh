#!/bin/bash
# Build caddy 2.11.9 (caddyserver/caddy) for armv7 iOS 10.x with the Go
# 1.27.2 darwin/arm revived toolchain.
#
# Third-party Go program through the Go reproducible template
# (docs/go-app-template.md; canaries: net/tailscale, net/tailcat,
# tools/fzf, tools/git-lfs).  caddy is the heaviest graph so far
# (~200 direct+indirect modules, ~1.8 GB in GOMODCACHE), but the recipe
# is the git-lfs shape with only the version-specific parts swapped:
#
#   * pristine source from the upstream release tag archive (sources.lock
#     row caddy, pinned to the release page's latest stable v2.11.9,
#     2026-11-05) via tools/fetch-src.sh;
#   * go.mod replace lines ADDED after extraction: x/sys ->
#     godeps/xsys-darwin-arm, x/net -> godeps/xnet-darwin-arm.  caddy
#     pins EXACTLY the adapted trees' versions (x/sys v0.48.0, x/net
#     v0.60.0), so the replaces are drop-in with no MVS movement;
#   * the go directive is only pinned when upstream demands a NEWER go
#     than the revived port provides.  caddy 2.11.9 says `go 1.26.0` and
#     the whole dependency graph tops out at 1.26.0 (measured with
#     `go list -m -f '{{.GoVersion}}' all`) -- BELOW the 1.27.2
#     toolchain, so NOTHING is clamped this time (the predicted
#     >1.27.2 shape did not materialize; the guard below still fails
#     loud if a future bump lands).
#   * the revived host toolchain builds on demand via ../../lang/go/build.sh;
#   * version stamping: `go build ./cmd/caddy` leaves `caddy version`
#     reporting "unknown" (caddy looks itself up in build-info Deps,
#     which only works when built as a dependency a la XCADDY).  We do
#     NOT use XCADDY; the upstream-sanctioned alternative is the
#     CustomVersion var (caddy.go documents
#     `-ldflags '-X github.com/caddyserver/caddy/v2.CustomVersion=...'`).
#     Like fzf's -X main.version this makes the version independent of
#     the build directory's git state (byte-ab contract).
#   * the check-undefined gate runs on the binary (pure Go, CGO off;
#     the darwin/arm port still links libSystem dynamically for
#     syscalls -- the tbd whitelist covers it, verified tailscale
#     101/101, tailcat 116/116, fzf, git-lfs).
#
# HTTP/3 note: quic-go v0.63.0 carries NO build constraint excluding
# darwin/arm (its darwin files are gated by `//go:build darwin` only),
# and this build compiles it in.  Whether the QUIC runtime actually
# works on 32-bit ARM (64-bit atomic alignment) is a DEVICE-side
# question -- plain HTTP file-server acceptance never exercises it;
# see docs/caddy.md for the honest untested-surface note.
#
# Reproducibility contract (byte-ab.sh): -trimpath, -buildvcs=false,
# -s -w (the -s -w is also REQUIRED: darwin/arm linker's __DWARF
# filesize>vmsize bug, docs/go.md).
#
# Non-negotiable environment (see tailscale/build.sh):
#   * GOTOOLCHAIN=local -- an upstream go1.2x toolchain has NO darwin/arm.
#   * TMPDIR/GOMODCACHE under $root/tmp -- host /tmp is a small tmpfs
#     (AGENTS.md rule 0); caddy's module tree alone is ~1.8 GB.
#   * GOPROXY=goproxy.cn -- proxy.golang.org hangs here.
#
# Usage:
#   ./caddy/build.sh                      # -> ../out/caddy-<ver>-armv7
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
GO_VERSION="${GO_VERSION:-1.27.2}"
VER="${CADDY_VERSION:-2.11.9}"

# ---- revived toolchain + env iron rules (shared snippet, 2026-11-25 extraction) ----
source "$root/tools/go-env.sh"

# ---- pristine source via the verified path -------------------------------
SRC="$root/tmp/src/caddy-$VER"
if [ ! -f "$SRC/go.mod" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock caddy)"
    tarball="$("$root/tools/fetch-src.sh" caddy "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/go.mod" ] || { echo "caddy source layout unexpected" >&2; exit 1; }

# ---- wire the adapted dependency trees (godeps/) into go.mod -------------
# The upstream go.mod has no replace lines; ours are ADDITIONS.  caddy pins
# exactly x/sys v0.48.0 and x/net v0.60.0 -- the same versions the adapted
# trees are based on -- so no requirement in the graph moves.
#
# The replace paths MUST be relative (../../../godeps/... from
# tmp/src/caddy-*/ == $root/godeps/...): an absolute path is recorded
# VERBATIM in the binary's embedded build info ("=> /abs/path (devel)"),
# which -trimpath does NOT scrub -- two builds at different absolute paths
# would differ byte-for-byte and fail tools/byte-ab.sh (byte-ab wall #5).
#
# The go directive is only pinned when upstream demands a NEWER go than the
# revived port provides (caddy 2.11.9 says 1.26.0 -- leave lower directives
# alone: bumping them changes language semantics).
python3 - "$SRC/go.mod" <<'PY'
import re, sys
gomod = sys.argv[1]
s = open(gomod).read()
mapping = {
    'golang.org/x/sys': '../../../godeps/xsys-darwin-arm',
    'golang.org/x/net': '../../../godeps/xnet-darwin-arm',
}
for mod, path in mapping.items():
    line = f'replace {mod} => {path}'
    s = re.sub(rf'^replace {re.escape(mod)} => .*$',
               line.replace('\\', '\\\\'), s, flags=re.M)
    if f'replace {mod} =>' not in s:
        s = s.replace('module github.com/caddyserver/caddy/v2\n',
                      f'module github.com/caddyserver/caddy/v2\n\n{line}\n', 1)
# GOTOOLCHAIN=local forbids upgrades anyway -- fail loud here instead.
s = re.sub(r'^toolchain .*\n', '', s, flags=re.M)
s = re.sub(r'^go 1\.(2[89]|[3-9][0-9])(\.[0-9]+)?$', 'go 1.27.2', s, flags=re.M)
open(gomod, 'w').write(s)
print("go.mod: replaces -> godeps/xsys-darwin-arm, godeps/xnet-darwin-arm (added)")
PY

mkdir -p "$OUT"
# clamp any wall-clock the toolchain might embed (byte-ab lever)
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

cd "$SRC"
"$GOPORT" mod download >/dev/null 2>&1 || true
GOOS=darwin GOARCH=arm GOARM=7 CGO_ENABLED=0 \
    "$GOPORT" build -trimpath -buildvcs=false \
    -ldflags "-s -w -X github.com/caddyserver/caddy/v2.CustomVersion=v$VER" \
    -o "$OUT/caddy-$VER-armv7" ./cmd/caddy

# The output must be a Mach-O executable; same loud check as tailscale.
file "$OUT/caddy-$VER-armv7" | grep -q "Mach-O armv7 executable" || {
    echo "output is not a Mach-O armv7 executable:" >&2
    file "$OUT/caddy-$VER-armv7" >&2
    exit 1
}

# ---- gate: every undefined symbol must resolve from a device dylib ------
"$root/tools/check-undefined.sh" "$OUT/caddy-$VER-armv7"

echo "==> $OUT/caddy-$VER-armv7"
echo "    deploy: via caddy/make-deb.sh (deb re-signs on device in postinst)"
