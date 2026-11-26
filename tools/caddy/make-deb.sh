#!/bin/bash
# Package the armv7 caddy build into a .deb (caddy4) for the APT repo.
#
# Skeleton follows tools/git-lfs/make-deb.sh + the Go-template conventions
# (tools/fzf/make-deb.sh): staging under $root/tmp (host /tmp is a small
# tmpfs, AGENTS.md rule 0), SOURCE_DATE_EPOCH exported at the top and the
# changelog date derived from it (deterministic-deb convention, 2026-11-24),
# -Zgzip --root-owner-group, host-side ldid -S asserted via ldid -e, and the
# device-side re-sign in postinst (host signatures get Killed: 9 on this
# kernel -- see the deploy trio in ~/.dsh/AGENTS.md).
#
# Payload layout:
#   /var/mobile/tools/caddy/bin/caddy       the Go binary (signed, ~30 MB)
#   /var/mobile/tools/caddy/etc/            EMPTY config dir -- caddy's
#                                           first run generates a Caddyfile;
#                                           we deliberately ship no config
#                                           (README points the way)
#   /var/mobile/tools/caddy/share/doc/caddy4/  changelog/copyright/README
#   /usr/bin/caddy                          symlink (postinst/prerm)
#
# Depends: firmware (>= 10.3) as usual, plus ca-certificates4 |
# ca-certificates.  Honest note: caddy embeds the Mozilla root store via
# golang.org/x/crypto/x509roots/fallback (cmd/x509rootsfallback.go calls
# x509.SetFallbackRoots), so ACME/TLS verification works even with no
# device CA store; the ca-certificates dependency keeps caddy consistent
# with the other TLS tools on the device (wget/curl/nginx lineage) and
# provides the PEM pool for anything caddy hands to the system pool.
#
# Usage:
#   ./caddy/build.sh && ./caddy/make-deb.sh
#   DEBREV=2 ./caddy/make-deb.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"
PKG="caddy4"
VER="${CADDY_VERSION:-2.11.9}"
PREFIX="/var/mobile/tools/caddy"

BIN="$OUT/caddy-$VER-armv7"
[ -f "$BIN" ] || { echo "missing $BIN -- run ./caddy/build.sh first" >&2; exit 1; }

# Same contract as tailcat/make-deb.sh sign(): failures loud, signature
# asserted with ldid -e, using the host ldid that the repo's toolchain ships.
LDID="$HOME/ios-tool/bin/ldid"
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
sign() {
    local src="$1" dst="$2"
    cp "$src" "$dst" || { echo "cp failed: $src -> $dst" >&2; exit 1; }
    [ -x "$LDID" ] || { echo "host ldid missing at $LDID" >&2; exit 1; }
    "$LDID" -S "$dst" || { echo "ldid -S failed for $dst" >&2; exit 1; }
    "$LDID" -e "$dst" >/dev/null 2>&1 || {
        echo "$dst carries no signature after ldid -S" >&2
        exit 1
    }
}

# staging under $root/tmp -- NOT /tmp (usrquota tmpfs, AGENTS.md rule 0)
mkdir -p "$root/tmp"
w="$(mktemp -d "$root/tmp/caddy-deb.XXXXXX")"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" "$w$PREFIX/bin" "$w$PREFIX/etc" "$w/usr/share/doc/$PKG"

cat > "$w/DEBIAN/control" <<CTRL
Package: $PKG
Name: caddy $VER
Version: $VER-$DEBREV
Section: Networking
Priority: optional
Architecture: iphoneos-arm
Depends: firmware (>= 10.3), ca-certificates4 | ca-certificates
Maintainer: $MAINTAINER
Homepage: https://github.com/caddyserver/caddy
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Description: caddy $VER for armv7 iOS, Go 1.27.2 darwin/arm revived port
 Modern web server with automatic HTTPS (ACME), HTTP/1.1, HTTP/2 and
 HTTP/3, compiled through the repo's Go reproducible template.
 .
 Installs under /var/mobile/tools/caddy with /usr/bin/caddy symlink.
 No Caddyfile is shipped: run \`caddy\` once in a directory and it offers
 to generate one, or use \`caddy file-server\` for a zero-config static
 server.  Embeds the Mozilla root store (x509roots/fallback), so TLS
 verification works even without a device CA pool.
CTRL

cat > "$w/DEBIAN/postinst" <<'POST'
#!/bin/sh
# The host-side ldid signature is NOT accepted by the iOS 10 kernel policy
# on this target (installed-but-host-signed binaries die with "Killed: 9"
# before main()).  Re-sign with the on-device ldid on every install/upgrade.
set -e
PREFIX=/var/mobile/tools/caddy
if [ -x /usr/bin/ldid ] || command -v ldid >/dev/null 2>&1; then
    ldid -S "$PREFIX/bin/caddy" 2>/dev/null || true
fi
chown -R mobile:mobile "$PREFIX" 2>/dev/null || true
chmod 0755 "$PREFIX/bin/caddy" 2>/dev/null || true
ln -sf "$PREFIX/bin/caddy" /usr/bin/caddy
exit 0
POST
chmod 755 "$w/DEBIAN/postinst"

cat > "$w/DEBIAN/prerm" <<'PRE'
#!/bin/sh
# Remove the PATH symlink before the payload disappears.
set -e
rm -f /usr/bin/caddy
exit 0
PRE
chmod 755 "$w/DEBIAN/prerm"

cat > "$w/usr/share/doc/$PKG/changelog" <<CH
$PKG ($VER-$DEBREV) stable; urgency=medium

  * caddy $VER, ported through the Go reproducible template (fetch-src
    pinned source, godeps xsys-darwin-arm + xnet-darwin-arm via go.mod
    replace, -trimpath -buildvcs=false, CustomVersion stamp, check-
    undefined gate).  go directive 1.26.0 <= toolchain 1.27.2: nothing
    clamped; quic-go v0.63.0 compiles for darwin/arm (no build
    constraint excludes it).
  * Single binary + /usr/bin symlink + empty etc/ (no Caddyfile shipped;
    first run generates one, \`caddy file-server\` needs none).

 -- $MAINTAINER  $(date -R -u -d "@${SOURCE_DATE_EPOCH:-0}")
CH

cat > "$w/usr/share/doc/$PKG/copyright" <<CR
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: caddy
Source: https://github.com/caddyserver/caddy

Files: *
Copyright: 2015-2026 Matthew Holt and The Caddy Authors
License: Apache-2.0
 Licensed under the Apache License, Version 2.0 (the "License"); you may
 not use this file except in compliance with the License.  You may obtain
 a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 .
 Full text ships in the upstream source tarball (LICENSE).

Cross-compiled for armv7 iOS 10.x with a revived Go 1.27.2 darwin/arm
toolchain.  No Apple SDK files are redistributed.
CR

cat > "$w/usr/share/doc/$PKG/README" <<RD
caddy $VER on armv7 iOS (package caddy4)
========================================

Binary:  /var/mobile/tools/caddy/bin/caddy  (symlinked as /usr/bin/caddy)
Config:  /var/mobile/tools/caddy/etc/  -- EMPTY by design.  Caddy
         generates a Caddyfile on first run (\`caddy start\` in a
         directory with no Caddyfile offers to create one), or write
         your own here and run:
             caddy run --config /var/mobile/tools/caddy/etc/Caddyfile

Zero-config static file server (no Caddyfile needed):
    caddy file-server --listen :8080 --root <dir>
then fetch files from another machine and compare checksums:
    curl -O http://<device-ip>:8080/<file>;  md5sum <file>

Automatic HTTPS / ACME: needs publicly reachable ports 80 and 443.
On a LAN device behind NAT this cannot complete an ACME challenge --
use \`tls internal\` (caddy's own local CA) or plain HTTP for local
serving.  The binary embeds the Mozilla root store
(x509roots/fallback), so outbound TLS verification works as-is.

Docs: https://caddyserver.com/docs/
RD

# ---- payload ------------------------------------------------------------
sign "$BIN" "$w$PREFIX/bin/caddy"
chmod 755 "$w$PREFIX/bin/caddy"

deb="$OUT/${PKG}_${VER}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb -Zgzip --root-owner-group -b "$w" "$deb"
echo "==> $deb"
sha256sum "$deb"
echo "    installs $PREFIX/bin/caddy with /usr/bin/caddy symlink;"
echo "    $PREFIX/etc/ left empty (no Caddyfile shipped)"
