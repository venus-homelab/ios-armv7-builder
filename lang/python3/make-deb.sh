#!/bin/bash
# make-deb.sh -- build python3 deb for armv7 iOS 10.3.3
#
# Payload layout:
#   /var/mobile/tools/python3/bin/python3         interpreter (signed)
#   /var/mobile/tools/python3/lib/python3.13/     stdlib + lib-dynload/*.so
#   /var/mobile/tools/bin/python3                 symlink
#
# Sources: interpreter from obj/python; stdlib from the CPython source Lib/
# tree; extension modules from obj/Modules/*.so (already signed here so the
# device's dlopen() accepts them).
set -eu
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$ROOT" && git rev-parse --show-toplevel)"
REPO_OUT="$root/out"
SRC="${PYTHON_SRC:-$root/tmp/src/Python-3.13.18}"
# OBJ is overridable because 3.13 and 3.14 share one repo directory; the
# 3.13 build tree lives in $HOME/scratch/python3/obj313, and build.sh still
# writes to $ROOT/obj.  Pass OBJ=... to package a specific tree.
OBJ="${PYTHON_OBJ:-$ROOT/obj}"
PYVER="3.13"
VERSION="3.13.18-9"   # -9: atomic socket 修复(payload 变);-8: 净树重建补回 pip(捆扎 wheel;-7 无 pip,池内 -6 同样无,pip 里程碑回归) 净树重建补回 pip(捆扎 wheel;-7 无 pip,池内 -6 同样无,pip 里程碑回归)
DEB="$REPO_OUT/python3_${VERSION}_iphoneos-arm.deb"
STAGE="$REPO_OUT/python3-stage"

[ -f "$OBJ/python" ] || { echo "missing $OBJ/python -- run build.sh first" >&2; exit 1; }
[ -d "$SRC/Lib" ] || { echo "missing $SRC/Lib" >&2; exit 1; }

rm -rf "$STAGE" "$DEB"
mkdir -p "$STAGE/var/mobile/tools/python3/bin" \
         "$STAGE/var/mobile/tools/python3/lib/python$PYVER/lib-dynload" \
         "$STAGE/var/mobile/tools/bin" \
         "$STAGE/DEBIAN"

# interpreter
cp "$OBJ/python" "$STAGE/var/mobile/tools/python3/bin/python3"
chmod 755 "$STAGE/var/mobile/tools/python3/bin/python3"
ldid -S "$STAGE/var/mobile/tools/python3/bin/python3"
ldid -e "$STAGE/var/mobile/tools/python3/bin/python3" >/dev/null

# stdlib (plain .py tree)
cp -r "$SRC/Lib/." "$STAGE/var/mobile/tools/python3/lib/python$PYVER/"
# pip milestone (-8): build.sh restores pip into the OBJ tree's site-packages
# from the bundled ensurepip wheel -- carry it over (pure-python, fixed bytes)
mkdir -p "$STAGE/var/mobile/tools/python3/lib/python$PYVER/site-packages"
cp -r "$OBJ/lib/python$PYVER/site-packages/." \
      "$STAGE/var/mobile/tools/python3/lib/python$PYVER/site-packages/"
# _sysconfigdata__*.py is GENERATED at build time (build/lib.*), never in
# the source Lib/ -- without it sysconfig (and therefore ensurepip/pip)
# dies with ModuleNotFoundError on the device (2026-11-23 pip-entry task).
SYSCONFDATA="$(find "$(dirname "$OBJ")" "$OBJ" -maxdepth 4 \
    -path '*build/lib.darwin-armv7-*' -name '_sysconfigdata__*.py' 2>/dev/null | head -1)"
[ -n "$SYSCONFDATA" ] || SYSCONFDATA="$(find "$OBJ" -maxdepth 3 -name '_sysconfigdata__*.py' 2>/dev/null | head -1)"
[ -n "$SYSCONFDATA" ] || { echo "no _sysconfigdata module in the build tree" >&2; exit 1; }
cp "$SYSCONFDATA" "$STAGE/var/mobile/tools/python3/lib/python$PYVER/"
find "$STAGE/var/mobile/tools/python3/lib/python$PYVER" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

# _scproxy stub: urllib.request imports it unconditionally on darwin; the C
# module needs SCDynamicStoreCopyProxies, which the SDK headers mark
# unavailable on iOS (clang refuses to compile the call site), and this
# device is offline anyway -- proxies come from env vars.  A python-level
# stub satisfies the import and falls through to getproxies_environment().
cat > "$STAGE/var/mobile/tools/python3/lib/python$PYVER/_scproxy.py" <<'EOF'
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

# pip entry: a thin wrapper per interpreter.  pip itself materialises on
# the device via `python3 -m ensurepip` (works now that _sysconfigdata
# ships); the wrapper survives whether or not that has run yet.
for entry in pip3 pip3.13; do
	cat > "$STAGE/var/mobile/tools/python3/bin/$entry" <<'EOF'
#!/bin/sh
exec /var/mobile/tools/python3/bin/python3 -m pip "$@"
EOF
	chmod 755 "$STAGE/var/mobile/tools/python3/bin/$entry"
done

# extension modules: real files (they are symlinks in the build tree) + sign
if compgen -G "$OBJ/Modules/*.so" > /dev/null; then
	for so in "$OBJ"/Modules/*.so; do
		cp -L "$so" "$STAGE/var/mobile/tools/python3/lib/python$PYVER/lib-dynload/"
	done
	for so in "$STAGE/var/mobile/tools/python3/lib/python$PYVER/lib-dynload/"*.so; do
		chmod 755 "$so"
		ldid -S "$so" 2>/dev/null || true
	done
fi

ln -sf /var/mobile/tools/python3/bin/python3 "$STAGE/var/mobile/tools/bin/python3"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: python3
Version: $VERSION
Architecture: iphoneos-arm
Maintainer: hesper <venus-homelab@users.noreply.github.com>
Depends: firmware (>= 10.3), ca-certificates4 | ca-certificates
Description: CPython 3.13.18 for iOS 10.3.3 armv7
 Full CPython with the standard library and C extension modules
 (math, zlib, hashlib, sqlite3, ssl/OpenSSL 4.0.3, _socket, ...).
 zlib/binascii statically close libz (net-tree reproducible build).
 Installs to /var/mobile/tools/python3 and coexists with python314;
 set PYTHONHOME if relocating.
Section: Development
Priority: optional
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
BIN=/var/mobile/tools/python3/bin/python3
[ -x "$BIN" ] && ldid -e "$BIN" >/dev/null 2>&1
for so in /var/mobile/tools/python3/lib/python3.13/lib-dynload/*.so; do
	[ -f "$so" ] && ldid -e "$so" >/dev/null 2>&1
done
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
[ -L /var/mobile/tools/bin/python3 ] && rm -f /var/mobile/tools/bin/python3
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

dpkg-deb --root-owner-group -Zgzip --build "$STAGE" "$DEB" >/dev/null
echo "Built $DEB"
dpkg -I "$DEB" | head -6
ls -lh "$DEB"
echo "SHA256: $(sha256sum "$DEB" | cut -d' ' -f1)"
