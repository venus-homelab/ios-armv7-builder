# shellcheck shell=bash  # sourced snippet, not executed directly
# tools/go-env.sh -- sourced by every Go package build.sh: revived-toolchain
# ensure + the environment iron rules.  Extracted 2026-11-25 (audit backlog:
# five build.sh files carried ~60 identical lines; fzf/git-lfs/caddy ports
# copied tailscale's block and drift risk grew with each copy).
#
# Usage (after GO_VERSION and $root are set in the caller):
#     source "$root/tools/go-env.sh"
# Provides: GOPORT (the revived darwin/arm go binary), the toolchain
# extracted under $root/tmp/go-revived, and the environment exports below.
# Does NOT touch go.mod (godeps replace wiring stays per-package), does not
# build, does not sign.  See docs/go-app-template.md §一/§三.

: "${GO_VERSION:?GO_VERSION must be set before sourcing go-env.sh}"
: "${root:?root must be set before sourcing go-env.sh}"

# ---- revived host toolchain: build on demand, then extract ---------------
HOSTTGZ="${HOSTTGZ:-$root/out/go-host-$GO_VERSION-linux-amd64.tgz}"
if [ ! -s "$HOSTTGZ" ]; then
    echo "==> no revived toolchain artifact -- building it (lang/go/build.sh)"
    ( cd "$root/lang/go" && GO_VERSION="$GO_VERSION" ./build.sh )
fi
[ -s "$HOSTTGZ" ] || { echo "toolchain artifact missing: $HOSTTGZ" >&2; exit 1; }
GOROOT_REV="$root/tmp/go-revived"
if [ ! -x "$GOROOT_REV/bin/go" ]; then
    rm -rf "$GOROOT_REV"
    # the tgz members are the GOROOT layout itself (bin/ pkg/ src/ ...,
    # flattened by go/build.sh's -C) -- extract straight into the target
    mkdir -p "$GOROOT_REV"
    tar xzf "$HOSTTGZ" -C "$GOROOT_REV"
fi
GOPORT="$GOROOT_REV/bin/go"

# ---- environment iron rules (docs/go-app-template.md §三) ----------------
export GOTOOLCHAIN=local
export CGO_ENABLED=0
export GOOS=darwin GOARCH=arm GOARM=7
# the host may carry an explicitly-empty GOSUMDB; go.sum remains the
# integrity anchor, the transparency log is optional for a pinned build
export GOSUMDB="${GOSUMDB:-off}"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export TMPDIR="${TMPDIR:-$root/tmp}"
mkdir -p "$TMPDIR"
export GOMODCACHE="${GOMODCACHE:-$root/tmp/gomodcache}"
