#!/bin/bash
# Build the Go 1.27.2 darwin/arm revived port for armv7 iOS 10.x.
#
# Two artifacts:
#   * a host (linux/amd64) GOROOT that can cross-compile darwin/arm —
#     this is what tailcat and every other Go program in this repo is
#     built with (~/scratch/go-port is one such tree);
#   * an on-device toolchain tgz (bin/go + pkg/tool/darwin_arm/* + src +
#     pkg/include) that runs `go build` on the iPad itself.
#
# Everything that differs from upstream go1.27.2 lives in patches/
# (see patches/README.md for the why of every hunk).  The runtime fixes
# are load-bearing: without them every libc call trashes the trampoline
# return address (pc=0xc), os.File.Seek fails with EINVAL, directory
# iteration corrupts, and multi-threaded programs hang on SIGURG.
#
# Usage:
#   ./go/build.sh                          # -> out/go-host-*, out/goroot-arm-*
#   GO_TAR=/path/to/go1.27.2.src.tar.gz ./go/build.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
GO_VERSION="${GO_VERSION:-1.27.2}"
GO_TAR="${GO_TAR:-$HOME/go-sdk/go$GO_VERSION.src.tar.gz}"
BOOTSTRAP="${GOROOT_BOOTSTRAP:-$HOME/go-sdk/go1.27.2}"

# sources.lock: go 1.27.2 (aliyun mirror of the official golang.org source
# tarball -- both serve the identical bytes; the mirror is what this host
# reaches fastest).  $GO_TAR keeps its legacy path (hardlinked from the cache)
# because other scripts reference it.
"$root/tools/fetch-src.sh" go \
    "https://mirrors.aliyun.com/golang/go$GO_VERSION.src.tar.gz" \
    "$(awk -F'\t' '$1=="go"{print $4}' "$root/sources.lock")" \
    "$GO_TAR" >/dev/null
# The bootstrap toolchain also comes through the verified path (2026-11-23
# Go-template work): fetch the pinned linux-amd64 distribution and extract
# it into the cache, unless a pre-staged bootstrap exists (the legacy path).
[ -x "$BOOTSTRAP/bin/go" ] || {
    read -r BU BSHA _ <<<"$("$root/tools/fetch-src.sh" --lock go-bootstrap)"
    btgz="$("$root/tools/fetch-src.sh" go-bootstrap "$BU" "$BSHA")"
    rm -rf "$root/tmp/go-bootstrap"
    mkdir -p "$root/tmp"
    tar -C "$root/tmp" -xzf "$btgz"
    mv "$root/tmp/go" "$root/tmp/go-bootstrap"
    BOOTSTRAP="$root/tmp/go-bootstrap"
    export GOROOT_BOOTSTRAP="$BOOTSTRAP"
}
[ -x "$BOOTSTRAP/bin/go" ] || {
    echo "bootstrap toolchain not found at $BOOTSTRAP/bin/go" >&2
    exit 1
}

# /tmp on this host is a small tmpfs with per-user quota — Go builds
# (make.bash $WORK, link output) exceed it with "disk quota exceeded".
# Work on the root filesystem instead.
export TMPDIR="${TMPDIR:-$root/tmp}"
mkdir -p "$TMPDIR"
# mktemp must stay on the root filesystem (AGENTS.md rule 0): the extracted
# go source tree is ~100MB and the default /tmp is a small tmpfs.
work="$(mktemp -d "$root/tmp/go-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- unpack official sources and apply the port patches -------------------
mkdir -p "$work/goroot"
tar xzf "$GO_TAR" -C "$work/goroot" --strip-components=1
cd "$work/goroot"
for p in "$here"/patches/[0-9]*.patch; do
    echo "==> applying $(basename "$p")"
    patch -p1 --silent < "$p"
done

# --- host toolchain (linux/amd64, cross-compiles darwin/arm) --------------
cd "$work/goroot/src"
export GOROOT_BOOTSTRAP="$BOOTSTRAP"
# GOROOT_FINAL pins the embedded defaultGOROOT to a CONSTANT path: without
# it make.bash bakes the random mktemp GOROOT into every host binary and
# rebuilds differ byte-for-byte (2026-11-25 audit).  /var/mobile/tools/goroot
# is the deb install layout, so the device default is also correct.
export GOROOT_FINAL=/var/mobile/tools/goroot
unset GOOS GOARCH GOARM CGO_ENABLED 2>/dev/null || true
./make.bash 2>&1 | tail -3
export GOROOT="$work/goroot"

# --- sanity: the fresh host toolchain cross-builds a darwin/arm binary ----
cat > "$work/hello.go" <<'EOF'
package main
import "fmt"
func main() { fmt.Println("ok") }
EOF
GOOS=darwin GOARCH=arm GOARM=7 CGO_ENABLED=0 \
    "$work/goroot/bin/go" build -o "$work/hello" "$work/hello.go"
file "$work/hello" | grep -q "Mach-O armv7 executable" || {
    echo "sanity build did not produce a Mach-O armv7 executable" >&2; exit 1
}

# --- host toolchain artifact (before bin/go is replaced below) ------------
mkdir -p "$OUT"
tar czf "$OUT/go-host-$GO_VERSION-linux-amd64.tgz" -C "$work/goroot" \
    bin pkg/tool/linux_amd64 src pkg/include api VERSION

# --- on-device toolchain: cross-build the five commands (darwin/arm) -----
# Build to a temp name first: overwriting bin/go (the linux/amd64 host go)
# before the other four are built would leave the loop with no working
# compiler.
GOOS=darwin GOARCH=arm GOARM=7 CGO_ENABLED=0 "$work/goroot/bin/go" \
    build -trimpath -ldflags "-s -w" -o "$work/goroot/bin/go.darwinarm" ./cmd/go \
    || { echo "cross-build of cmd/go failed" >&2; exit 1; }
file "$work/goroot/bin/go.darwinarm" | grep -q "Mach-O armv7 executable" || {
    echo "cmd/go output is not a Mach-O armv7 executable" >&2; exit 1
}
for t in compile link asm vet; do
    GOOS=darwin GOARCH=arm GOARM=7 CGO_ENABLED=0 "$work/goroot/bin/go" \
        build -trimpath -ldflags "-s -w" -o "$work/goroot/pkg/tool/darwin_arm/$t" ./cmd/$t \
        || { echo "cross-build of cmd/$t failed" >&2; exit 1; }
    file "$work/goroot/pkg/tool/darwin_arm/$t" | grep -q "Mach-O armv7 executable" || {
        echo "cmd/$t output is not a Mach-O armv7 executable" >&2
        file "$work/goroot/pkg/tool/darwin_arm/$t" >&2
        exit 1
    }
done
mv "$work/goroot/bin/go.darwinarm" "$work/goroot/bin/go"

# The on-device tgz mirrors the layout /var/mobile/tools/goroot expects.
tar czf "$OUT/goroot-arm-$GO_VERSION.tgz" -C "$work/goroot" \
    bin/go pkg/tool/darwin_arm src pkg/include

echo "==> $OUT/goroot-arm-$GO_VERSION.tgz   (on-device toolchain)"
echo "==> $OUT/go-host-$GO_VERSION-linux-amd64.tgz (host cross toolchain)"
echo "    sanity build: $(file "$work/hello" | sed 's/.*: //')"
