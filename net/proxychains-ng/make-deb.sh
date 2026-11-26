#!/bin/bash
# make-deb.sh -- build proxychains4 deb for armv7 iOS 10.3.3
#
# Payload layout:
#   /var/mobile/tools/proxychains/bin/proxychains4         the runner CLI
#   /var/mobile/tools/proxychains/bin/proxychains4-daemon  daemon variant
#   /var/mobile/tools/proxychains/lib/libproxychains4.dylib  injected lib
#   /var/mobile/tools/proxychains/etc/proxychains.conf     config (tor-ready)
#   /var/mobile/tools/bin/proxychains4                     entry symlink
#
# proxychains4 execs the command with DYLD_INSERT_LIBRARIES pointing at
# libdir/DLL_NAME (both compiled in from --libdir), so the layout below is
# not movable without a rebuild.  The shipped config defaults to tor's
# SOCKS5 on 127.0.0.1:9050 (the repo's tor4 listens there by default).
#
# Usage: ./proxychains-ng/make-deb.sh   # uses ../out/*-4.18-armv7
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
PC_VERSION="${PC_VERSION:-4.18}"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"

P4="$(ls "$OUT"/proxychains4-$PC_VERSION-armv7 2>/dev/null | head -1)"
PD="$(ls "$OUT"/proxychains4-daemon-$PC_VERSION-armv7 2>/dev/null | head -1)"
LIB="$(ls "$OUT"/libproxychains4-$PC_VERSION-armv7 2>/dev/null | head -1)"
[ -n "$P4" ] && [ -n "$PD" ] && [ -n "$LIB" ] || {
    echo "missing artifacts in $OUT -- run proxychains-ng/build.sh first" >&2; exit 1; }

STAGE="$OUT/proxychains4-stage"
DEB="$OUT/proxychains4_${PC_VERSION}-${DEBREV}_iphoneos-arm.deb"
rm -rf "$STAGE" "$DEB"
mkdir -p "$STAGE/DEBIAN" \
         "$STAGE/var/mobile/tools/proxychains/bin" \
         "$STAGE/var/mobile/tools/proxychains/lib" \
         "$STAGE/var/mobile/tools/proxychains/etc" \
         "$STAGE/var/mobile/tools/bin"

install -m 755 "$P4" "$STAGE/var/mobile/tools/proxychains/bin/proxychains4"
install -m 755 "$PD" "$STAGE/var/mobile/tools/proxychains/bin/proxychains4-daemon"
install -m 755 "$LIB" "$STAGE/var/mobile/tools/proxychains/lib/libproxychains4.dylib"

# sign + assert all three (an unsigned injected dylib is killed by dyld)
for f in "$STAGE/var/mobile/tools/proxychains/bin/proxychains4" \
         "$STAGE/var/mobile/tools/proxychains/bin/proxychains4-daemon" \
         "$STAGE/var/mobile/tools/proxychains/lib/libproxychains4.dylib"; do
    ldid -S "$f"
    ldid -e "$f" >/dev/null    # assert: exit 0 only on a signed file
done

# shipped config: tor-ready by default (strict chain, one socks5 hop;
# remote DNS -- proxy_dns -- so hostnames never leak past tor)
cat > "$STAGE/var/mobile/tools/proxychains/etc/proxychains.conf" <<'EOF'
# proxychains.conf for iOS 10.3.3 (repo default: tor on localhost)
# man proxychains.conf for the full option set.
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 127.0.0.1 9050
EOF
chmod 644 "$STAGE/var/mobile/tools/proxychains/etc/proxychains.conf"

ln -sf ../proxychains/bin/proxychains4 "$STAGE/var/mobile/tools/bin/proxychains4"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: proxychains4
Name: proxychains-ng
Version: $PC_VERSION-$DEBREV
Architecture: iphoneos-arm
Maintainer: $MAINTAINER
Section: net
Priority: optional
Depends: firmware (>= 10.3)
Description: proxychains-ng 4.18 for iOS 10.3.3 armv7
 Force any dynamically-linked program through a SOCKS4/5 or HTTP proxy
 via native Darwin interposition (DYLD_INTERPOSE).  Shipped config points
 at tor's SOCKS5 on 127.0.0.1:9050; hook any repo-built tool with:
   proxychains4 curl -s https://check.torproject.org/api/ip
 Note: Apple's own binaries carry __RESTRICT and cannot be hooked; the
 repo-built packages can.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
for f in /var/mobile/tools/proxychains/bin/proxychains4 \
         /var/mobile/tools/proxychains/bin/proxychains4-daemon \
         /var/mobile/tools/proxychains/lib/libproxychains4.dylib; do
    [ -x "$f" ] || [ -f "$f" ] && ldid -e "$f" >/dev/null 2>&1
done
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
[ -L "/var/mobile/tools/bin/proxychains4" ] && rm -f "/var/mobile/tools/bin/proxychains4" || true
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

dpkg-deb --root-owner-group -Zgzip --build "$STAGE" "$DEB" >/dev/null
rm -rf "$STAGE"
echo "Built $DEB"
dpkg -I "$DEB" | head -8
echo "SHA256: $(sha256sum "$DEB" | cut -d' ' -f1)"
