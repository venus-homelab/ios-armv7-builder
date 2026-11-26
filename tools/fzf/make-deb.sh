#!/bin/bash
# Package the armv7 fzf build into a .deb (fzf4) for the APT repo.
#
# Skeleton follows net/tailcat/make-deb.sh + the Go-template conventions
# (tailscale/make-deb.sh): staging under $root/tmp (host /tmp is a small
# tmpfs, AGENTS.md rule 0), SOURCE_DATE_EPOCH exported at the top and the
# changelog date derived from it (deterministic-deb convention, 2026-11-24),
# -Zgzip --root-owner-group, host-side ldid -S asserted via ldid -e, and the
# device-side re-sign in postinst (host signatures get Killed: 9 on this
# kernel -- see the deploy trio in ~/.dsh/AGENTS.md).
#
# Payload layout (fzf's real distribution shape, mirrored from the upstream
# tarball):
#   /var/mobile/tools/fzf/bin/fzf               the Go binary (signed)
#   /var/mobile/tools/fzf/bin/fzf-tmux          tmux launcher script
#   /var/mobile/tools/fzf/bin/fzf-preview.sh    $FZF_DEFAULT preview helper
#   /var/mobile/tools/fzf/share/man/man1/       man page
#   /var/mobile/tools/fzf/share/fzf/shell/      completion + key bindings
#   /usr/bin/fzf, /usr/bin/fzf-tmux             symlinks (postinst/prerm)
#
# Usage:
#   ./fzf/build.sh && ./fzf/make-deb.sh
#   DEBREV=2 ./fzf/make-deb.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"
PKG="fzf4"
VER="${FZF_VERSION:-0.75.0}"
PREFIX="/var/mobile/tools/fzf"

BIN="$OUT/fzf-$VER-armv7"
[ -f "$BIN" ] || { echo "missing $BIN -- run ./fzf/build.sh first" >&2; exit 1; }
SRC="$root/tmp/src/fzf-$VER"
[ -f "$SRC/main.go" ] || { echo "missing extracted source $SRC -- run ./fzf/build.sh first" >&2; exit 1; }

# Same contract as tailcat/make-deb.sh sign(): failures loud, signature
# asserted with ldid -e, using the host ldid that the repo's toolchain ships.
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
w="$(mktemp -d "$root/tmp/fzf-deb.XXXXXX")"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" \
         "$w$PREFIX/bin" \
         "$w$PREFIX/share/man/man1" \
         "$w$PREFIX/share/fzf/shell" \
         "$w/usr/share/doc/$PKG"

cat > "$w/DEBIAN/control" <<CTRL
Package: $PKG
Name: fzf $VER
Version: $VER-$DEBREV
Section: Utilities
Priority: optional
Architecture: iphoneos-arm
Depends: firmware (>= 10.3), ca-certificates4 | ca-certificates
Maintainer: $MAINTAINER
Homepage: https://github.com/junegunn/fzf
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Description: fzf $VER for armv7 iOS, Go 1.27.2 darwin/arm revived port
 Command-line fuzzy finder (Go canary port of the repo's Go reproducible
 template).  Interactive TUI over tmux works; direct terminal use depends
 on the device terminal's termios support.
 .
 Installs under /var/mobile/tools/fzf with /usr/bin symlinks.  See
 $PREFIX/share/fzf/shell for completions and key bindings.
CTRL

cat > "$w/DEBIAN/postinst" <<'POST'
#!/bin/sh
# The host-side ldid signature is NOT accepted by the iOS 10 kernel policy
# on this target (installed-but-host-signed binaries die with "Killed: 9"
# before main()).  Re-sign with the on-device ldid on every install/upgrade.
set -e
PREFIX=/var/mobile/tools/fzf
if [ -x /usr/bin/ldid ] || command -v ldid >/dev/null 2>&1; then
    ldid -S "$PREFIX/bin/fzf" 2>/dev/null || true
fi
chown -R mobile:mobile "$PREFIX" 2>/dev/null || true
chmod 0755 "$PREFIX/bin/fzf" "$PREFIX/bin/fzf-tmux" "$PREFIX/bin/fzf-preview.sh" 2>/dev/null || true
ln -sf "$PREFIX/bin/fzf" /usr/bin/fzf
ln -sf "$PREFIX/bin/fzf-tmux" /usr/bin/fzf-tmux
exit 0
POST
chmod 755 "$w/DEBIAN/postinst"

cat > "$w/DEBIAN/prerm" <<'PRE'
#!/bin/sh
# Remove the PATH symlinks before the payload disappears.
set -e
rm -f /usr/bin/fzf /usr/bin/fzf-tmux
exit 0
PRE
chmod 755 "$w/DEBIAN/prerm"

cat > "$w/usr/share/doc/$PKG/changelog" <<CH
$PKG ($VER-$DEBREV) stable; urgency=medium

  * fzf $VER, first canary port through the Go reproducible template
    (fetch-src pinned source, godeps/xsys-darwin-arm via go.mod replace,
    -trimpath -buildvcs=false, check-undefined gate).
  * Payload mirrored from the upstream tarball: fzf-tmux, fzf-preview.sh,
    man page, shell completions/key bindings.

 -- $MAINTAINER  $(date -R -u -d "@${SOURCE_DATE_EPOCH:-0}")
CH

cat > "$w/usr/share/doc/$PKG/copyright" <<CR
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: fzf
Source: https://github.com/junegunn/fzf

Files: *
Copyright: 2013-2026 Junegunn Choi
License: MIT

Cross-compiled for armv7 iOS 10.x with a revived Go 1.27.2 darwin/arm
toolchain.  No Apple SDK files are redistributed.
CR

# ---- payload ------------------------------------------------------------
sign "$BIN" "$w$PREFIX/bin/fzf"
chmod 755 "$w$PREFIX/bin/fzf"
install -m 755 "$SRC/bin/fzf-tmux" "$w$PREFIX/bin/fzf-tmux"
install -m 755 "$SRC/bin/fzf-preview.sh" "$w$PREFIX/bin/fzf-preview.sh"
install -m 644 "$SRC/man/man1/fzf.1" "$w$PREFIX/share/man/man1/fzf.1" 2>/dev/null \
    || echo "    (no prebuilt man page in tarball -- skipped)"
for f in "$SRC"/shell/*; do
    [ -f "$f" ] || continue
    install -m 644 "$f" "$w$PREFIX/share/fzf/shell/$(basename "$f")"
done

deb="$OUT/${PKG}_${VER}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb -Zgzip --root-owner-group -b "$w" "$deb"
echo "==> $deb"
sha256sum "$deb"
echo "    installs $PREFIX/bin/fzf (+fzf-tmux, man, shell integration) with /usr/bin symlinks"
