#!/bin/bash
# Package the Mozilla CA bundle + update script into a .deb for the APT repo.
#
# Pure data package -- no binaries, no signing step, nothing that executes at
# install time.  It ships:
#   /var/mobile/tools/etc/ca-certificates/ca-bundle.crt   Mozilla trust store
#   /var/mobile/tools/bin/update-ca-certificates          refresher script
#   /var/mobile/tools/etc/ca-certificates/README          runtime entry points
#
# The system /etc/ssl/cert.pem (iOS 10.3 vintage) is never touched; runtimes
# are switched to the managed bundle explicitly (docs/ca-certificates.md).
#
# Usage: ./ca-certificates/make-deb.sh      # after ./ca-certificates/build.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
CA_VERSION="${CA_VERSION:-20261121}"
DEBREV="${DEBREV:-3}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"

BUNDLE="$OUT/ca-certificates-ca-bundle.pem"
[ -s "$BUNDLE" ] || { echo "missing bundle; run build.sh first" >&2; exit 1; }

w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" \
         "$w/var/mobile/tools/etc/ca-certificates" \
         "$w/var/mobile/tools/bin" \
         "$w/usr/share/doc/ca-certificates4"

cat > "$w/DEBIAN/control" <<CTRL
Package: ca-certificates4
Name: CA certificates (managed bundle)
Version: $CA_VERSION-$DEBREV
Section: Utilities
Priority: optional
Architecture: iphoneos-arm
Maintainer: $MAINTAINER
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Depends: firmware (>= 10.3)
Provides: ca-certificates
Replaces: wget4
Description: Mozilla CA bundle and update script for the armv7 kit
 A single managed trust store: /var/mobile/tools/etc/ca-certificates/
 ca-bundle.crt (Mozilla bundle via curl.se, $(grep -c "BEGIN CERTIFICATE" "$BUNDLE") certificates) plus
 update-ca-certificates, which refreshes it atomically with sanity checks.
 .
 This package also owns /var/mobile/tools/env.sh -- the kit's single
 certificate convention (PATH plus SSL_CERT_FILE pointing at the managed
 bundle; source it or let the runtime packages' docs point you there).
 Previously wget4 shipped a divergent copy pointing at the system store.
 .
 Entry points: SSL_CERT_FILE=.../ca-bundle.crt for curl, wget, python3,
 node and go; git config http.sslCAInfo for git.  The system
 /etc/ssl/cert.pem is left in place -- see docs/ca-certificates.md.
CTRL

cat > "$w/var/mobile/tools/etc/ca-certificates/README" <<'RD'
ca-certificates4
================

ca-bundle.crt is the Mozilla trust store this kit manages; refresh it with:

    /var/mobile/tools/bin/update-ca-certificates

Point a runtime at it:

    export SSL_CERT_FILE=/var/mobile/tools/etc/ca-certificates/ca-bundle.crt   # curl/wget/python3/node/go
    git config --global http.sslCAInfo /var/mobile/tools/etc/ca-certificates/ca-bundle.crt

The device's stock /etc/ssl/cert.pem (iOS 10.3 era, ~120 certs, missing
modern roots like ISRG X2) is left untouched by this package.
RD

install -m 0644 "$BUNDLE" "$w/var/mobile/tools/etc/ca-certificates/ca-bundle.crt"
install -m 0755 "$here/update-ca-certificates" "$w/var/mobile/tools/bin/update-ca-certificates"
install -m 0644 "$w/var/mobile/tools/etc/ca-certificates/README" "$w/usr/share/doc/ca-certificates4/README"

# The kit's single env convention.  ca-certificates4 is the natural owner:
# every runtime that cares about SSL_CERT_FILE now Depends on this package,
# so sourcing advice in the per-package docs can rely on the file existing.
# Content is IDENTICAL for every consumer; wget4's divergent copy (system
# store) was retired in favour of this one (Replaces: wget4 above).
mkdir -p "$w/var/mobile/tools"
cat > "$w/var/mobile/tools/env.sh" <<'ENV'
# Source this (or add these directories to PATH) to use the armv7 kit
# tools with the managed CA bundle (ca-certificates4).
export PATH=/var/mobile/tools:/var/mobile/tools/bin:$PATH
export SSL_CERT_FILE=/var/mobile/tools/etc/ca-certificates/ca-bundle.crt
ENV
chmod 0755 "$w/var/mobile/tools/env.sh"

deb="$OUT/ca-certificates4_${CA_VERSION}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb --root-owner-group -Zgzip --build "$w" "$deb" >/dev/null
echo "==> $deb"
dpkg-deb -f "$deb" Package Version Architecture
sha256sum "$deb"
