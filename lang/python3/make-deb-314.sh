#!/bin/bash
# make-deb-314.sh -- CPython 3.14 deb for armv7 iOS 10.3.3
#
# Identical layout to the 3.13 package but under /var/mobile/tools/python314,
# so both interpreters can coexist.  Built from the 3.14 source tree with the
# ios-armv7 patches applied (see patches/).
set -eu
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
# 仓库根必须用 git 解析:python3 目录搬进 lang/ 后,$ROOT/.. 是 lang/ 而非
# 仓库根,旧的 "$(cd "$ROOT/.." && pwd)/out" 解析出 lang/out(2026-11-25 实录)
REPO_ROOT="$(cd "$ROOT" && git rev-parse --show-toplevel)"
REPO_OUT="$REPO_ROOT/out"
SRC="${PYTHON_SRC:-$REPO_ROOT/tmp/src/Python-3.14.10}"
OBJ="${PYTHON_OBJ:-$ROOT/obj}"
PYVER="3.14"
UPSTREAM="$(grep -m1 '^#define PY_VERSION' "$SRC/Include/patchlevel.h" | sed 's/.*"\(.*\)".*/\1/')"
VERSION="${UPSTREAM}-9"   # -9: atomic socket 修复(payload 变);-8: 净树重建补回 pip(捆扎 wheel;-7 无 pip) 净树重建补回 pip(捆扎 wheel;-7 无 pip)
DEB="$REPO_OUT/python314_${VERSION}_iphoneos-arm.deb"
STAGE="$REPO_OUT/python314-stage"
PREFIX=/var/mobile/tools/python314

[ -f "$OBJ/python" ] || { echo "missing $OBJ/python -- run build.sh first" >&2; exit 1; }
[ -d "$SRC/Lib" ] || { echo "missing $SRC/Lib" >&2; exit 1; }

rm -rf "$STAGE" "$DEB"
mkdir -p "$STAGE$PREFIX/bin" "$STAGE$PREFIX/lib/python$PYVER/lib-dynload" \
         "$STAGE/var/mobile/tools/bin" "$STAGE/DEBIAN"

cp "$OBJ/python" "$STAGE$PREFIX/bin/python3"
chmod 755 "$STAGE$PREFIX/bin/python3"
ldid -S "$STAGE$PREFIX/bin/python3"
ldid -e "$STAGE$PREFIX/bin/python3" >/dev/null

cp -r "$SRC/Lib/." "$STAGE$PREFIX/lib/python$PYVER/"
# pip milestone (-8): build.sh restores pip into the OBJ tree's site-packages
# from the bundled ensurepip wheel -- carry it over (pure-python, fixed bytes)
mkdir -p "$STAGE$PREFIX/lib/python$PYVER/site-packages"
cp -r "$OBJ/lib/python$PYVER/site-packages/." \
      "$STAGE$PREFIX/lib/python$PYVER/site-packages/"
# _sysconfigdata__*.py is GENERATED at build time (build/lib.*), never in
# the source Lib/ -- without it sysconfig (and therefore ensurepip/pip)
# dies with ModuleNotFoundError on the device (2026-11-23 pip-entry task).
SYSCONFDATA="$(find "$(dirname "$OBJ")" "$OBJ" -maxdepth 4 \
    -path '*build/lib.darwin-armv7-*' -name '_sysconfigdata__*.py' 2>/dev/null | head -1)"
[ -n "$SYSCONFDATA" ] || SYSCONFDATA="$(find "$OBJ" -maxdepth 3 -name '_sysconfigdata__*.py' 2>/dev/null | head -1)"
[ -n "$SYSCONFDATA" ] || { echo "no _sysconfigdata module in the build tree" >&2; exit 1; }
cp "$SYSCONFDATA" "$STAGE$PREFIX/lib/python$PYVER/"
find "$STAGE$PREFIX/lib/python$PYVER" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

# _scproxy stub (see make-deb.sh for the story)
cat > "$STAGE$PREFIX/lib/python$PYVER/_scproxy.py" <<'EOF'
"""Stub for the Darwin-only _scproxy C module (iOS port).

The real module wraps SCDynamicStoreCopyProxies, which the iOS SDK marks
unavailable; this kit's devices take proxy settings from the standard
environment variables instead (http_proxy / https_proxy / no_proxy).
"""

def _get_proxy_settings():
    return {}


def _get_proxies():
    return {}


def get_proxies():
    return {}
EOF

# pip entry for the 3.14 interpreter (see make-deb.sh for the story)
for entry in pip3.14; do
	cat > "$STAGE$PREFIX/bin/$entry" <<'EOF'
#!/bin/sh
exec /var/mobile/tools/python314/bin/python3 -m pip "$@"
EOF
	chmod 755 "$STAGE$PREFIX/bin/$entry"
done

for so in "$OBJ"/Modules/*.so; do
    [ -e "$so" ] || continue
    cp -L "$so" "$STAGE$PREFIX/lib/python$PYVER/lib-dynload/"
done
for so in "$STAGE$PREFIX/lib/python$PYVER/lib-dynload/"*.so; do
    chmod 755 "$so"; ldid -S "$so" 2>/dev/null || true
done

ln -sf "$PREFIX/bin/python3" "$STAGE/var/mobile/tools/bin/python3.14"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: python314
Version: $VERSION
Architecture: iphoneos-arm
Maintainer: hesper <venus-homelab@users.noreply.github.com>
Depends: firmware (>= 10.3), ca-certificates4 | ca-certificates
Description: CPython $UPSTREAM for iOS 10.3.3 armv7
 Full CPython with the standard library and 53 C extension modules
 (math, zlib, hashlib, sqlite3, ssl/OpenSSL 4.0.3, _socket, ...).
 TLS 1.3 verified on device.  Installs to /var/mobile/tools/python314 and
 coexists with python3 (3.13).  Needs PYTHONHOME=$PREFIX unless the prefix
 matches the build-time value.
Section: Development
Priority: optional
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
BIN=/var/mobile/tools/python314/bin/python3
[ -x "$BIN" ] && ldid -e "$BIN" >/dev/null 2>&1
for so in /var/mobile/tools/python314/lib/python3.14/lib-dynload/*.so; do
	[ -f "$so" ] && ldid -e "$so" >/dev/null 2>&1
done
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
[ -L /var/mobile/tools/bin/python3.14 ] && rm -f /var/mobile/tools/bin/python3.14
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

dpkg-deb --root-owner-group -Zgzip --build "$STAGE" "$DEB" >/dev/null
echo "Built $DEB"
dpkg -I "$DEB" | head -6
ls -lh "$DEB"
echo "SHA256: $(sha256sum "$DEB" | cut -d' ' -f1)"
