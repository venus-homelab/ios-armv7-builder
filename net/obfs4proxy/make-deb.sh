#!/bin/bash
# Package the armv7 obfs4proxy build into a .deb for the APT repo.
#
# obfs4proxy ships as a single static Go binary (no config, no daemon,
# no auto-start -- the nginx lesson).  It is meant to be driven by tor's
# ClientTransportPlugin:
#
#   ClientTransportPlugin obfs4 exec /var/mobile/tools/obfs4proxy/bin/obfs4proxy
#   Bridge obfs4 <ip>:<port> <fingerprint> cert=<cert> iat-mode=<0|1|2>
#
# It can also be driven by any pt-speaking manager (the E2E probe in
# probe/ is exactly that -- env + stdio, no tor needed).
#
# Prerequisite: ./build.sh has produced ../out/obfs4proxy-<ver>-armv7.
#
# Usage:
#   ./obfs4proxy/build.sh && ./obfs4proxy/make-deb.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"
PKG="obfs4proxy4"
VER="${OBFS4_VERSION:-0.0.14}"

BIN="$OUT/obfs4proxy-$VER-armv7"
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
w="$(mktemp -d "$root/tmp/obfs4-deb.XXXXXX")"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" \
         "$w/var/mobile/tools/obfs4proxy/bin" \
         "$w/var/mobile/tools/bin" \
         "$w/usr/share/doc/$PKG"

cat > "$w/DEBIAN/control" <<CTRL
Package: $PKG
Name: obfs4proxy $VER
Version: $VER-$DEBREV
Section: Networking
Priority: optional
Architecture: iphoneos-arm
Maintainer: $MAINTAINER
Homepage: https://gitlab.com/yawning/obfs4
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Depends: firmware (>= 10.3)
Description: obfs4proxy $VER for armv7 iOS, Go 1.27.2 darwin/arm port
  Tor pluggable transport: disguises tor traffic as random-looking TCP
  (obfs4 bridge protocol, client role on device).  Driven by tor4's
  ClientTransportPlugin over the pt env/stdio protocol -- no config
  file, no daemon.  Pair it with obfs4 Bridge lines in torrc:
    ClientTransportPlugin obfs4 exec /var/mobile/tools/obfs4proxy/bin/obfs4proxy
    Bridge obfs4 <ip>:<port> <fp> cert=<cert> iat-mode=<n>
CTRL

cat > "$w/DEBIAN/postinst" <<'POST'
#!/bin/sh
# Re-sign on the device: host ldid signatures are occasionally rejected
# by the iOS 10 kernel policy (Killed: 9 before main).
if command -v ldid >/dev/null 2>&1; then
    ldid -S /var/mobile/tools/obfs4proxy/bin/obfs4proxy || true
fi
chown -R mobile:mobile /var/mobile/tools/obfs4proxy 2>/dev/null || true
exit 0
POST
chmod 0755 "$w/DEBIAN/postinst"

cat > "$w/DEBIAN/prerm" <<'PRE'
#!/bin/sh
set -e
[ -L "/var/mobile/tools/bin/obfs4proxy" ] && rm -f "/var/mobile/tools/bin/obfs4proxy" || true
exit 0
PRE
chmod 0755 "$w/DEBIAN/prerm"

cat > "$w/usr/share/doc/$PKG/copyright" <<CR
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: obfs4proxy
Source: https://gitlab.com/yawning/obfs4

Files: *
Copyright: 2014-2022 Yawning Angel <yawning at schwanenlied dot me>
License: BSD-2-Clause

Files: vendored goptlib (git.torproject.org/pluggable-transports/goptlib)
Copyright: 2012-2022 David Fifield <david@bamsoftware.com>
License: CC0-1.0

Files: debian/*
Copyright: 2026 Hesper <venus-homelab@users.noreply.github.com>
License: BSD-2-Clause
CR

sign "$w/var/mobile/tools/obfs4proxy/bin/obfs4proxy"
chmod 0755 "$w/var/mobile/tools/obfs4proxy/bin/obfs4proxy"
ln -sf ../obfs4proxy/bin/obfs4proxy "$w/var/mobile/tools/bin/obfs4proxy"

deb="$OUT/${PKG}_${VER}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb --root-owner-group -Zgzip --build "$w" "$deb" >/dev/null
echo "==> $deb"
dpkg-deb -f "$deb" Package Version Architecture
sha256sum "$deb"
echo "    installs /var/mobile/tools/obfs4proxy/bin/obfs4proxy (+ bin symlink)"
