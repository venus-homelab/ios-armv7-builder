#!/bin/bash
# Build git-lfs 3.8.1 for armv7 iOS 10.x with the Go 1.27.2 darwin/arm
# revived toolchain.
#
# Second canary for the Go reproducible template (net/tailscale,
# net/tailcat; first canary: tools/fzf).  git-lfs is a heavier dependency
# graph than fzf -- x/net AND x/sys both land in the binary (lfshttp /
# lfsapi pull x/net's http2+context; go-isatty pulls x/sys) -- so it
# exercises both adapted trees in godeps/:
#
#   * pristine source from the upstream release tag archive (sources.lock
#     row git-lfs) via tools/fetch-src.sh;
#   * go.mod replace lines ADDED after extraction: x/sys ->
#     godeps/xsys-darwin-arm, x/net -> godeps/xnet-darwin-arm (upstream
#     carries no replace lines);
#   * golang.org/x/crypto (indirect, v0.54) is NOT replaced -- it is pure Go
#     for everything git-lfs reaches (via x/net and the kerberos/spnego
#     credential path) and resolves from the module proxy like upstream;
#   * the revived host toolchain builds on demand via ../../lang/go/build.sh;
#   * the check-undefined gate runs on the binary (Go binaries on this
#     target are libSystem-linked even with CGO_ENABLED=0; the tbd whitelist
#     covers them -- verified tailscale 101/101, tailcat 116/116).
#
# Reproducibility contract (byte-ab.sh): -trimpath, -buildvcs=false, -s -w
# (the -s -w is also REQUIRED: darwin/arm linker's __DWARF filesize>vmsize
# bug, docs/go.md).  config.Version defaults to the upstream value in the
# source ("3.8.1"); no -X stamp needed.  git-lfs's Makefile GIT_LFS_SHA
# stamp is skipped deliberately: the tarball has no git metadata and we do
# not fabricate a commit hash.
#
# Non-negotiable environment (see tailscale/build.sh):
#   * GOTOOLCHAIN=local -- an upstream go1.2x toolchain has NO darwin/arm.
#   * TMPDIR/GOMODCACHE under $root/tmp -- host /tmp is a small tmpfs
#     (AGENTS.md rule 0).
#   * GOPROXY=goproxy.cn -- proxy.golang.org hangs here.
#
# Usage:
#   ./git-lfs/build.sh                    # -> ../out/git-lfs-<ver>-armv7
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
GO_VERSION="${GO_VERSION:-1.27.2}"
VER="${LFS_VERSION:-3.8.1}"

# ---- revived toolchain + env iron rules (shared snippet, 2026-11-25 extraction) ----
source "$root/tools/go-env.sh"

# ---- pristine source via the verified path -------------------------------
SRC="$root/tmp/src/git-lfs-$VER"
if [ ! -f "$SRC/go.mod" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock git-lfs)"
    tarball="$("$root/tools/fetch-src.sh" git-lfs "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/go.mod" ] || { echo "git-lfs source layout unexpected" >&2; exit 1; }

# ---- wire the adapted dependency trees (godeps/) into go.mod -------------
# The upstream go.mod has no replace lines; ours are ADDITIONS.  The go
# directive is only pinned when upstream demands a NEWER go than the revived
# port provides (git-lfs 3.8.1 says 1.25.0 -- leave lower directives alone:
# bumping them changes language semantics).
#
# The replace paths MUST be relative (../../../godeps/... from
# tmp/src/git-lfs-*/ == $root/godeps/...): an absolute path is recorded
# VERBATIM in the binary's embedded build info ("=> /abs/path (devel)"),
# which -trimpath does NOT scrub -- two builds at different absolute paths
# would differ byte-for-byte and fail tools/byte-ab.sh.  Relative paths make
# the build tree-layout-only.
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
        s = s.replace('module github.com/git-lfs/git-lfs/v3\n',
                      f'module github.com/git-lfs/git-lfs/v3\n\n{line}\n', 1)
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
    -ldflags "-s -w" \
    -o "$OUT/git-lfs-$VER-armv7" .

# The output must be a Mach-O executable; same loud check as tailscale.
file "$OUT/git-lfs-$VER-armv7" | grep -q "Mach-O armv7 executable" || {
    echo "output is not a Mach-O armv7 executable:" >&2
    file "$OUT/git-lfs-$VER-armv7" >&2
    exit 1
}

# ---- gate: every undefined symbol must resolve from a device dylib ------
"$root/tools/check-undefined.sh" "$OUT/git-lfs-$VER-armv7"

echo "==> $OUT/git-lfs-$VER-armv7"
echo "    deploy: via git-lfs/make-deb.sh (deb re-signs on device in postinst)"
