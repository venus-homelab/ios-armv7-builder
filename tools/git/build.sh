#!/bin/bash
# Build git 2.51.2 for armv7 iOS 10.x on Linux.
#
# Same toolchain family as ../curl and ../wget (see docs/toolchain.md), but
# git does not use autoconf here: its Makefile is driven by a hand-written
# config.mak (below), because configure's probes lie even harder than usual
# on this target and several "uname_S = Linux" defaults leak in when building
# on a Linux host -- the target is iOS, not the build machine.
#
# Static throughout: libz (cross-built in zlib-src), libcurl.a, libssl.a and
# libcrypto.a.  Nothing in /usr is touched; everything installs under
# /var/mobile/tools.
#
# Usage:
#   ./git/build.sh            # self-contained: fetches git/zlib, auto-builds
#                             # openssl + curl (matrix precedent), stages to
#                             # ../tmp/git-staging
#   ./git/make-deb.sh         # packages ../tmp/git-staging into ../out/git_*.deb
# Environment (all optional, same defaults as the other SDK-mode builds;
# CI overrides via .github/workflows/build.yaml job env):
#   IOS_SYSROOT  (default $HOME/ios-tool/iPhoneOS10.3.sdk)
#   IOS_LD64     (default $HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld)
#   IOS_STUBDIR  (default $HOME/ios-tool)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
GIT_VERSION="${GIT_VERSION:-2.51.2}"
SRC="${GIT_SRC:-$root/tmp/src/git-$GIT_VERSION}"
ZLIB="${ZLIB:-$root/tmp/src/zlib-1.3.1}"
OSSL="${OSSL:-$root/tmp/src/openssl-4.0.3}"
CURL="${CURL:-$root/tmp/src/curl-8.16.0}"
STAGING="${STAGING:-$root/tmp/git-staging}"
PREFIX="/var/mobile/tools"
CC="$root/tools/cc-wrapper.sh"

# SDK sysroot (toolchain.md §16/§23) -- the musl tmp/sysroot era is over.
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ---------------------------------------------------------------- zlib ----
# git cannot be built without it (there is no --without-zlib).  The rest of
# this repository avoids zlib, so this is the first static libz in the tree.
# Pure C, no syscalls, cross-builds in seconds.
if [ ! -f "$ZLIB/libz.a" ]; then
    [ -d "$ZLIB" ] || {
        mkdir -p "$root/tmp/src"
        # sources.lock: zlib 1.3.1 -- github tag archive, because zlib.net
        # stopped serving 1.3.1 (404 there since the 1.4 release).
        zlib_tar="$("$root/tools/fetch-src.sh" zlib \
            "https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz" \
            "$(awk -F'\t' '$1=="zlib"{print $4}' "$root/sources.lock")")"
        tar -C "$root/tmp/src" -xzf "$zlib_tar"
    }
    ( cd "$ZLIB" \
      && CC="$CC" AR="$root/tools/darwin-ar" RANLIB="$root/tools/darwin-ranlib" \
         CHOST=armv7-apple-darwin ./configure --static >/dev/null \
      && make -j"$(nproc)" libz.a >/dev/null )
    # GNU thin archives are silently ignored by ld64 (docs/toolchain.md §2)
    "$root/tools/darwin-ar" rcs "$ZLIB/libz.a.new" "$ZLIB"/*.o
    # verify the conversion produced real members before replacing anything
    [ "$("$root/tools/darwin-ar" t "$ZLIB/libz.a.new" | wc -l)" -gt 0 ] || { echo "libz.a conversion produced 0 members" >&2; exit 1; }
    mv "$ZLIB/libz.a.new" "$ZLIB/libz.a"
fi
# git's Makefile spells zlib as -L$(ZLIB_PATH)/lib -lz, and -lz is no longer
# on the cc-wrapper discard list (it forwards like any -l now), so the static
# archive must be findable in a lib/ subdir.  Mirror it there.
mkdir -p "$ZLIB/lib" && cp -f "$ZLIB/libz.a" "$ZLIB/lib/libz.a"

# ----------------------------------------------------------------- git ----
if [ ! -d "$SRC" ]; then
    mkdir -p "$root/tmp/src"
    # sources.lock: git 2.51.2
    git_tar="$("$root/tools/fetch-src.sh" git \
        "https://github.com/git/git/archive/refs/tags/v$GIT_VERSION.tar.gz" \
        "$(awk -F'\t' '$1=="git"{print $4}' "$root/sources.lock")")"
    tar -C "$root/tmp/src" -xzf "$git_tar"
fi

# Self-contained dependencies (the matrix builds packages on independent
# runners in no particular order -- openssh/openssl set the precedent)
[ -f "$CURL/lib/.libs/libcurl.a" ] || {
    echo "==> building curl first (git's static HTTP dependency)"
    (cd "$root/net/curl" && ./build.sh)
}
[ -f "$CURL/lib/.libs/libcurl.a" ] || { echo "curl build did not produce $CURL/lib/.libs/libcurl.a" >&2; exit 1; }
[ -f "$OSSL/libssl.a" ] || {
    echo "==> building OpenSSL first (git's static TLS dependency)"
    (cd "$root/net/openssl" && ./build.sh)
}
[ -f "$OSSL/libssl.a" ] || { echo "OpenSSL build did not produce $OSSL/libssl.a" >&2; exit 1; }

# curl 8.16.0-6 static libcurl.a drags its own dependency closure (HTTP/2,
# brotli decoder, zstd) plus the ___atomic_is_lock_free shim that OpenSSL 4's
# archives need and iOS 10 libSystem lacks.  curl/build.sh keeps them in
# deterministic ABI dirs under tmp/ -- require them here.
NG2ABI="$root/tmp/curl-nghttp2-abi"; BRABI="$root/tmp/curl-brotli-abi"; ZABI="$root/tmp/curl-zstd-abi"
C8OBJ="$root/tmp/curl-c8fixed.o"
for f in "$NG2ABI/lib/libnghttp2.a" "$BRABI/lib/libbrotlidec.a" \
         "$BRABI/lib/libbrotlicommon.a" "$ZABI/lib/libzstd.a" "$C8OBJ"; do
    [ -f "$f" ] || { echo "missing $f -- curl/build.sh produces the curl-*-abi dirs" >&2; exit 1; }
done

cd "$SRC"

# imap-send pokes opaque OpenSSL 4 ASN1 structs (does not compile) and is
# useless on the device.  git 2.51.2 adds imap-send.o to PROGRAM_OBJS
# UNCONDITIONALLY (the old `ifndef NO_IMAP_SEND` guard at this line is gone
# upstream), so NO_IMAP_SEND no longer keeps it out of `all` -- and
# `install: all` would try to build git-imap-send.  Drop it from the extracted
# Makefile instead.  (An earlier green run here was a stale .o from the musl
# era masking exactly this.)
sed -i 's|^PROGRAM_OBJS += imap-send.o$|# imap-send dropped: opaque OpenSSL 4 ASN1 structs|' Makefile
grep -q '^# imap-send dropped' Makefile || { echo "imap-send sed did not match -- git Makefile changed?" >&2; exit 1; }

# Hand-written cross config.  Notes on every non-obvious line:
cat > config.mak <<MAK
# hand-written cross config for armv7-apple-ios10.3
SHELL_PATH = /bin/sh
CC = $CC
AR = $root/tools/darwin-ar
RANLIB = $root/tools/darwin-ranlib
prefix = $PREFIX
gitexecdir = libexec/git-core
template_dir = share/git-core/templates
sysconfdir = $PREFIX/etc
# nothing here can run scripts: no perl, no python, no tcl on the device
NO_GETTEXT = YesPlease
NO_TCLTK = YesPlease
NO_PERL = YesPlease
NO_PYTHON = YesPlease
NO_EXPAT = YesPlease
NO_ICONV = YesPlease
# git's bundled regex is fine; the sysroot has no usable one to probe
NO_REGEX = YesPlease
# link against our OpenSSL 4, not Apple CommonCrypto
NO_APPLE_COMMON_CRYPTO = YesPlease
OPENSSLDIR = $OSSL
NEEDS_CRYPTO_WITH_SSL = YesPlease
ZLIB_PATH = $ZLIB
CURLDIR = $CURL
CURL_LDFLAGS = -L$CURL/lib/.libs -lcurl
NO_INSTALL_HARDLINKS = YesPlease
HAVE_ALLOCA_H = YesPlease
# Darwin's struct stat spells the mtime timespec st_mtimespec (musl spells it
# st_mtim, which the Linux default branch below would chase -- and the SDK has
# no st_mtim at all)
USE_ST_TIMESPEC = YesPlease
# git's progress meter uses setitimer; it exists on iOS but probes mislead,
# and the feature is cosmetic -- keep it off
NO_SETITIMER = YesPlease

# ---- overrides for building from a Linux host ----
# config.mak.uname's ifeq(\$(uname_S),Linux) branch assumes the TARGET is
# Linux; it is iOS.  Everything below would otherwise be baked in and either
# fail to compile (sync_file_range, /proc) or abort at first use on the
# device (getrandom).  config.mak is included after config.mak.uname, so
# these ordinary assignments win.
# iOS has no sync_file_range syscall.
HAVE_SYNC_FILE_RANGE =
# iOS has no procfs at all (/proc does not exist).
HAVE_SYSINFO =
HAVE_PLATFORM_PROCINFO =
PROCFS_EXECUTABLE_PATH =
COMPAT_OBJS := \$(filter-out compat/linux/procinfo.o,\$(COMPAT_OBJS))
# iOS libSystem has strlcpy (BSD); do not compile git's compat copy.
NO_STRLCPY =
# iOS libSystem provides arc4random_buf natively; getrandom does not exist
# on iOS 10 and would abort in dyld on first use (symbol not found).
CSPRNG_METHOD = arc4random
# ld64 does not accept -Wl,-rpath,; all libs are static anyway.
CC_LD_DYNPATH = -L
# The cc-wrapper drops -lz from the link line (it assumes libSystem
# re-exports zlib, which is true on macOS but NOT on iOS 10 -- on the
# device deflateInit_ would abort in dyld on first use).  Put the
# converted static archive on the link line explicitly instead.
EXTLIBS += $ZLIB/libz.a
# git's default SHA1 backend is SHA1DC, so the Makefile never adds
# -lssl/-lcrypto (EXTLIBS carries crypto only when OPENSSL_SHA1 is
# selected) -- but curl's TLS needs them.  Append the static archives to
# EXTLIBS (used late, in the link recipes; CURL_LIBCURL is NOT usable --
# its plain assignments at Makefile:1663/1666 run after config.mak and
# would silently overwrite anything appended here).
EXTLIBS += $OSSL/libssl.a $OSSL/libcrypto.a
# libcurl.a's own closure: consumer-before-provider (ld64 pulls archive
# members in one left-to-right pass; brotli's decoder needs its common
# tables, so dec precedes common).  The c8fixed object is force-included and
# tiny -- harmless on the plain git link too.  NOTE: this heredoc is
# unquoted, so no backticks or unexpanded dollar-parens may appear here.
EXTLIBS += $NG2ABI/lib/libnghttp2.a
EXTLIBS += $BRABI/lib/libbrotlidec.a $BRABI/lib/libbrotlicommon.a
EXTLIBS += $ZABI/lib/libzstd.a
EXTLIBS += $C8OBJ
MAK

# git's Makefile tracks ALL_LDFLAGS for its "new link flags" relink decision
# but NOT EXTLIBS -- a config.mak that only changed the archive closure is
# invisible to it (a reused tree then relinks nothing and ships the stale
# binary).  Remove the two link targets so the recipes always rerun.
rm -f "$SRC/git" "$SRC/git-remote-http"
make -j"$(nproc)" git git-remote-http >/dev/null

# ----------------------------------------------------------- install ------
# Plain `make install` drags in three things we do not ship (each found the
# hard way):
#   * imap-send: pokes opaque OpenSSL 4 ASN1 structs, does not compile, and
#     is useless on the device.  NO_IMAP_SEND in config.mak does NOT work --
#     the `ifndef NO_IMAP_SEND` at Makefile:773 is evaluated *before*
#     config.mak is included, so it must be given on the command line.
#   * oss-fuzz targets: LINK_FUZZ_PROGRAMS = YesPlease leaks from the Linux
#     branch of config.mak.uname and the fuzz link line uses GNU-ld-only
#     options (--allow-multiple-definition) that ld64 rejects.
#   * test programs: Makefile:3262 appends $(TEST_PROGRAMS), $(UNIT_TEST_PROGS)
#     and $(CLAR_TEST_PROG) to `all::` UNCONDITIONALLY.  Blank them on the
#     command line; command-line variables override everything.
rm -rf "$STAGING" && mkdir -p "$STAGING"
make install DESTDIR="$STAGING" \
    NO_IMAP_SEND=YesPlease LINK_FUZZ_PROGRAMS= \
    TEST_PROGRAMS= UNIT_TEST_PROGS= CLAR_TEST_PROG= test_bindir_programs= \
    -j"$(nproc)" >/dev/null

# git-cvsserver is a perl script; NO_PERL keeps most perl bits out but this
# one still lands in bin/ (its shebang is the tell).
rm -f "$STAGING$PREFIX/bin/git-cvsserver"
# sample hooks: watchman's needs perl, and .sample hooks are inert anyway
rm -f "$STAGING$PREFIX/share/git-core/templates/hooks/"*.sample

echo "==> staged in $STAGING (install prefix $PREFIX)"

# build.yaml's gate wants the repo convention out/<artifact>-armv7; the
# staging tree alone made the gate either die (no artifact) or silently gate
# whatever else was in out/ (it picked curl's artifact on the first run).
mkdir -p "$root/out"
cp "$STAGING$PREFIX/bin/git" "$root/out/git-$GIT_VERSION-armv7"
echo "==> $root/out/git-$GIT_VERSION-armv7"
echo "    next: ./git/make-deb.sh"
