#!/bin/bash
# Build dnscrypt-proxy 2.1.21 (DNSCrypt/dnscrypt-proxy) for armv7 iOS 10.x
# with the Go 1.27.2 darwin/arm revived toolchain.
#
# A local DNS proxy: accepts plain DNS on 127.0.0.1:53 and forwards to
# DNSCrypt / DoH / DoQ / ODoH upstreams.  On the device it pairs with the
# local tor4 (SOCKS) and privoxy4 (HTTP) stack as the DNS leg.
#
# Template: tools/fzf/build.sh (go-app-template §一/§三), with these
# version-specific parts:
#
#   * pristine source from the upstream release tag archive (sources.lock
#     row dnscrypt-proxy) via tools/fetch-src.sh;
#   * godeps replaces: x/sys AND x/net both route through the darwin/arm
#     adapted trees (x/net is needed -- DoH speaks HTTP/2 via x/net);
#   * x/crypto, x/text, quic-go, qpack resolve from go.sum via the module
#     proxy (pure-Go on this target; quic-go is used in the CLIENT role
#     for DoQ -- the 2026-11-25 2x2 matrix proved the client role works
#     on armv7 while the server role does not, see docs/caddy.md §7);
#   * the main package lives in the dnscrypt-proxy/ subdirectory.
#
# Non-negotiable environment: GOTOOLCHAIN=local, TMPDIR/GOMODCACHE under
# $root/tmp, GOPROXY=goproxy.cn (see tools/go-env.sh, go-app-template §三).
#
# Usage:
#   ./dnscrypt-proxy/build.sh              # -> ../out/dnscrypt-proxy-<ver>-armv7
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
GO_VERSION="${GO_VERSION:-1.27.2}"
VER="${DNSCRYPT_VERSION:-2.1.21}"

source "$root/tools/go-env.sh"

# ---- pristine source via the verified path -------------------------------
SRC="$root/tmp/src/dnscrypt-proxy-$VER"
if [ ! -f "$SRC/go.mod" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock dnscrypt-proxy)"
    tarball="$("$root/tools/fetch-src.sh" dnscrypt-proxy "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/go.mod" ] || { echo "dnscrypt-proxy source layout unexpected" >&2; exit 1; }

# ---- wire the adapted dependency trees (godeps/) into go.mod -------------
# Replace paths are RELATIVE to go.mod (byte-A/B wall #5): x/sys (unix
# ioctl/sockopt surface) and x/net (HTTP/2 for DoH) both have darwin/arm
# adaptations in godeps/.  x/crypto, x/text, quic-go, qpack stay on the
# module proxy -- they are pure Go here.
python3 - "$SRC/go.mod" <<'PY'
import re, sys
gomod = sys.argv[1]
s = open(gomod).read()
# module path is lowercase dnscrypt upstream; the go directive says 1.27.4
# while the revived port is 1.27.2 (GOTOOLCHAIN=local refuses) -- pin it
# down, same as the tailscale 1.104.7 precedent (docs/tailscale.md).
base_pat = 'module github.com/dnscrypt/dnscrypt-proxy\n'
mapping = {'golang.org/x/sys': '../../../godeps/xsys-darwin-arm',
           'golang.org/x/net': '../../../godeps/xnet-darwin-arm'}
for mod, path in mapping.items():
    line = f'replace {mod} => {path}'
    s = re.sub(rf'^replace {re.escape(mod)} => .*$',
               line.replace('\\', '\\\\'), s, flags=re.M)
    if f'replace {mod} =>' not in s:
        s = s.replace(base_pat, f'{base_pat}\n{line}\n', 1)
s = re.sub(r'^toolchain .*\n', '', s, flags=re.M)
s = re.sub(r'^go 1\.27\.[4-9]$', 'go 1.27.2', s, flags=re.M)
s = re.sub(r'^go 1\.(2[89]|[3-9][0-9])(\.[0-9]+)?$', 'go 1.27.2', s, flags=re.M)
open(gomod, 'w').write(s)
print("go.mod: replaces -> godeps/ (x/sys, x/net), go directive pinned 1.27.2")
PY

# ---- darwin/arm(32) syscall gap: IPV6_TCLASS ----------------------------
# upstream setsockopts_darwin.go uses syscall.IPV6_TCLASS; the arm64 port
# has it but the 32-bit revival's syscall package does not (darwin value
# 0x3d per netinet6/in6.h).  Idempotent source patch, deterministic.
python3 - "$SRC/dnscrypt-proxy/setsockopts_darwin.go" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'IPV6_TCLASS' in s and 'ipv6TClassDarwin' not in s:
    shim = ('// darwin/arm(32) syscall gap: IPV6_TCLASS=0x3d (netinet6/in6.h);\n'
            '// the revived 32-bit syscall package lacks it (2026-11-25).\n'
            'const ipv6TClassDarwin = 0x3d\n')
    s = s.replace('syscall.IPV6_TCLASS', 'ipv6TClassDarwin')
    s = s.rstrip('\n') + '\n\n' + shim
    open(p, 'w').write(s)
    print('patched: syscall.IPV6_TCLASS -> ipv6TClassDarwin (0x3d)')
PY

export GOFLAGS=-mod=mod
mkdir -p "$OUT"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

cd "$SRC/dnscrypt-proxy"
GOOS=darwin GOARCH=arm GOARM=7 CGO_ENABLED=0 \
    "$GOPORT" build -trimpath -buildvcs=false \
    -ldflags "-s -w" \
    -o "$OUT/dnscrypt-proxy-$VER-armv7" .

file "$OUT/dnscrypt-proxy-$VER-armv7" | grep -q "Mach-O armv7 executable" || {
    echo "output is not a Mach-O armv7 executable:" >&2
    file "$OUT/dnscrypt-proxy-$VER-armv7" >&2
    exit 1
}

# ---- gate: every undefined symbol must resolve from a device dylib ------
"$root/tools/check-undefined.sh" "$OUT/dnscrypt-proxy-$VER-armv7"

echo "==> $OUT/dnscrypt-proxy-$VER-armv7"
echo "    deploy: via dnscrypt-proxy/make-deb.sh (deb re-signs on device in postinst)"
