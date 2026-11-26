#!/bin/bash
# Build fzf 0.75.0 (junegunn/fzf) for armv7 iOS 10.x with the Go 1.27.2
# darwin/arm revived toolchain.
#
# This package is a CANARY for the Go reproducible template (net/tailscale,
# net/tailcat): a third-party pure-Go program that must build + package +
# byte-A/B reproduce without touching the template.  Everything below is the
# tailscale/build.sh recipe with only the version-specific parts swapped:
#
#   * pristine source from the upstream release tag archive (sources.lock
#     row fzf) via tools/fetch-src.sh;
#   * the darwin/arm dependency adaptation comes from ../godeps/: fzf needs
#     ONLY golang.org/x/sys (tcell + x/term route their ioctls through it),
#     so a single replace line is added after extraction;
#   * the revived host toolchain builds on demand via ../../lang/go/build.sh,
#     then is extracted from the out/go-host-*.tgz artifact;
#   * the check-undefined gate runs on the binary (Go binaries on this target
#     are libSystem-linked even with CGO_ENABLED=0 -- the tbd whitelist
#     already covers them, verified against tailscale 101/101 and tailcat
#     116/116).
#
# Reproducibility contract (byte-ab.sh):
#   * -trimpath (kills build-path and module-cache-path leakage),
#   * -buildvcs=false (tarball has no .git; never stamp VCS state),
#   * -s -w (the darwin/arm linker's __DWARF filesize>vmsize bug, see
#     docs/go.md; also shrinks the surface path leakage could hit),
#   * version/revision stamped explicitly via -X main.version/main.revision
#     so `fzf --version` never depends on the build directory's git state.
#
# Non-negotiable environment (see tailscale/build.sh):
#   * GOTOOLCHAIN=local -- an upstream go1.2x toolchain has NO darwin/arm.
#   * TMPDIR/GOMODCACHE under $root/tmp -- host /tmp is a small tmpfs
#     (AGENTS.md rule 0).
#   * GOPROXY=goproxy.cn -- proxy.golang.org hangs here.
#
# Usage:
#   ./fzf/build.sh                        # -> ../out/fzf-<ver>-armv7
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
GO_VERSION="${GO_VERSION:-1.27.2}"
VER="${FZF_VERSION:-0.75.0}"

# ---- revived toolchain + env iron rules (shared snippet, 2026-11-25 extraction) ----
source "$root/tools/go-env.sh"

# ---- pristine source via the verified path -------------------------------
SRC="$root/tmp/src/fzf-$VER"
if [ ! -f "$SRC/go.mod" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock fzf)"
    tarball="$("$root/tools/fetch-src.sh" fzf "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/go.mod" ] || { echo "fzf source layout unexpected" >&2; exit 1; }

# ---- wire the adapted dependency tree (godeps/) into go.mod -------------
# The upstream go.mod has no replace lines; ours is an ADDITION.  The go
# directive is only pinned when upstream demands a NEWER go than the revived
# port provides -- bumping a lower directive (fzf 0.75.0 says 1.23.0) would
# change language semantics, which is exactly what a canary must not do.
#
# The replace path MUST be relative (../../../godeps/... from tmp/src/fzf-*/
# == $root/godeps/...): an absolute path is recorded VERBATIM in the binary's
# embedded build info ("=> /abs/path (devel)"), which -trimpath does NOT
# scrub -- two builds at different absolute paths would differ byte-for-byte
# and fail tools/byte-ab.sh.  Relative paths make the build tree-layout-only.
python3 - "$SRC/go.mod" <<'PY'
import re, sys
gomod = sys.argv[1]
s = open(gomod).read()
mapping = {'golang.org/x/sys': '../../../godeps/xsys-darwin-arm'}
for mod, path in mapping.items():
    line = f'replace {mod} => {path}'
    s = re.sub(rf'^replace {re.escape(mod)} => .*$',
               line.replace('\\', '\\\\'), s, flags=re.M)
    if f'replace {mod} =>' not in s:
        s = s.replace('module github.com/junegunn/fzf\n',
                      f'module github.com/junegunn/fzf\n\n{line}\n', 1)
# GOTOOLCHAIN=local forbids upgrades anyway -- fail loud here instead.
s = re.sub(r'^toolchain .*\n', '', s, flags=re.M)
s = re.sub(r'^go 1\.(2[89]|[3-9][0-9])(\.[0-9]+)?$', 'go 1.27.2', s, flags=re.M)
open(gomod, 'w').write(s)
print("go.mod: replace x/sys -> godeps/xsys-darwin-arm (added)")
PY

mkdir -p "$OUT"
# clamp any wall-clock the toolchain might embed (byte-ab lever; a plain
# build embeds no timestamps, but pinning costs nothing and protects the
# contract)
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

cd "$SRC"
"$GOPORT" mod download >/dev/null 2>&1 || true
GOOS=darwin GOARCH=arm GOARM=7 CGO_ENABLED=0 \
    "$GOPORT" build -trimpath -buildvcs=false \
    -ldflags "-s -w -X main.version=$VER -X main.revision=v$VER" \
    -o "$OUT/fzf-$VER-armv7" .

# The output must be a Mach-O executable; same loud check as tailscale.
file "$OUT/fzf-$VER-armv7" | grep -q "Mach-O armv7 executable" || {
    echo "output is not a Mach-O armv7 executable:" >&2
    file "$OUT/fzf-$VER-armv7" >&2
    exit 1
}

# ---- gate: every undefined symbol must resolve from a device dylib ------
"$root/tools/check-undefined.sh" "$OUT/fzf-$VER-armv7"

echo "==> $OUT/fzf-$VER-armv7"
echo "    deploy: via fzf/make-deb.sh (deb re-signs on device in postinst)"
