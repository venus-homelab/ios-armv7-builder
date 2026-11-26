#!/bin/bash
# Package the armv7 zstd CLI build into a .deb (zstd4) for the APT repo.
#
# Skeleton follows tools/fzf/make-deb.sh / tools/git-lfs/make-deb.sh:
# staging under $root/tmp (host /tmp is a small tmpfs, AGENTS.md rule 0),
# SOURCE_DATE_EPOCH exported at the top and the changelog date derived from
# it (deterministic-deb convention, 2026-11-24), -Zgzip --root-owner-group,
# host-side ldid -S asserted via ldid -e, and the device-side re-sign in
# postinst (host signatures get Killed: 9 on this kernel -- deploy trio in
# ~/.dsh/AGENTS.md).
#
# Payload layout (zstd's upstream install shape, make install conventions):
#   /var/mobile/tools/zstd/bin/zstd        the real binary (signed)
#   /var/mobile/tools/zstd/bin/unzstd      symlink -> zstd (argv[0] switch,
#                                          same as `make install` upstream)
#   /var/mobile/tools/zstd/bin/zstdcat     symlink -> zstd (same mechanism)
#   /var/mobile/tools/zstd/share/man/man1/zstd.1
#   /usr/bin/{zstd,unzstd,zstdcat}         symlinks (postinst/prerm)
#
# zstdgrep/zstdless are deliberately NOT shipped: they shell out to grep/less
# workflows this port does not target, and they are separate upstream scripts.
#
# Depends is only the firmware floor: the binary's single recorded dylib is
# libSystem.B.dylib (asserted in build.sh), everything else is static.
#
# Usage:
#   ./zstd/build.sh && ./zstd/make-deb.sh
#   DEBREV=2 ./zstd/make-deb.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"
PKG="zstd4"
VER="${ZSTD_VERSION:-1.5.7}"
PREFIX="/var/mobile/tools/zstd"

BIN="$OUT/zstd-$VER-armv7"
[ -f "$BIN" ] || { echo "missing $BIN -- run ./zstd/build.sh first" >&2; exit 1; }
SRC="$root/tmp/src/zstd-$VER"
MAN="$SRC/programs/zstd.1"
[ -f "$MAN" ] || { echo "missing $MAN -- run ./zstd/build.sh first" >&2; exit 1; }

# Same contract as fzf/make-deb.sh sign(): failures loud, signature asserted
# with ldid -e, using the host ldid that the repo's toolchain ships.
LDID="${LDID:-${IOS_STUBDIR:-$HOME/ios-tool}/bin/ldid}"
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
sign() {
    local src="$1" dst="$2"
    cp "$src" "$dst" || { echo "cp failed: $src -> $dst" >&2; exit 1; }
    [ -x "$LDID" ] || { echo "host ldid missing at $LDID" >&2; exit 1; }
    "$LDID" -S "$dst" || { echo "ldid -S failed for $dst" >&2; exit 1; }
    "$LDID" -e "$dst" >/dev/null 2>&1 || {
        echo "$dst carries no signature after ldid -S" >&2
        exit 1
    }
}

# staging under $root/tmp -- NOT /tmp (usrquota tmpfs, AGENTS.md rule 0)
mkdir -p "$root/tmp"
w="$(mktemp -d "$root/tmp/zstd-deb.XXXXXX")"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" \
         "$w$PREFIX/bin" \
         "$w$PREFIX/share/man/man1" \
         "$w/usr/share/doc/$PKG"

cat > "$w/DEBIAN/control" <<CTRL
Package: $PKG
Name: zstd
Version: $VER-$DEBREV
Section: Utilities
Priority: optional
Architecture: iphoneos-arm
Depends: firmware (>= 10.3)
Maintainer: $MAINTAINER
Homepage: https://github.com/facebook/zstd
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Description: zstd $VER for armv7 iOS, the .zst compression CLI
 Zstandard fast lossless compression command line tool (same upstream tree
 the repo's curl zstd-transfer-encoding subbuild already links against --
 sources.lock row "zstd 1.5.7" is shared, the CLI was the missing piece).
 .
 Installs under /var/mobile/tools/zstd with /usr/bin symlinks for zstd,
 unzstd and zstdcat (argv[0] aliases, upstream make-install convention).
CTRL

cat > "$w/DEBIAN/postinst" <<'POST'
#!/bin/sh
# The host-side ldid signature is NOT accepted by the iOS 10 kernel policy
# on this target (installed-but-host-signed binaries die with "Killed: 9"
# before main()).  Re-sign with the on-device ldid on every install/upgrade.
set -e
PREFIX=/var/mobile/tools/zstd
if [ -x /usr/bin/ldid ] || command -v ldid >/dev/null 2>&1; then
    ldid -S "$PREFIX/bin/zstd" 2>/dev/null || true
fi
chown -R mobile:mobile "$PREFIX" 2>/dev/null || true
chmod 0755 "$PREFIX/bin/zstd" 2>/dev/null || true
ln -sf "$PREFIX/bin/zstd" /usr/bin/zstd
ln -sf "$PREFIX/bin/zstd" /usr/bin/unzstd
ln -sf "$PREFIX/bin/zstd" /usr/bin/zstdcat
exit 0
POST
chmod 755 "$w/DEBIAN/postinst"

cat > "$w/DEBIAN/prerm" <<'PRE'
#!/bin/sh
# Remove the PATH symlinks before the payload disappears.
set -e
rm -f /usr/bin/zstd /usr/bin/unzstd /usr/bin/zstdcat
exit 0
PRE
chmod 755 "$w/DEBIAN/prerm"

cat > "$w/usr/share/doc/$PKG/changelog" <<CH
$PKG ($VER-$DEBREV) stable; urgency=medium

  * zstd $VER CLI, first port (tar.zst workflow).  Same pinned source tree
    the curl subbuild consumes (shared sources.lock row), CLI built from
    programs/ with the CC/AR/RANLIB override + darwin-ar recipe.
  * HAVE_ZLIB/HAVE_LZMA/HAVE_LZ4 forced off (probe would lie under
    -undefined dynamic_lookup); single libSystem.B.dylib dependency,
    check-undefined gate 95/95.

 -- $MAINTAINER  $(date -R -u -d "@${SOURCE_DATE_EPOCH:-0}")
CH

cat > "$w/usr/share/doc/$PKG/copyright" <<CR
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: zstd
Source: https://github.com/facebook/zstd

Files: *
Copyright: 2016-2026 Meta Platforms, Inc. and affiliates
License: BSD-3-Clause or GPL-2.0+
 Dual-licensed upstream; the package ships the BSD-3-Clause flavour (the
 build does not enable the GPL-only code paths).

Cross-compiled for armv7 iOS 10.x with clang + cctools ld64.  No Apple SDK
files are redistributed.
CR

# ---- payload ------------------------------------------------------------
sign "$BIN" "$w$PREFIX/bin/zstd"
chmod 755 "$w$PREFIX/bin/zstd"
ln -sf zstd "$w$PREFIX/bin/unzstd"
ln -sf zstd "$w$PREFIX/bin/zstdcat"
install -m 644 "$MAN" "$w$PREFIX/share/man/man1/zstd.1"

deb="$OUT/${PKG}_${VER}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb -Zgzip --root-owner-group -b "$w" "$deb"
echo "==> $deb"
sha256sum "$deb"
echo "    installs $PREFIX/bin/zstd (+unzstd/zstdcat symlinks, man page) with /usr/bin symlinks"
