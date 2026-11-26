#!/bin/bash
# Build obfs4proxy 0.0.14 (gitlab.com/yawning/obfs4) for armv7 iOS 10.x
# with the revived Go 1.27.2 darwin/arm toolchain.
#
# obfs4proxy is tor's pluggable transport that disguises tor traffic as
# random-looking TCP.  On the device it runs the CLIENT role (tor's
# ClientTransportPlugin: tor <-> obfs4proxy speaks the pt env/stdio
# protocol, obfs4proxy <-> bridge speaks obfs4).  The trigger for this
# port is hard evidence: tor4 bootstrap stalls at 14% on this network
# (relay TLS unreachable, docs/torsocks.md §3 坑 #6) -- bridges are the
# documented way out and obfs4 is the standard bridge transport.
#
# Template: net/dnscrypt-proxy/build.sh (go-app-template §一/§三), with
# these package-specific parts:
#
#   * pristine source from the upstream gitlab tag archive (sources.lock
#     row obfs4proxy, tag obfs4proxy-0.0.14) via tools/fetch-src.sh.
#     The archive's top-level member is obfs4-obfs4proxy-<ver> and the
#     extraction dir name is DERIVED from the tarball so byte-ab's
#     pristine-source cleanup (tar tf | head -1) removes exactly the
#     tree this script would otherwise reuse;
#   * godeps replaces: x/sys AND x/net both route through the darwin/arm
#     adapted trees (dnscrypt 2026-11-25 precedent).  x/net is needed
#     for x/net/proxy (SOCKS5/HTTP upstream proxy dialers); x/sys is the
#     transitive floor under both x/net and x/crypto;
#   * x/crypto (curve25519/hkdf/nacl/secretbox), goptlib (pt protocol,
#     git.torproject.org), edwards25519-extra, filippo.io/edwards25519
#     and dchest/siphash are pure Go and resolve from go.sum via the
#     module proxy.  TCP only -- zero quic-go surface, so caddy.md §7's
#     server-side QUIC wall does not apply (the E2E in probe/ proves the
#     obfs4 SERVER role too, on the host);
#   * upstream go directive is 1.16 (<= 1.27.2: no pin needed) and there
#     is no toolchain line;
#   * the main package lives in the obfs4proxy/ SUBDIRECTORY (ls-verified
#     against the tag tree -- NOT the repo root);
#   * obfs4proxy/termmon_linux.go is excluded on darwin by Go's implicit
#     filename constraint; termmon.go takes the PPID-polling fallback
#     when termMonitorOSInit is nil -- verified in source, no patch.
#
# Non-negotiable environment: GOTOOLCHAIN=local, TMPDIR/GOMODCACHE under
# $root/tmp (AGENTS.md rule 0), GOPROXY=goproxy.cn (tools/go-env.sh).
#
# Usage:
#   ./obfs4proxy/build.sh              # -> ../out/obfs4proxy-<ver>-armv7
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
GO_VERSION="${GO_VERSION:-1.27.2}"
VER="${OBFS4_VERSION:-0.0.14}"

source "$root/tools/go-env.sh"

# ---- pristine source via the verified path -------------------------------
mkdir -p "$root/tmp/src"
read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock obfs4proxy)"
tarball="$("$root/tools/fetch-src.sh" obfs4proxy "$U" "$SHA")"
# full listing to a file first: `tar tf | head -1` SIGPIPEs tar mid-stream
# and pipefail turns that into a silent exit (byte-ab.sh 2026-11-24 note)
tf="$(mktemp "$root/tmp/obfs4-tf.XXXXXX")"; trap 'rm -f "$tf"' EXIT
tar tf "$tarball" >"$tf"
top="$(head -1 "$tf" | cut -d/ -f1)"
[ -n "$top" ] || { echo "cannot derive top-level dir from tarball" >&2; exit 1; }
SRC="$root/tmp/src/$top"
if [ ! -f "$SRC/go.mod" ]; then
    rm -rf "$SRC"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/go.mod" ] || { echo "obfs4proxy source layout unexpected" >&2; exit 1; }

# ---- wire the adapted dependency trees (godeps/) into go.mod -------------
# Replace paths are RELATIVE to go.mod (byte-A/B wall #5) and computed
# with os.path.relpath so the versioned extraction dir cannot drift them.
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
s = re.sub(r'^toolchain .*\n', '', s, flags=re.M)
open(gomod, 'w').write(s)
print('go.mod: replaces -> godeps/ (x/sys, x/net); go 1.16 directive <= 1.27.2 left as-is')
PY

export GOFLAGS=-mod=mod
mkdir -p "$OUT"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

cd "$SRC"
GOOS=darwin GOARCH=arm GOARM=7 CGO_ENABLED=0 \
    "$GOPORT" build -trimpath -buildvcs=false \
    -ldflags "-s -w" \
    -o "$OUT/obfs4proxy-$VER-armv7" ./obfs4proxy

file "$OUT/obfs4proxy-$VER-armv7" | grep -q "Mach-O armv7 executable" || {
    echo "output is not a Mach-O armv7 executable:" >&2
    file "$OUT/obfs4proxy-$VER-armv7" >&2
    exit 1
}

# ---- gate: every undefined symbol must resolve from a device dylib ------
"$root/tools/check-undefined.sh" "$OUT/obfs4proxy-$VER-armv7"

echo "==> $OUT/obfs4proxy-$VER-armv7"
echo "    deploy: via obfs4proxy/make-deb.sh (deb re-signs on device in postinst)"
