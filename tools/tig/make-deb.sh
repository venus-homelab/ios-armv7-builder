#!/bin/bash
# Package the armv7 tig build into a .deb (tig4) for the APT repo.
#
# Skeleton follows tools/fzf/make-deb.sh + tools/git-lfs/make-deb.sh (the
# current canary conventions): staging under $root/tmp (host /tmp is a small
# tmpfs, AGENTS.md rule 0), SOURCE_DATE_EPOCH exported at the top and the
# changelog date derived from it (deterministic-deb convention, 2026-11-24),
# -Zgzip --root-owner-group, host-side ldid -S asserted via ldid -e, and the
# device-side re-sign in postinst (host signatures get Killed: 9 on this
# kernel -- see the deploy trio in ~/.dsh/AGENTS.md).
#
# Payload layout (ncdu/less prefix shape + /usr/bin symlink like the
# fzf/git-lfs canaries):
#   /var/mobile/tools/tig/tig        the binary (signed)
#   /var/mobile/tools/tig/etc/tigrc  default config (SYSCONFDIR is baked
#                                    into the binary as that exact path)
#   /usr/bin/tig                     symlink (postinst/prerm)
#
# tig shells out to `git` for every view, so the package Depends on the
# device's git (git4); ncursesw + terminfo come from the device firmware
# itself (linked at build time -- see build.sh).
#
# Usage:
#   ./tig/build.sh && ./tig/make-deb.sh
#   DEBREV=2 ./tig/make-deb.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
DEBREV="${DEBREV:-2}"   # -2: Depends git4 -> git (2026-11-25, pool package is
                        # named `git`, not git4 -- control change, DEBREV iron
                        # rule applies even though the payload is unchanged)
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"
PKG="tig4"
VER="${TIG_VERSION:-2.6.1}"
PREFIX="/var/mobile/tools/tig"

BIN="$OUT/tig-$VER-armv7"
[ -f "$BIN" ] || { echo "missing $BIN -- run ./tig/build.sh first" >&2; exit 1; }
SRC="$root/tmp/src/tig-$VER"
[ -f "$SRC/tigrc" ] || { echo "missing extracted source $SRC -- run ./tig/build.sh first" >&2; exit 1; }

# Same contract as fzf/git-lfs make-deb.sh sign(): failures loud, signature
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
w="$(mktemp -d "$root/tmp/tig-deb.XXXXXX")"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" \
         "$w$PREFIX/etc" \
         "$w/usr/share/doc/$PKG"

cat > "$w/DEBIAN/control" <<CTRL
Package: $PKG
Name: tig $VER
Version: $VER-$DEBREV
Section: Devel
Priority: optional
Architecture: iphoneos-arm
Depends: firmware (>= 10.3), git
Maintainer: $MAINTAINER
Homepage: https://github.com/jonas/tig
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Description: tig $VER for armv7 iOS, ncurses text-mode interface to git
 Text-mode UI for git: stage chunks interactively, browse refs/diffs/logs
 and blame without leaving the terminal.  Every view shells out to git at
 runtime, so the device's git package is a hard dependency.
 .
 Linked against the device's own libncursesw.5.dylib (terminfo from
 /usr/share/terminfo); GNU libiconv is statically embedded.  The interactive
 prompt runs without readline (upstream fallback path).  Man pages are not
 built (upstream needs asciidoc+xmlto; see docs/tig.md).
 .
 Installs under $PREFIX with /usr/bin/tig symlink; default config at
 $PREFIX/etc/tigrc (edit ~/.tigrc to override).
CTRL

cat > "$w/DEBIAN/postinst" <<'POST'
#!/bin/sh
# The host-side ldid signature is NOT accepted by the iOS 10 kernel policy
# on this target (installed-but-host-signed binaries die with "Killed: 9"
# before main()).  Re-sign with the on-device ldid on every install/upgrade.
set -e
PREFIX=/var/mobile/tools/tig
if [ -x /usr/bin/ldid ] || command -v ldid >/dev/null 2>&1; then
    ldid -S "$PREFIX/tig" 2>/dev/null || true
fi
chown -R mobile:mobile "$PREFIX" 2>/dev/null || true
chmod 0755 "$PREFIX/tig" 2>/dev/null || true
ln -sf "$PREFIX/tig" /usr/bin/tig
exit 0
POST
chmod 755 "$w/DEBIAN/postinst"

cat > "$w/DEBIAN/prerm" <<'PRE'
#!/bin/sh
# Remove the PATH symlink before the payload disappears.
set -e
rm -f /usr/bin/tig
exit 0
PRE
chmod 755 "$w/DEBIAN/prerm"

cat > "$w/usr/share/doc/$PKG/changelog" <<CH
$PKG ($VER-$DEBREV) stable; urgency=medium

  * tig $VER, first port (configure package; release tarball pinned in
    sources.lock, fetched through tools/fetch-src.sh).
  * Curses: device-extracted ncurses 5.7 wide headers + the device's
    libncursesw.5.dylib on the link line (less/ncdu recipe).
  * iconv: GNU libiconv 1.17 statically embedded -- the device ships no
    libiconv.2.dylib (zsh precedent); no iconv runtime dependency.
  * wordexp/mkstemps via tig's own compat/ fallbacks; no readline (device
    has none, upstream fallback path); no PCRE.

 -- $MAINTAINER  $(date -R -u -d "@${SOURCE_DATE_EPOCH:-0}")
CH

cat > "$w/usr/share/doc/$PKG/copyright" <<CR
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: tig
Source: https://github.com/jonas/tig

Files: *
Copyright: 2006-2026 Jonas Fonseca and tig contributors
License: GPL-2+

The static libiconv used at link time is GNU libiconv 1.17 (LGPL-2.1+,
built but not redistributed as a separate archive).  Cross-compiled for
armv7 iOS 10.x.  No Apple SDK files are redistributed.
CR

# ---- payload ------------------------------------------------------------
sign "$BIN" "$w$PREFIX/tig"
chmod 755 "$w$PREFIX/tig"
install -m 644 "$SRC/tigrc" "$w$PREFIX/etc/tigrc"

deb="$OUT/${PKG}_${VER}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb -Zgzip --root-owner-group -b "$w" "$deb"
echo "==> $deb"
sha256sum "$deb"
echo "    installs $PREFIX/tig (+etc/tigrc) with /usr/bin/tig symlink;"
echo "    runtime needs the device's git package, terminfo and libncursesw.5"
