#!/bin/bash
# make-deb.sh -- build netstat4 deb for armv7 iOS 10.3.3
set -eu
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

ROOT="$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)"
OUT="$ROOT/out"
DEB="$OUT/netstat4_1.0-2_iphoneos-arm.deb"
STAGE="$OUT/netstat4-stage"
BINDIR="$STAGE/var/mobile/tools/bin"

rm -rf "$STAGE" "$DEB"
mkdir -p "$BINDIR"

# build from the in-tree source (the ~/scratch era is over -- the
# review's netstat item: a clean checkout must produce this deb)
( cd "$ROOT/net/netstat" && bash ./build.sh )
cp "$ROOT/out/netstat-1.0-armv7" "$BINDIR/netstat"
chmod 755 "$BINDIR/netstat"
ldid -S "$BINDIR/netstat"

# control file
mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: netstat4
Version: 1.0-2
Architecture: iphoneos-arm
Depends: firmware (>= 10.3)
Maintainer: hesper <venus-homelab@users.noreply.github.com>
Description: netstat for iOS 10.3.3 armv7
 Shows active Internet connections, routing tables, and interface statistics.
 Built from device-verified ABI (xinpgen/xinpcb/xtcpcb offsets measured on
 xnu-3789.70.16). Supports -a -t -u -r -i flags, numeric output.
Section: net
Priority: optional
EOF

# postinst: nothing special, just ensure ldid signature
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
BIN="/var/mobile/tools/bin/netstat"
[ -x "$BIN" ] && ldid -e "$BIN" >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

# prerm: nothing
cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

# build deb
# -Zgzip: 设备 dpkg 1.18.10 不认 zstd 成员（control.tar.zst 报
#   "unknown compression"，2026-11-14 设备实测）；--root-owner-group 与
#   lsof/make-deb.sh 同款，载荷归 root:root。
dpkg-deb --root-owner-group -Zgzip --build "$STAGE" "$DEB" >/dev/null
echo "Built $DEB"
dpkg -I "$DEB"
echo "SHA256: $(sha256sum "$DEB" | cut -d' ' -f1)"

# make-repo.sh scans the repo-root out/ (the categorized layout)
echo "==> $DEB"