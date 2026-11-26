#!/bin/bash
# Package the armv7 git-lfs build into a .deb (git-lfs4) for the APT repo.
#
# Skeleton follows net/tailcat/make-deb.sh + the Go-template conventions
# (tailscale/make-deb.sh): staging under $root/tmp (host /tmp is a small
# tmpfs, AGENTS.md rule 0), SOURCE_DATE_EPOCH exported at the top and the
# changelog date derived from it (deterministic-deb convention, 2026-11-24),
# -Zgzip --root-owner-group, host-side ldid -S asserted via ldid -e, and the
# device-side re-sign in postinst (host signatures get Killed: 9 on this
# kernel -- see the deploy trio in ~/.dsh/AGENTS.md).
#
# Payload layout:
#   /var/mobile/tools/git-lfs/bin/git-lfs       the Go binary (signed)
#   /usr/bin/git-lfs                            symlink (postinst/prerm)
#
# git-lfs is a git remote helper: after install, a plain `git lfs` works
# from the device's git (repo tools/git) through the /usr/bin symlink; for
# GIT_SSH/credential flows the device still needs its own git+ssh setup.
#
# Usage:
#   ./git-lfs/build.sh && ./git-lfs/make-deb.sh
#   DEBREV=2 ./git-lfs/make-deb.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"
PKG="git-lfs4"
VER="${LFS_VERSION:-3.8.1}"
PREFIX="/var/mobile/tools/git-lfs"

BIN="$OUT/git-lfs-$VER-armv7"
[ -f "$BIN" ] || { echo "missing $BIN -- run ./git-lfs/build.sh first" >&2; exit 1; }

# Same contract as tailcat/make-deb.sh sign(): failures loud, signature
# asserted with ldid -e, using the host ldid that the repo's toolchain ships.
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
w="$(mktemp -d "$root/tmp/git-lfs-deb.XXXXXX")"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" "$w$PREFIX/bin" "$w/usr/share/doc/$PKG"

cat > "$w/DEBIAN/control" <<CTRL
Package: $PKG
Name: git-lfs $VER
Version: $VER-$DEBREV
Section: Devel
Priority: optional
Architecture: iphoneos-arm
Depends: firmware (>= 10.3), ca-certificates4 | ca-certificates
Maintainer: $MAINTAINER
Homepage: https://github.com/git-lfs/git-lfs
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Description: git-lfs $VER for armv7 iOS, Go 1.27.2 darwin/arm revived port
 Git Large File Storage: git remote helper for storing large blobs outside
 the repository (Go canary port of the repo's Go reproducible template).
 .
 Installs under /var/mobile/tools/git-lfs with /usr/bin/git-lfs symlink;
 works with the repo's git4 build via plain \`git lfs <cmd>\`.
CTRL

cat > "$w/DEBIAN/postinst" <<'POST'
#!/bin/sh
# The host-side ldid signature is NOT accepted by the iOS 10 kernel policy
# on this target (installed-but-host-signed binaries die with "Killed: 9"
# before main()).  Re-sign with the on-device ldid on every install/upgrade.
set -e
PREFIX=/var/mobile/tools/git-lfs
if [ -x /usr/bin/ldid ] || command -v ldid >/dev/null 2>&1; then
    ldid -S "$PREFIX/bin/git-lfs" 2>/dev/null || true
fi
chown -R mobile:mobile "$PREFIX" 2>/dev/null || true
chmod 0755 "$PREFIX/bin/git-lfs" 2>/dev/null || true
ln -sf "$PREFIX/bin/git-lfs" /usr/bin/git-lfs
exit 0
POST
chmod 755 "$w/DEBIAN/postinst"

cat > "$w/DEBIAN/prerm" <<'PRE'
#!/bin/sh
# Remove the PATH symlink before the payload disappears.
set -e
rm -f /usr/bin/git-lfs
exit 0
PRE
chmod 755 "$w/DEBIAN/prerm"

cat > "$w/usr/share/doc/$PKG/changelog" <<CH
$PKG ($VER-$DEBREV) stable; urgency=medium

  * git-lfs $VER, second canary port through the Go reproducible template
    (fetch-src pinned source, godeps xsys-darwin-arm + xnet-darwin-arm via
    go.mod replace, -trimpath -buildvcs=false, check-undefined gate).
  * Single binary + /usr/bin symlink; man pages not shipped (upstream
    generates them with asciidoctor at release time).

 -- $MAINTAINER  $(date -R -u -d "@${SOURCE_DATE_EPOCH:-0}")
CH

cat > "$w/usr/share/doc/$PKG/copyright" <<CR
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: git-lfs
Source: https://github.com/git-lfs/git-lfs

Files: *
Copyright: 2015-2026 GitHub, Inc. and Git LFS contributors
License: MIT

Cross-compiled for armv7 iOS 10.x with a revived Go 1.27.2 darwin/arm
toolchain.  No Apple SDK files are redistributed.
CR

# ---- payload ------------------------------------------------------------
sign "$BIN" "$w$PREFIX/bin/git-lfs"
chmod 755 "$w$PREFIX/bin/git-lfs"

deb="$OUT/${PKG}_${VER}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb -Zgzip --root-owner-group -b "$w" "$deb"
echo "==> $deb"
sha256sum "$deb"
echo "    installs $PREFIX/bin/git-lfs with /usr/bin/git-lfs symlink"
