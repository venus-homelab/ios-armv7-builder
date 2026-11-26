#!/bin/bash
# make-deb.sh -- build zsh4 deb for armv7 iOS 10.3.3
#
# Payload layout:
#   /var/mobile/tools/zsh/bin/zsh                    the real binary (signed)
#   /var/mobile/tools/zsh/share/zsh/5.9/functions/   completion system etc.
#   /var/mobile/tools/bin/zsh                        symlink (login shells)
#
# The functions tree is zsh's other half (completion, prompt themes,
# vcs_info): without it zsh starts but is only half a shell.  It is
# installed from the BUILD TREE via `make install.fns` -- so make-deb.sh
# requires the same workspace the build ran in (true on CI: build, gate and
# package steps share one runner; true locally by construction).
#
# Usage: lang/zsh/make-deb.sh          # uses ../out/zsh-*-armv7 + tmp/src/zsh-5.9
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
ZSH_VERSION="${ZSH_VERSION:-5.9}"
DEBREV="${DEBREV:-2}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"

BIN_SRC="$(ls "$OUT"/zsh-$ZSH_VERSION-armv7 2>/dev/null | head -1)"
[ -n "$BIN_SRC" ] || { echo "missing $OUT/zsh-$ZSH_VERSION-armv7 -- run zsh/build.sh first" >&2; exit 1; }

# The build tree must still exist (make install.fns needs the built zsh to
# regenerate the functions).  On CI this is the same runner that just built;
# locally it is tmp/src/zsh-$V.
SRC="$root/tmp/src/zsh-$ZSH_VERSION"
[ -f "$SRC/Src/zsh" ] || { echo "missing build tree $SRC -- run zsh/build.sh first" >&2; exit 1; }

STAGE="$OUT/zsh4-stage"
DEB="$OUT/zsh4_${ZSH_VERSION}-${DEBREV}_iphoneos-arm.deb"
rm -rf "$STAGE" "$DEB"
mkdir -p "$STAGE/DEBIAN"

# 1. bin + functions via the real install targets (DESTDIR-staged).
#    install.* may trigger incremental recompiles (timestamp races in the
#    module tree), so the cross env must be live here too -- the env-landmine
#    lesson, make-deb edition (same defaults as build.sh).
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
make -C "$SRC" DESTDIR="$STAGE" install.bin install.fns >/dev/null

# 2. normalize: the binary must be root:wheel 755 + ad-hoc signed (ldid);
#    install.bin may also drop a zsh versioned alias -- keep only what the
#    layout promises.
BIN="$STAGE/var/mobile/tools/zsh/bin/zsh"
[ -f "$BIN" ] || { echo "install.bin did not stage the binary as expected" >&2; exit 1; }
chmod 755 "$BIN"
ldid -S "$BIN"
ldid -e "$BIN" >/dev/null    # assert: exit 0 only on a signed file
# the layout promises ONE binary: install.bin's versioned alias (zsh-5.9)
# shipped unsigned in 5.9-1 (2026-11-24 pool audit) -- the comment above
# promised keep-only-what-the-layout-promises; deliver it
for extra in "$STAGE/var/mobile/tools/zsh/bin/"zsh-*; do
    [ -e "$extra" ] || continue
    echo "    removing the unsigned versioned alias: $(basename "$extra")"
    rm -f "$extra"
done
find "$STAGE" -name '*.old' -delete 2>/dev/null || true

# 3. functions dir sanity: the completion system is the payload's point
FNDIR="$STAGE/var/mobile/tools/zsh/share/zsh/$ZSH_VERSION/functions"
[ -s "$FNDIR/compinit" ] || { echo "functions tree incomplete (no compinit)" >&2; exit 1; }
# compaudit flags group/world-writable fpath dirs and compinit then wants a
# tty to ask about them -- normalize: dirs 755, data files 644, root:root
# (dpkg-deb --root-owner-group reasserts ownership).
find "$STAGE/var/mobile/tools/zsh" -type d -exec chmod 755 {} +
find "$STAGE/var/mobile/tools/zsh/share" -type f -exec chmod 644 {} +
chown -R root:root "$STAGE/var/mobile/tools/zsh/share" 2>/dev/null || true
chown -R root:root "$STAGE/var/mobile/tools/zsh/share" 2>/dev/null || true

# 4. login-shell entry point
mkdir -p "$STAGE/var/mobile/tools/bin"
ln -sf ../zsh/bin/zsh "$STAGE/var/mobile/tools/bin/zsh"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: zsh4
Name: zsh
Version: $ZSH_VERSION-$DEBREV
Architecture: iphoneos-arm
Maintainer: $MAINTAINER
Section: Shells
Priority: optional
Depends: firmware (>= 10.3)
Description: zsh $ZSH_VERSION for iOS 10.3.3 armv7
 Static-modules build with UTF-8 multibyte support; zle linked against the
 device's ncurses 5.7 (terminfo from /usr/share/terminfo).  Installed under
 /var/mobile/tools/zsh with /var/mobile/tools/bin/zsh as the entry point;
 add that to \$PATH or chsh-style wrappers to use it.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
BIN="/var/mobile/tools/zsh/bin/zsh"
[ -x "$BIN" ] && ldid -e "$BIN" >/dev/null 2>&1
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
[ -L "/var/mobile/tools/bin/zsh" ] && rm -f "/var/mobile/tools/bin/zsh" || true
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

dpkg-deb --root-owner-group -Zgzip --build "$STAGE" "$DEB" >/dev/null
rm -rf "$STAGE"
echo "Built $DEB"
dpkg -I "$DEB" | head -8
echo "SHA256: $(sha256sum "$DEB" | cut -d' ' -f1)"
