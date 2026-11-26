#!/bin/bash
# Build torsocks 2.5.0 for armv7 iOS 10.3.3 on Linux (SDK sysroot mode).
#
# What it is: the tor-native per-command socksifier.  libtorsocks.dylib is
# injected with DYLD_INSERT_LIBRARIES by the `torsocks` wrapper script; its
# exported connect()/socket()/gethostbyname()/... replace libSystem's for
# the child process and redirect them into tor's SOCKS5 (device tor4:
# 127.0.0.1:9050).  Complements privoxy4 (HTTP entry) with per-command
# takeover; overlaps proxychains4 but is tor-specific (onion cookie pool,
# SOCKS5 auth isolation, leak-hardening deny rules).
#
# FEASIBILITY GATE (2026-11-25, probe/ on-device, evidence in
# net/torsocks/probe/matrix-20261125.log):
#   (a) unsigned host+lib + DYLD_INSERT ....... Killed: 9 (kernel signature
#       policy, NOT a DYLD_INSERT restriction)
#   (b) on-device ldid -S host+lib + DYLD_INSERT -> constructor ran  ✓
#   (c) entitlements-signed ................... loaded too (b suffices) ✓
#   (d) + DYLD_FORCE_FLAT_NAMESPACE=1 ......... connect() INTERPOSED  ✓
#       (this is exactly the mechanism src/bin/torsocks.in exports on
#       darwin*; plain two-level hosts get hooked -- probe/(d) case)
#   (e) known-good: injecting the device's libproxychains4.dylib into the
#       same probe host prints "[proxychains] DLL init"      ✓
#   Family-wide limit (proxychains.md §3, re-confirmed): Apple's own
#   __RESTRICT binaries (/usr/bin/ssh ...) ignore DYLD_INSERT; repo-built
#   binaries are hookable.  ALIVE WITH CONDITIONS.
#
# WHY NO CONFIGURE (and no libtool): upstream ships configure.ac only
# (Debian orig tarball = git tag repack, no generated configure; AC_PROG_
# LIBTOOL would need libtoolize, and the CI Dockerfile installs libtool-bin
# but NOT libtool).  The configure surface is tiny and fully static for a
# fixed target, so this build hand-rolls it (sqlite "deliberately no
# configure" precedent):
#   * host_os MUST be darwin: the darwin branch of configure.ac picks
#     LIBC_NAME=libSystem.dylib, SHLIB_EXT=dylib and LDPRELOAD=
#     DYLD_INSERT_LIBRARIES -- the wrapper generated from the linux branch
#     would export LD_PRELOAD (dead on iOS) and dlopen("libc.so.6").
#     No --host triplet games needed: we generate everything directly.
#   * config.h: CONFDIR + LIBC_NAME + HAVE_INET_ATON + HAVE_GETHOSTBYNAME +
#     HAVE_STRLCPY + HAVE_STRLCAT.
#     WALL #1: the Apple SDK's string.h ALWAYS includes secure/_string.h,
#     which defines strlcpy/strlcat as fortify macros (__builtin___
#     strl{n}_chk) -- torsocks's bundled src/ext/strl{cpy,cat}.c (included
#     by compat.c when HAVE_STRL* unset) cannot compile against this SDK:
#     "type specifier missing / conflicting types for __builtin___strlcat_
#     chk".  HAVE_STRL* must be set so compat.c skips its bundled copies;
#     calls then bind to the device's libSystem strlcpy/strlcat (BSD
#     heritage, present on iOS since forever -- and the SDK macro itself
#     proves the SDK expects them).  ALLOW_ENV_CONFIG is a dead macro in
#     2.5.0 (TORSOCKS_CONF_FILE is honored whenever !is_suid,
#     torsocks.c:167).
#   * -lresolv (configure.ac darwin branch) is dropped by cc-wrapper
#     (inside libSystem) -- no action needed.
#   * -single_module: modern ld64 defaults to it; flag omitted.
#
# Interposition caveat baked into upstream design: libtorsocks never calls
# the hooked functions by name -- originals are resolved via
# dlopen(LIBC_NAME)+dlsym into tsocks_libc_* pointers, so flat-namespace
# rebinding cannot recurse into itself.
#
# Products (out/):
#   libtorsocks-<ver>-armv7   the injected dylib (gated by check-undefined)
#   torsocks-wrapper-<ver>    the wrapper script, generated from upstream
#                             src/bin/torsocks.in.  Deliberately NOT named
#                             *-armv7: CI gate audits every out/*-armv7
#                             with llvm-nm, and a shell script would fail
#                             it.  Installed by make-deb.sh.
# Layout contract (mirrors upstream configure defaults, prefix swapped):
#   /var/mobile/tools/torsocks/lib/torsocks/libtorsocks.dylib   (= @libdir@
#     + "/torsocks" suffix, see src/lib/Makefile.am and torsocks.in LIBDIR)
#   /var/mobile/tools/torsocks/etc/tor/torsocks.conf            (= CONFDIR
#     + "/tor/", see defaults.h DEFAULT_CONF_FILE)
#
# Usage: ./build.sh   # outputs ../out/* (UNSIGNED dylib)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
TORSOCKS_VERSION="${TORSOCKS_VERSION:-2.5.0}"
SRC="${TORSOCKS_SRC:-$root/tmp/src/torsocks-v$TORSOCKS_VERSION}"

# SDK sysroot mode (AGENTS.md rule 5; toolchain.md §16/§23) -- env
# self-contained per porting-flow §4 (bare build.sh must succeed).
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}"
[ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# byte-ab determinism: cc-wrapper touches .o mtimes from this when set.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"
CC="$root/tools/cc-wrapper.sh"
AR="$root/tools/darwin-ar"

# 1. net tree from the pinned tarball EVERY run (warm-tree false-greens;
#    fetch-src caches by content hash, so repeat runs cost zero network).
read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock torsocks)"
tarball="$("$root/tools/fetch-src.sh" torsocks "$U" "$SHA")"
rm -rf "$SRC"
mkdir -p "$root/tmp/src"
tar -C "$root/tmp/src" -xjf "$tarball"
[ -f "$SRC/src/lib/torsocks.c" ] || { echo "torsocks source layout unexpected" >&2; exit 1; }

cd "$SRC"

# 1b. WALL #3: upstream darwin bug (see patch-darwin.py); applied to the
#     freshly extracted tree every run, so it can never go stale.
python3 "$here/patch-darwin.py"

# 2. hand-rolled config.h (see header comment for what and why).
mkdir -p include
cat > include/config.h <<EOF
/* generated by net/torsocks/build.sh -- the subset of configure.ac output
 * that torsocks 2.5.0 actually consumes on a darwin* target */
#define CONFDIR "/var/mobile/tools/torsocks/etc"
#define LIBC_NAME "libSystem.dylib"
#define HAVE_INET_ATON 1
#define HAVE_GETHOSTBYNAME 1
#define HAVE_STRLCPY 1
#define HAVE_STRLCAT 1
#define PACKAGE "torsocks"
#define VERSION "$TORSOCKS_VERSION"
EOF

COMMON_C="compat.c config-file.c connection.c log.c onion.c socks5.c utils.c"
LIB_C="torsocks.c connect.c gethostbyname.c getaddrinfo.c close.c getpeername.c socket.c syscall.c socketpair.c recv.c exit.c accept.c listen.c fclose.c sendto.c execve.c"
# WALL #2: upstream never #includes config.h outside torsocks.h -- configure
# force-includes it on the command line (DEFAULT_INCLUDES "-include
# config.h").  Without it, compat.c's #ifndef HAVE_STRL* guards never see
# the defines and the bundled strlcpy.c still explodes against the SDK
# macros.  Mirror upstream exactly: -include config.h + -I include.
CPPFLAGS_B="-I include -I src -I src/common -I src/lib -include config.h"
CFLAGS_B="-O2 -Wall"

# 3. libcommon.a
mkdir -p "$root/tmp/torsocks-obj/common"
for c in $COMMON_C; do
    $CC $CPPFLAGS_B $CFLAGS_B -c "src/common/$c" -o "$root/tmp/torsocks-obj/common/${c%.c}.o"
done
rm -f "$root/tmp/torsocks-obj/libcommon.a"
$AR cru "$root/tmp/torsocks-obj/libcommon.a" "$root"/tmp/torsocks-obj/common/*.o

# 4. libtorsocks.dylib (the DYLD_INSERT payload).  install_name = device
#    path (upstream libdir layout: libdir/torsocks/).  Exports stay default
#    visibility -- the flat-namespace override needs them exported.
LDLIB_OBJS=""
for c in $LIB_C; do
    $CC $CPPFLAGS_B $CFLAGS_B -c "src/lib/$c" -o "$root/tmp/torsocks-obj/${c%.c}.o"
    LDLIB_OBJS="$LDLIB_OBJS $root/tmp/torsocks-obj/${c%.c}.o"
done
$CC -dynamiclib -Wl,-install_name,/var/mobile/tools/torsocks/lib/torsocks/libtorsocks.dylib \
    -o libtorsocks.dylib $LDLIB_OBJS "$root/tmp/torsocks-obj/libcommon.a"

# 5. wrapper script: substitute what AC_CONFIG_FILES(src/bin/torsocks)
#    would have.  LDPRELOAD/SHLIB_EXT come from the darwin* branch of
#    configure.ac (DYLD_INSERT_LIBRARIES / dylib).
sed -e "s|@prefix@|/var/mobile/tools/torsocks|g" \
    -e "s|@exec_prefix@|/var/mobile/tools/torsocks|g" \
    -e "s|@libdir@|/var/mobile/tools/torsocks/lib|g" \
    -e "s|@LDPRELOAD@|DYLD_INSERT_LIBRARIES|g" \
    -e "s|@SHLIB_EXT@|dylib|g" \
    -e "s|@VERSION@|$TORSOCKS_VERSION|g" \
    src/bin/torsocks.in > torsocks
chmod 755 torsocks
# sanity: no unsubstituted placeholders survive
if grep -n "@[A-Z_]*@" torsocks; then echo "unsubstituted placeholder in wrapper" >&2; exit 1; fi

# 6. gate: every undefined symbol must be on the device-verified whitelist.
"$root/tools/check-undefined.sh" libtorsocks.dylib

# 7. stage products.
mkdir -p "$root/out"
cp libtorsocks.dylib "$root/out/libtorsocks-$TORSOCKS_VERSION-armv7"
cp torsocks "$root/out/torsocks-wrapper-$TORSOCKS_VERSION"
echo "==> $root/out/libtorsocks-$TORSOCKS_VERSION-armv7 (+ torsocks-wrapper-$TORSOCKS_VERSION, script)"
file "$root/out/libtorsocks-$TORSOCKS_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh stages + on-device postinst signs;"
echo "     feasibility evidence: net/torsocks/probe/)"
