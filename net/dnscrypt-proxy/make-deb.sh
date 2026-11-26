#!/bin/bash
# Package the armv7 dnscrypt-proxy build into a .deb for the APT repo.
#
# dnscrypt-proxy is a user-run local DNS proxy (127.0.0.1:53 -> DoH/DoQ/
# DNSCrypt upstreams).  Ships as binary + example config ONLY: no
# LaunchDaemon, no auto-start (the nginx lesson -- services stay off;
# starting it is explicit).  The example config listens on 127.0.0.1:53
# with one public DoH upstream and needs root to bind 53; for a mobile-
# user run, change listen_addresses to a port >1024 first.
#
# Prerequisite: ./build.sh has produced ../out/dnscrypt-proxy-<ver>-armv7.
#
# Usage:
#   ./dnscrypt-proxy/build.sh && ./dnscrypt-proxy/make-deb.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"
PKG="dnscrypt-proxy4"
VER="${DNSCRYPT_VERSION:-2.1.21}"

BIN="$OUT/dnscrypt-proxy-$VER-armv7"
[ -f "$BIN" ] || { echo "missing $BIN (run ./build.sh first)" >&2; exit 1; }

sign() {
    local dst="$1"
    cp "$BIN" "$dst"
    command -v ldid >/dev/null 2>&1 || {
        echo "ldid is not on PATH -- refusing to package an unsigned binary" >&2
        exit 1
    }
    ldid -S "$dst" || { echo "ldid -S failed for $dst" >&2; exit 1; }
    ldid -e "$dst" >/dev/null 2>&1 || {
        echo "$dst carries no signature after ldid -S" >&2
        exit 1
    }
}

mkdir -p "$root/tmp"
w="$(mktemp -d "$root/tmp/dnscrypt-deb.XXXXXX")"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" \
         "$w/var/mobile/tools/dnscrypt-proxy/bin" \
         "$w/var/mobile/tools/dnscrypt-proxy/etc" \
         "$w/usr/share/doc/$PKG"

cat > "$w/DEBIAN/control" <<CTRL
Package: $PKG
Name: dnscrypt-proxy $VER
Version: $VER-$DEBREV
Section: Networking
Priority: optional
Architecture: iphoneos-arm
Maintainer: $MAINTAINER
Homepage: https://github.com/DNSCrypt/dnscrypt-proxy
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Depends: firmware (>= 10.3), ca-certificates4 | ca-certificates
Description: dnscrypt-proxy $VER for armv7 iOS, Go 1.27.2 darwin/arm port
  Local DNS proxy: plain DNS in (127.0.0.1:53), DNSCrypt/DoH/DoQ out.
  Ships binary + example config only -- no daemon, no auto-start.
  Start it yourself:
    /var/mobile/tools/dnscrypt-proxy/bin/dnscrypt-proxy \\
      -config /var/mobile/tools/dnscrypt-proxy/etc/dnscrypt-proxy.toml
  Binding 53 needs root; edit listen_addresses for a mobile-user port.
CTRL

cat > "$w/DEBIAN/postinst" <<'POST'
#!/bin/sh
# Re-sign on the device: host ldid signatures are occasionally rejected
# by the iOS 10 kernel policy (Killed: 9 before main).
if command -v ldid >/dev/null 2>&1; then
    ldid -S /var/mobile/tools/dnscrypt-proxy/bin/dnscrypt-proxy || true
fi
chown -R mobile:mobile /var/mobile/tools/dnscrypt-proxy 2>/dev/null || true
exit 0
POST
chmod 0755 "$w/DEBIAN/postinst"

cat > "$w/usr/share/doc/$PKG/copyright" <<CR
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: dnscrypt-proxy
Source: https://github.com/DNSCrypt/dnscrypt-proxy

Files: *
Copyright: 2018-2026 Frank Denis <j at pureftps dot org>
License: BSD-2-Clause

Files: debian/*
Copyright: 2026 Hesper <venus-homelab@users.noreply.github.com>
License: BSD-2-Clause
CR

sign "$w/var/mobile/tools/dnscrypt-proxy/bin/dnscrypt-proxy"
chmod 0755 "$w/var/mobile/tools/dnscrypt-proxy/bin/dnscrypt-proxy"

# example config: OFFLINE-FIRST -- a static alidns DoH stamp (223.5.5.5,
# reachable from this network) instead of the GitHub-hosted resolvers list,
# which is unreachable from the device (raw.githubusercontent blocked).
# Validated end to end on the device 2026-11-25 (see docs/dnscrypt-proxy.md).
cat > "$w/var/mobile/tools/dnscrypt-proxy/etc/dnscrypt-proxy.toml" <<TOML
listen_addresses = ['127.0.0.1:15353']

[static.'alidns']
stamp = 'sdns://AgIAAAAAAAAACTIyMy41LjUuNQAOZG5zLmFsaWRucy5jb20KL2Rucy1xdWVyeQ'
TOML

deb="$OUT/${PKG}_${VER}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb --root-owner-group -Zgzip --build "$w" "$deb" >/dev/null
echo "==> $deb"
dpkg-deb -f "$deb" Package Version Architecture
sha256sum "$deb"
echo "    installs /var/mobile/tools/dnscrypt-proxy/{bin,etc} (no daemon)"
