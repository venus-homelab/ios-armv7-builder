#!/bin/bash
# Package the armv7 privoxy build into a .deb (privoxy4) for the APT repo.
#
# Skeleton follows tools/tig/make-deb.sh (fzf/git-lfs canary conventions):
# staging under $root/tmp (host /tmp is a small tmpfs, AGENTS.md rule 0),
# SOURCE_DATE_EPOCH exported at the top and the changelog date derived from
# it, -Zgzip --root-owner-group, host-side ldid -S asserted via ldid -e, and
# the device-side re-sign in postinst (host signatures get Killed: 9 on this
# kernel -- the deploy trio in ~/.dsh/AGENTS.md).
#
# Payload layout (task spec: bin + etc under the package prefix):
#   /var/mobile/tools/privoxy/bin/privoxy           the binary (signed)
#   /var/mobile/tools/privoxy/etc/config            config template (edited,
#                                                   absolute payload paths)
#   /var/mobile/tools/privoxy/etc/*.action|filter   actions/filter files
#   /var/mobile/tools/privoxy/etc/trust             trust file
#   /var/mobile/tools/privoxy/etc/templates/*       CGI pages (confdir/templates)
#   /var/mobile/tools/privoxy/var/log/              created by postinst (logdir)
#   /usr/bin/privoxy                                symlink (postinst/prerm)
#
# Config paths are RUNTIME directives (nothing baked into the binary), so the
# daemon must be started with the explicit config path:
#   privoxy /var/mobile/tools/privoxy/etc/config
# (bare `privoxy` looks for ./config in the CWD -- upstream default.)
#
# Depends: firmware (>= 10.3) only.  Pinned by build, not guessed: otool -L
# shows exactly one LC_LOAD_DYLIB (/usr/lib/libSystem.B.dylib); pcre2 and
# zlib are static archives with zero members left unresolved
# (check-undefined.sh 117/117 at build time).
#
# Usage:
#   ./build.sh && ./make-deb.sh
#   DEBREV=2 ./make-deb.sh
set -euo pipefail
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
DEBREV="${DEBREV:-1}"
MAINTAINER="${MAINTAINER:-Hesper <venus-homelab@users.noreply.github.com>}"
PKG="privoxy4"
VER="${PRIVOXY_VERSION:-4.1.0}"
PREFIX="/var/mobile/tools/privoxy"

BIN="$OUT/privoxy-$VER-armv7"
[ -f "$BIN" ] || { echo "missing $BIN -- run ./build.sh first" >&2; exit 1; }
SRC="$root/tmp/src/privoxy-$VER-stable"
for f in config default.action default.filter match-all.action trust user.action user.filter; do
    [ -f "$SRC/$f" ] || { echo "missing extracted source file $SRC/$f -- run ./build.sh first" >&2; exit 1; }
done
[ -d "$SRC/templates" ] || { echo "missing $SRC/templates -- run ./build.sh first" >&2; exit 1; }

# Same contract as tig/fzf/git-lfs make-deb.sh sign(): failures loud,
# signature asserted with ldid -e.
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
w="$(mktemp -d "$root/tmp/privoxy-deb.XXXXXX")"; trap 'rm -rf "$w"' EXIT
mkdir -p "$w/DEBIAN" \
         "$w$PREFIX/bin" \
         "$w$PREFIX/etc" \
         "$w/usr/share/doc/$PKG"

cat > "$w/DEBIAN/control" <<CTRL
Package: $PKG
Name: Privoxy $VER
Version: $VER-$DEBREV
Section: Networking
Priority: optional
Architecture: iphoneos-arm
Depends: firmware (>= 10.3)
Maintainer: $MAINTAINER
Homepage: https://www.privoxy.org/
Depiction: https://github.com/venus-homelab/ios-armv7-builder
Description: Privoxy $VER for armv7 iOS, non-caching filtering HTTP proxy
 Privacy-enhancing HTTP proxy with header/header-forge, ad blocking and
 content filtering (pcrs/PCRE2).  Local entry point on 127.0.0.1:8118 that
 forwards upstream -- including SOCKS5 via forward-socks5 -- covering the
 proxychains __RESTRICT blind spot for plain HTTP clients.
 .
 Everything is statically embedded (PCRE2, zlib); the only dynamic
 dependency is libSystem.  https-inspection is compiled out (needs a TLS
 backend; see docs/privoxy.md for the openssl4 outlook).
 .
 Installs under $PREFIX (bin + etc); /usr/bin/privoxy symlink.  Start with
 the explicit config path: privoxy $PREFIX/etc/config -- or --no-daemon for
 foreground mode.
CTRL

cat > "$w/DEBIAN/postinst" <<'POST'
#!/bin/sh
# The host-side ldid signature is NOT accepted by the iOS 10 kernel policy
# on this target (installed-but-host-signed binaries die with "Killed: 9"
# before main()).  Re-sign with the on-device ldid on every install/upgrade.
set -e
PREFIX=/var/mobile/tools/privoxy
if [ -x /usr/bin/ldid ] || command -v ldid >/dev/null 2>&1; then
    ldid -S "$PREFIX/bin/privoxy" 2>/dev/null || true
fi
chown -R mobile:mobile "$PREFIX" 2>/dev/null || true
chmod 0755 "$PREFIX/bin/privoxy" 2>/dev/null || true
mkdir -p "$PREFIX/var/log"
chown mobile:mobile "$PREFIX/var/log" 2>/dev/null || true
ln -sf "$PREFIX/bin/privoxy" /usr/bin/privoxy
exit 0
POST
chmod 755 "$w/DEBIAN/postinst"

cat > "$w/DEBIAN/prerm" <<'PRE'
#!/bin/sh
# Remove the PATH symlink before the payload disappears.
set -e
rm -f /usr/bin/privoxy
exit 0
PRE
chmod 755 "$w/DEBIAN/prerm"

cat > "$w/usr/share/doc/$PKG/changelog" <<CH
$PKG ($VER-$DEBREV) stable; urgency=medium

  * Privoxy $VER, first port (configure package; release tarball pinned in
    sources.lock, fetched through tools/fetch-src.sh; configure + config.h.in
    generated on the build host -- the tarball ships neither).
  * PCRE2 statically embedded, built from the sources.lock-locked nmap 7.95
    bundled libpcre into a private tree (nginx/build.sh recipe); both
    libpcre2-8 and libpcre2-posix archives provided (configure bakes both
    into LIBS).
  * zlib statically embedded (FEATURE_ZLIB: decompress responses before
    filtering).  --enable-compression left off.
  * https-inspection compiled out (needs a TLS backend: mbedTLS/OpenSSL/
    wolfSSL); pcre JIT disabled (no RWX mmap on iOS).
  * Config template edited for the payload: absolute confdir/logdir, plus a
    forward-socks5 example for the SOCKS5 upstream use case.

 -- $MAINTAINER  $(date -R -u -d "@${SOURCE_DATE_EPOCH:-0}")
CH

cat > "$w/usr/share/doc/$PKG/copyright" <<CR
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: privoxy
Source: https://sourceforge.net/projects/ijbswa/

Files: *
Copyright: 2001-2026 the Privoxy team (https://www.privoxy.org/)
License: GPL-2+
 Privoxy is licensed under the GNU General Public License, version 2 or
 (at your option) any later version (LICENSE + LICENSE.GPLv3 in the
 upstream tarball).

The statically embedded PCRE2 comes from nmap 7.95's bundled libpcre
(BSD licence, see LICENCE in the pcre2 sources); the statically embedded
zlib is 1.3.1 (zlib licence).  Cross-compiled for armv7 iOS 10.x.  No
Apple SDK files are redistributed.
CR

# ---- payload ------------------------------------------------------------
sign "$BIN" "$w$PREFIX/bin/privoxy"
chmod 755 "$w$PREFIX/bin/privoxy"

# The upstream config ships CWD-relative confdir/logdir ("."), which only
# works when the daemon's CWD is the config dir.  Point them at the payload
# (absolute) so the daemon can be started from anywhere with the explicit
# config path, and append the forward/forward-socks5 device block.
sed -e "s|^confdir \.\$|confdir $PREFIX/etc|" \
    -e "s|^logdir \.\$|logdir $PREFIX/var/log|" \
    "$SRC/config" > "$w$PREFIX/etc/config"
grep -q "^confdir $PREFIX/etc$" "$w$PREFIX/etc/config" || { echo "confdir sed did not match -- upstream config changed?" >&2; exit 1; }
grep -q "^logdir $PREFIX/var/log$" "$w$PREFIX/etc/config" || { echo "logdir sed did not match -- upstream config changed?" >&2; exit 1; }
cat >> "$w$PREFIX/etc/config" <<'FWD'

# --- privoxy4 (iOS) forwarding defaults -----------------------------------
# Default: direct connection through the device's own network.
# (forward directives: the LAST match for a URL wins.)
forward / .
# Upstream SOCKS5 example -- the proxychains __RESTRICT use case.  Uncomment
# and replace host:port with the real upstream (the trailing "." means DNS
# is resolved remotely by the SOCKS5 server):
# forward-socks5 / 127.0.0.1:9050 .
FWD

# actions/filter files: generated default.action + upstream stock files
for f in default.action default.filter match-all.action trust user.action user.filter; do
    install -m 644 "$SRC/$f" "$w$PREFIX/etc/$f"
done
# CGI templates live at confdir/templates (upstream resolution order:
# templdir directive, else confdir/templates)
mkdir -p "$w$PREFIX/etc/templates"
find "$SRC/templates" -type f -maxdepth 1 -print0 \
    | xargs -0 -I{} install -m 644 {} "$w$PREFIX/etc/templates/"

deb="$OUT/${PKG}_${VER}-${DEBREV}_iphoneos-arm.deb"
dpkg-deb -Zgzip --root-owner-group -b "$w" "$deb"
echo "==> $deb"
sha256sum "$deb"
echo "    installs $PREFIX/bin/privoxy + etc (config/*.action/*.filter/templates)"
echo "    with /usr/bin/privoxy symlink; Depends: firmware (>= 10.3) only"
echo "    (single LC_LOAD_DYLIB: /usr/lib/libSystem.B.dylib)"
