#!/bin/bash
# Package the armv7 lz4 CLI build into a .deb (lz4) for the APT repo.
#
# Skeleton follows tools/fzf/make-deb.sh / tools/git-lfs/make-deb.sh:
# staging under $root/tmp (host /tmp is a small tmpfs, AGENTS.md rule 0),
# SOURCE_DATE_EPOCH exported at the top and the changelog date derived from
# it (deterministic-deb convention, 2026-11-24), -Zgzip --root-owner-group,
# host-side ldid -S asserted via ldid -e, and the device-side re-sign in
# postinst (host signatures get Killed: 9 on this kernel -- deploy trio in
# ~/.dsh/AGENTS.md).
#
# Package name is plain "lz4" following the git precedent (no numeric
# suffix; nothing else on the device claims the name).
#
# Payload layout (upstream `make install` shape exactly):
#   /var/mobile/tools/lz4/bin/lz4          the real binary (signed)
#   /var/mobile/tools/lz4/bin/lz4c         symlink -> lz4 (legacy CLI args)
#   /var/mobile/tools/lz4/bin/unlz4        symlink -> lz4 (argv[0] switch)
#   /var/mobile/tools/lz4/bin/lz4cat       symlink -> lz4 (argv[0] switch)
#   /var/mobile/tools/lz4/share/man/man1/lz4.1
#        + lz4c.1/lz4cat.1/unlz4.1 symlinks (upstream install layout)
#   /usr/bin/{lz4,lz4c,unlz4,lz4cat}       symlinks (postinst/prerm)
#
# Depends is only the firmware floor: the binary's single recorded dylib is
# libSystem.B.dylib (asserted in build.sh), everything else is static.
#
# Usage:
#   ./lz4/build.sh && ./lz4/make-deb.sh
#   DEBREV=2 ./lz4/make-deb.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"
PKG="lz4"
VER="${LZ4_VERSION:-1.11.1}"
PREFIX="/var/mobile/tools/lz4"

BIN="$OUT/lz4-$VER-armv7"
[ -f "$BIN" ] || { echo "missing $BIN -- run ./lz4/build.sh first" >&2; exit 1; }
SRC="$root/tmp/src/lz4-$VER"
MAN="$SRC/programs/lz4.1"
[ -f "$MAN" ] || { echo "missing $MAN -- run ./lz4/build.sh first" >&2; exit 1; }

# Same contract as fzf/make-deb.sh sign(): failures loud, signature asserted
# with ldid -e, using the host ldid that the repo's toolchain ships.
LDID="$HOME/ios-tool/bin/ldid"
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
w="$(mktemp -d "$root/tmp/lz4-deb.XXXXXX")"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" \
         "$w$PREFIX/bin" \
         "$w$PREFIX/share/man/man1" \
         "$w/usr/share/doc/$PKG"

cat > "$w/DEBIAN/control" <<CTRL
Package: $PKG
Name: lz4
Version: $VER-$DEBREV
Section: Utilities
Priority: optional
Architecture: iphoneos-arm
Depends: firmware (>= 10.3)
Maintainer: $MAINTAINER
Homepage: https://github.com/lz4/lz4
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Description: lz4 $VER for armv7 iOS, the .lz4 compression CLI
 LZ4 extremely fast lossless compression command line tool, pinned to the
 latest stable release per the upstream release page (v1.11.1, 2026-11-10
 point fix; official asset sha256 sidecar cross-checked).  Plain-make
 cross build, single libSystem dependency, no configure stage.
 .
 Installs under /var/mobile/tools/lz4 with /usr/bin symlinks for lz4, lz4c,
 unlz4 and lz4cat (argv[0] aliases, upstream make-install convention).
CTRL

cat > "$w/DEBIAN/postinst" <<'POST'
#!/bin/sh
# The host-side ldid signature is NOT accepted by the iOS 10 kernel policy
# on this target (installed-but-host-signed binaries die with "Killed: 9"
# before main()).  Re-sign with the on-device ldid on every install/upgrade.
set -e
PREFIX=/var/mobile/tools/lz4
if [ -x /usr/bin/ldid ] || command -v ldid >/dev/null 2>&1; then
    ldid -S "$PREFIX/bin/lz4" 2>/dev/null || true
fi
chown -R mobile:mobile "$PREFIX" 2>/dev/null || true
chmod 0755 "$PREFIX/bin/lz4" 2>/dev/null || true
ln -sf "$PREFIX/bin/lz4" /usr/bin/lz4
ln -sf "$PREFIX/bin/lz4" /usr/bin/lz4c
ln -sf "$PREFIX/bin/lz4" /usr/bin/unlz4
ln -sf "$PREFIX/bin/lz4" /usr/bin/lz4cat
exit 0
POST
chmod 755 "$w/DEBIAN/postinst"

cat > "$w/DEBIAN/prerm" <<'PRE'
#!/bin/sh
# Remove the PATH symlinks before the payload disappears.
set -e
rm -f /usr/bin/lz4 /usr/bin/lz4c /usr/bin/unlz4 /usr/bin/lz4cat
exit 0
PRE
chmod 755 "$w/DEBIAN/prerm"

cat > "$w/usr/share/doc/$PKG/changelog" <<CH
$PKG ($VER-$DEBREV) stable; urgency=medium

  * lz4 $VER CLI, first port (.lz4 workflow).  Pinned to the latest stable
    release per the upstream release page (v1.11.1, 2026-11-10 point fix),
    official release asset, sha256 computed from the downloaded bytes and
    cross-checked against the upstream .sha256 sidecar.
  * lz4-release posture (upstream default: NDEBUG, no debug flags); the
    pthread probe compiles the multithreaded IO path in, pthread_* resolves
    from the device libSystem; single libSystem.B.dylib dependency,
    check-undefined gate 85/85.

 -- $MAINTAINER  $(date -R -u -d "@${SOURCE_DATE_EPOCH:-0}")
CH

cat > "$w/usr/share/doc/$PKG/copyright" <<CR
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: lz4
Source: https://github.com/lz4/lz4

Files: *
Copyright: 2011-2026 Yann Collet
License: BSD-2-Clause

Cross-compiled for armv7 iOS 10.x with clang + cctools ld64.  No Apple SDK
files are redistributed.
CR

# ---- payload ------------------------------------------------------------
sign "$BIN" "$w$PREFIX/bin/lz4"
chmod 755 "$w$PREFIX/bin/lz4"
ln -sf lz4 "$w$PREFIX/bin/lz4c"
ln -sf lz4 "$w$PREFIX/bin/unlz4"
ln -sf lz4 "$w$PREFIX/bin/lz4cat"
install -m 644 "$MAN" "$w$PREFIX/share/man/man1/lz4.1"
ln -sf lz4.1 "$w$PREFIX/share/man/man1/lz4c.1"
ln -sf lz4.1 "$w$PREFIX/share/man/man1/lz4cat.1"
ln -sf lz4.1 "$w$PREFIX/share/man/man1/unlz4.1"

deb="$OUT/${PKG}_${VER}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb -Zgzip --root-owner-group -b "$w" "$deb"
echo "==> $deb"
sha256sum "$deb"
echo "    installs $PREFIX/bin/lz4 (+lz4c/unlz4/lz4cat symlinks, man pages) with /usr/bin symlinks"
