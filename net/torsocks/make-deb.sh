#!/bin/bash
# make-deb.sh -- build torsocks4 deb for armv7 iOS 10.3.3
#
# Payload layout (upstream configure defaults with the repo prefix; the
# dylib path and CONFDIR are baked into libtorsocks at compile time by
# net/torsocks/build.sh's config.h -- NOT movable without a rebuild):
#   /var/mobile/tools/torsocks/bin/torsocks                wrapper script
#   /var/mobile/tools/torsocks/lib/torsocks/libtorsocks.dylib  injected lib
#   /var/mobile/tools/torsocks/etc/tor/torsocks.conf       config (tor-ready)
#   /var/mobile/tools/bin/torsocks                         entry symlink
#
# Signing: the wrapper is a shell script (no signature); the dylib gets a
# host ldid -S at stage time (proxychains4 pattern) AND a device-side
# re-sign in postinst (caddy pattern -- host signatures are untrusted on
# this target).  Same 2x rule as every injected dylib in this repo.
#
# Usage: ./torsocks/make-deb.sh   # uses ../out/*-2.5.0 products
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
TORSOCKS_VERSION="${TORSOCKS_VERSION:-2.5.0}"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"

LIB="$(ls "$OUT"/libtorsocks-$TORSOCKS_VERSION-armv7 2>/dev/null | head -1)"
WRAP="$(ls "$OUT"/torsocks-wrapper-$TORSOCKS_VERSION 2>/dev/null | head -1)"
[ -n "$LIB" ] && [ -n "$WRAP" ] || {
    echo "missing artifacts in $OUT -- run torsocks/build.sh first" >&2; exit 1; }

STAGE="$OUT/torsocks4-stage"
DEB="$OUT/torsocks4_${TORSOCKS_VERSION}-${DEBREV}_iphoneos-arm.deb"
rm -rf "$STAGE" "$DEB"
mkdir -p "$STAGE/DEBIAN" \
         "$STAGE/var/mobile/tools/torsocks/bin" \
         "$STAGE/var/mobile/tools/torsocks/lib/torsocks" \
         "$STAGE/var/mobile/tools/torsocks/etc/tor" \
         "$STAGE/var/mobile/tools/bin"

install -m 644 "$LIB" "$STAGE/var/mobile/tools/torsocks/lib/torsocks/libtorsocks.dylib"
ldid -S "$STAGE/var/mobile/tools/torsocks/lib/torsocks/libtorsocks.dylib"
ldid -e "$STAGE/var/mobile/tools/torsocks/lib/torsocks/libtorsocks.dylib" >/dev/null
install -m 755 "$WRAP" "$STAGE/var/mobile/tools/torsocks/bin/torsocks"

# tor-ready config: defaults point at the repo's tor4 (127.0.0.1:9050);
# onion cookies get 127.42.42.0/24 so .onion hostnames never leave tor.
cat > "$STAGE/var/mobile/tools/torsocks/etc/tor/torsocks.conf" <<'EOF'
# torsocks.conf for iOS 10.3.3 (repo default: tor4 on localhost)
TorAddress 127.0.0.1
TorPort 9050

# Fake-IP range handed out for .onion names; the connection goes back to
# tor with the original hostname, so DNS never leaks.
OnionAddrRange 127.42.42.0/24

# Uncomment to give every torsocks process its own tor circuit:
#IsolatePID 1
EOF
chmod 644 "$STAGE/var/mobile/tools/torsocks/etc/tor/torsocks.conf"

ln -sf ../torsocks/bin/torsocks "$STAGE/var/mobile/tools/bin/torsocks"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: torsocks4
Name: torsocks
Version: $TORSOCKS_VERSION-$DEBREV
Architecture: iphoneos-arm
Maintainer: $MAINTAINER
Section: net
Priority: optional
Depends: firmware (>= 10.3)
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Description: torsocks 2.5.0 for iOS 10.3.3 armv7
 Per-command tor takeover: torsocks <cmd> injects libtorsocks.dylib via
 DYLD_INSERT_LIBRARIES (+DYLD_FORCE_FLAT_NAMESPACE) and redirects
 connect/socket/DNS into tor's SOCKS5 (127.0.0.1:9050, repo tor4).
 Shipped config is tor-ready; .onion names are proxied by hostname.
 Note: Apple's own binaries carry __RESTRICT and cannot be hooked; the
 repo-built packages can.  Complements privoxy4 (HTTP entry) and
 proxychains4 (generic chains).
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
# The host-side ldid signature is NOT accepted by the iOS 10 kernel policy
# on this target.  Re-sign the injected dylib with the on-device ldid on
# every install/upgrade (caddy pattern).
set -e
LIB=/var/mobile/tools/torsocks/lib/torsocks/libtorsocks.dylib
if command -v ldid >/dev/null 2>&1; then
    ldid -S "$LIB" 2>/dev/null || true
    ldid -e "$LIB" >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
[ -L "/var/mobile/tools/bin/torsocks" ] && rm -f "/var/mobile/tools/bin/torsocks" || true
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

dpkg-deb --root-owner-group -Zgzip --build "$STAGE" "$DEB" >/dev/null
rm -rf "$STAGE"
echo "Built $DEB"
dpkg -I "$DEB" | head -8
echo "SHA256: $(sha256sum "$DEB" | cut -d' ' -f1)"
