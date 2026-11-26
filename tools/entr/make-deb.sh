#!/bin/bash
# Package the armv7 entr build into a .deb (entr4) for the APT repo.
#
# Skeleton follows tools/tig/make-deb.sh + tools/fzf/make-deb.sh (the
# current C-package conventions): staging under $root/tmp (host /tmp is a
# small tmpfs, AGENTS.md rule 0), SOURCE_DATE_EPOCH exported at the top and
# the changelog date derived from it (deterministic-deb convention,
# 2026-11-24, byte-ab wall #2), -Zgzip --root-owner-group, host-side
# ldid -S asserted via ldid -e, and the device-side re-sign in postinst
# (host signatures get Killed: 9 on this kernel -- deploy trio in
# ~/.dsh/AGENTS.md).
#
# Payload layout (fzf's bin/ prefix shape, per the porting task spec):
#   /var/mobile/tools/entr/bin/entr             the binary (signed)
#   /var/mobile/tools/entr/share/man/man1/entr.1  man page
#   /usr/bin/entr                               symlink (postinst/prerm)
#
# Depends: firmware (>= 10.3) ONLY.  entr links against nothing but
# libSystem (build.sh asserts this); it shells out to /bin/sh at runtime,
# which is stock firmware.  The -x status filter wants /usr/bin/awk at
# runtime -- an optional feature, not a dependency (the device may not
# ship awk; document, don't pin).
#
# Usage:
#   ./entr/build.sh && ./entr/make-deb.sh
#   DEBREV=2 ./entr/make-deb.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"
PKG="entr4"
VER="${ENTR_VERSION:-5.9}"
PREFIX="/var/mobile/tools/entr"

BIN="$OUT/entr-$VER-armv7"
[ -f "$BIN" ] || { echo "missing $BIN -- run ./entr/build.sh first" >&2; exit 1; }
SRC="$root/tmp/src/entr-$VER"
[ -f "$SRC/entr.1" ] || { echo "missing extracted source $SRC -- run ./entr/build.sh first" >&2; exit 1; }

# Same contract as tig/fzf make-deb.sh sign(): failures loud, signature
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
w="$(mktemp -d "$root/tmp/entr-deb.XXXXXX")"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" \
         "$w$PREFIX/bin" \
         "$w$PREFIX/share/man/man1" \
         "$w/usr/share/doc/$PKG"

cat > "$w/DEBIAN/control" <<CTRL
Package: $PKG
Name: entr $VER
Version: $VER-$DEBREV
Section: Utilities
Priority: optional
Architecture: iphoneos-arm
Depends: firmware (>= 10.3)
Maintainer: $MAINTAINER
Homepage: https://github.com/eradman/entr
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Description: entr $VER for armv7 iOS, kqueue-based file watcher
 Run arbitrary commands when files change: pipe a file list on stdin
 (ls *.c | entr make) and the command re-runs on every write/rename/
 delete/attribute change.  Pure kqueue EVFILT_VNODE -- the device kernel's
 own event engine (same engine nginx/nmap run); no inotify shim, no
 daemon.  Depends on nothing beyond libSystem.
 .
 Installs under $PREFIX with a /usr/bin/entr symlink.  The -x status
 filter needs /usr/bin/awk on the device at runtime (optional feature).
CTRL

cat > "$w/DEBIAN/postinst" <<'POST'
#!/bin/sh
# The host-side ldid signature is NOT accepted by the iOS 10 kernel policy
# on this target (installed-but-host-signed binaries die with "Killed: 9"
# before main()).  Re-sign with the on-device ldid on every install/upgrade.
set -e
PREFIX=/var/mobile/tools/entr
if [ -x /usr/bin/ldid ] || command -v ldid >/dev/null 2>&1; then
    ldid -S "$PREFIX/bin/entr" 2>/dev/null || true
fi
chown -R mobile:mobile "$PREFIX" 2>/dev/null || true
chmod 0755 "$PREFIX/bin/entr" 2>/dev/null || true
ln -sf "$PREFIX/bin/entr" /usr/bin/entr
exit 0
POST
chmod 755 "$w/DEBIAN/postinst"

cat > "$w/DEBIAN/prerm" <<'PRE'
#!/bin/sh
# Remove the PATH symlink before the payload disappears.
set -e
rm -f /usr/bin/entr
exit 0
PRE
chmod 755 "$w/DEBIAN/prerm"

cat > "$w/usr/share/doc/$PKG/changelog" <<CH
$PKG ($VER-$DEBREV) stable; urgency=medium

  * entr $VER, first port (upstream toy configure with TARGET_OS=Darwin;
    release tag pinned in sources.lock, fetched through tools/fetch-src.sh).
  * kqueue semantics verified on-device first (tools/entr/probe-kqueue.c:
    2-element EVFILT_VNODE changelist, NOTE_WRITE/RENAME/DELETE delivery
    with udata round-trip, EVFILT_READ NOTE_LOWAT, kevent64, timespec
    timeout) -- see docs/entr.md for the acceptance transcript.
  * Zero patches: NOTE_TRUNCATE and pledge() are handled by upstream's
    own missing/compat.h on Darwin.

 -- $MAINTAINER  $(date -R -u -d "@${SOURCE_DATE_EPOCH:-0}")
CH

cat > "$w/usr/share/doc/$PKG/copyright" <<CR
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: entr
Source: https://github.com/eradman/entr

Files: *
Copyright: 2012 Eric Radman
License: ISC-style
 Permission to use, copy, modify, and distribute this software for any
 purpose with or without fee is hereby granted, provided that the above
 copyright notice and this permission notice appear in all copies.

Cross-compiled for armv7 iOS 10.x.  No Apple SDK files are redistributed.
CR

# ---- payload ------------------------------------------------------------
sign "$BIN" "$w$PREFIX/bin/entr"
chmod 755 "$w$PREFIX/bin/entr"
install -m 644 "$SRC/entr.1" "$w$PREFIX/share/man/man1/entr.1"

deb="$OUT/${PKG}_${VER}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb -Zgzip --root-owner-group -b "$w" "$deb"
echo "==> $deb"
sha256sum "$deb"
echo "    installs $PREFIX/bin/entr (+man page) with /usr/bin/entr symlink;"
echo "    runtime needs only libSystem + /bin/sh (both stock firmware)"
