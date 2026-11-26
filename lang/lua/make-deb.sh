#!/bin/bash
# make-deb.sh -- build lua54 deb for armv7 iOS 10.3.3
#
# Payload layout:
#   /var/mobile/tools/lua/bin/lua      interpreter (root:wheel, signed)
#   /var/mobile/tools/lua/bin/luac     bytecode compiler
#   /var/mobile/tools/lua/include/     C API headers (embedders)
#   /var/mobile/tools/lua/lib/liblua.a static library
#   /var/mobile/tools/bin/lua          symlink (login shells)
#
# Usage: ./lua/make-deb.sh          # uses ../out/lua-<ver>-armv7 + build tree
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
LUA_VERSION="${LUA_VERSION:-5.4.7}"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"

LUA_BIN="$(ls "$OUT"/lua-$LUA_VERSION-armv7 2>/dev/null | head -1)"
LUAC_BIN="$(ls "$OUT"/luac-$LUA_VERSION-armv7 2>/dev/null | head -1)"
[ -n "$LUA_BIN" ] && [ -n "$LUAC_BIN" ] || { echo "missing lua/luac in $OUT -- run lua/build.sh first" >&2; exit 1; }
SRC="$root/tmp/src/lua-$LUA_VERSION"
[ -f "$SRC/src/liblua.a" ] || { echo "missing build tree $SRC (liblua.a) -- run lua/build.sh first" >&2; exit 1; }

STAGE="$OUT/lua54-stage"
DEB="$OUT/lua54_${LUA_VERSION}-${DEBREV}_iphoneos-arm.deb"
rm -rf "$STAGE" "$DEB"
mkdir -p "$STAGE/DEBIAN" \
         "$STAGE/var/mobile/tools/lua/bin" \
         "$STAGE/var/mobile/tools/lua/include" \
         "$STAGE/var/mobile/tools/lua/lib" \
         "$STAGE/var/mobile/tools/bin"

install -m 755 "$LUA_BIN" "$STAGE/var/mobile/tools/lua/bin/lua"
install -m 755 "$LUAC_BIN" "$STAGE/var/mobile/tools/lua/bin/luac"
for b in lua luac; do
    ldid -S "$STAGE/var/mobile/tools/lua/bin/$b"
    ldid -e "$STAGE/var/mobile/tools/lua/bin/$b" >/dev/null   # assert signed
done

# C API for embedders (the deb is the distribution vehicle for liblua here)
install -m 644 "$SRC/src/lua.h" "$SRC/src/luaconf.h" \
               "$SRC/src/lualib.h" "$SRC/src/lauxlib.h" \
               "$SRC/src/lua.hpp" "$STAGE/var/mobile/tools/lua/include/"
install -m 644 "$SRC/src/liblua.a" "$STAGE/var/mobile/tools/lua/lib/"

ln -sf ../lua/bin/lua "$STAGE/var/mobile/tools/bin/lua"
ln -sf ../lua/bin/luac "$STAGE/var/mobile/tools/bin/luac"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: lua54
Name: lua
Version: $LUA_VERSION-$DEBREV
Architecture: iphoneos-arm
Maintainer: $MAINTAINER
Section: Interpreters
Priority: optional
Depends: firmware (>= 10.3)
Description: Lua 5.4.7 for iOS 10.3.3 armv7
 Interpreter + bytecode compiler + static library and C headers (for
 embedding).  Plain build: no readline/POSIX extras, zero runtime deps.
 Installed under /var/mobile/tools/lua with /var/mobile/tools/bin links.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
for b in lua luac; do
    BIN="/var/mobile/tools/lua/bin/$b"
    [ -x "$BIN" ] && ldid -e "$BIN" >/dev/null 2>&1
done
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
for b in lua luac; do
    [ -L "/var/mobile/tools/bin/$b" ] && rm -f "/var/mobile/tools/bin/$b" || true
done
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

dpkg-deb --root-owner-group -Zgzip --build "$STAGE" "$DEB" >/dev/null
rm -rf "$STAGE"
echo "Built $DEB"
dpkg -I "$DEB" | head -8
echo "SHA256: $(sha256sum "$DEB" | cut -d' ' -f1)"
