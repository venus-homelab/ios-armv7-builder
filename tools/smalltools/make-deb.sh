#!/bin/bash
# Package smalltools as smalltools4_<ver>_iphoneos-arm.deb.
# One binary, four names via argv[0] dispatch; the deb installs the binary
# once plus per-name symlinks, and /usr/bin links (rsync precedent).
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
VER="${SMALLTOOLS_VERSION:-1.0}"
BIN="$OUT/smalltools-armv7"
[ -f "$BIN" ] || { echo "missing $BIN (run smalltools/build.sh)" >&2; exit 1; }

w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" "$w/usr/bin" "$w/var/mobile/tools/smalltools" \
         "$w/usr/share/doc/smalltools4"

cat > "$w/DEBIAN/control" <<CTRL
Package: smalltools4
Name: tree watch realpath hexdump
Version: $VER-2
Section: Utilities
Priority: optional
Architecture: iphoneos-arm
Maintainer: Hesper <venus-homelab@users.noreply.github.com>
Homepage: https://github.com/venus-homelab/ios-armv7-builder
Depends: firmware (>= 10.3)
Description: tree/watch/realpath/hexdump for armv7 iOS 10+ (one binary)
 Four small file utilities the device lacks, one binary dispatched by
 argv[0]: tree (directory glyphs, -a -d -L), watch (periodic re-run,
 -n seconds), realpath (SDK realpath(3)), hexdump (16-byte hex+ASCII).
 Installed under /var/mobile/tools/smalltools with /usr/bin links.
CTRL

cat > "$w/DEBIAN/postinst" <<POST
#!/bin/sh
set -e
for n in tree watch realpath hexdump; do
    ln -sf smalltools /var/mobile/tools/smalltools/\$n
    ln -sf /var/mobile/tools/smalltools/\$n /usr/bin/\$n
done
if command -v ldid >/dev/null 2>&1; then
    ldid -S /var/mobile/tools/smalltools/smalltools 2>/dev/null || true
fi
exit 0
POST
chmod 0755 "$w/DEBIAN/postinst"

cat > "$w/DEBIAN/prerm" <<PRERM
#!/bin/sh
set -e
for n in tree watch realpath hexdump; do
    rm -f /usr/bin/\$n
done
exit 0
PRERM
chmod 0755 "$w/DEBIAN/prerm"

install -m 0755 "$BIN" "$w/var/mobile/tools/smalltools/smalltools"
cat > "$w/usr/share/doc/smalltools4/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: smalltools
Source: hand-written for ios-armv7-builder (no upstream)

Files: *
Copyright: 2026 Hesper <venus-homelab@users.noreply.github.com>
License: MIT
COPYRIGHT

dpkg-deb --root-owner-group -Zgzip --build "$w" \
    "$OUT/smalltools4_${VER}-2_iphoneos-arm.deb" >/dev/null
rm -rf "$w"; trap - EXIT
echo "==> $OUT/smalltools4_${VER}-2_iphoneos-arm.deb"
sha256sum "$OUT/smalltools4_${VER}-2_iphoneos-arm.deb"
