#!/bin/bash
# Build jq 1.7.1 (with oniguruma 6.9.10) for armv7 iOS 10.x on Linux.
#
# jq 1.7 dropped the bundled oniguruma, so libonig is cross-built first.
# Both are pure C; the walls here are all toolchain-shape:
#
#   * oniguruma's libtool-generated libonig.la records its install
#     directory.  Installing it with DESTDIR to harvest the .a leaves the
#     .la claiming /var/mobile/tools, and libtool's "moved library"
#     relink logic chokes on that (eval syntax error).  Fix: copy the bare
#     libonig.a + headers into a clean directory and point
#     --with-oniguruma at it -- no .la in sight.
#   * libtool's --mode=link wants to build a shared libjq.dylib
#     (-Wl,-soname ...).  That path is useless on this device and the
#     toolchain has no use for it; --disable-shared --enable-static keeps
#     libtool in plain .a land and jq links statically against libonig.
#   * jq's builtin.c unconditionally redirects exp10 to Apple's __exp10
#     (`#define exp10 __exp10`), which is fine on real Darwin but musl's
#     math.h has no declaration for it.  Probe-verified live on the device
#     that __exp10 exists (__exp10(2.0) == 100.0), so the declaration was
#     added to tools/sysroot/overlay/usr/include/math.h.
#
# Usage:
#   export IOS_SYSROOT=$HOME/ios-armv7-builder/tmp/sysroot \
#          IOS_STUBDIR=$HOME/ios-tool \
#          IOS_LD64=$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld \
#          LD_LIBRARY_PATH=$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib
#   ./jq/build.sh          # -> ../out/jq-1.7.1-armv7
#   ./jq/make-deb.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
JQ_VERSION="${JQ_VERSION:-1.7.1}"
ONIG_VERSION="${ONIG_VERSION:-6.9.10}"
CC="$root/tools/cc-wrapper.sh"

# SDK sysroot (toolchain.md §16/§23); CI overrides via build.yaml job env
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="${LD64_LIBS:-$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

JQROOT="${JQROOT:-$root/tmp/src/jq}"

# ------------------------------------------------------------- source ----
[ -d "$JQROOT/onig-$ONIG_VERSION" ] || {
    mkdir -p "$JQROOT"
    # sources.lock: oniguruma 6.9.10
    onig_tar="$("$root/tools/fetch-src.sh" oniguruma \
        "https://github.com/kkos/oniguruma/releases/download/v$ONIG_VERSION/onig-$ONIG_VERSION.tar.gz" \
        "$(awk -F'\t' '$1=="oniguruma"{print $4}' "$root/sources.lock")")"
    tar -C "$JQROOT" -xzf "$onig_tar"
}
[ -d "$JQROOT/jq-$JQ_VERSION" ] || {
    # sources.lock: jq 1.7.1
    jq_tar="$("$root/tools/fetch-src.sh" jq \
        "https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/jq-$JQ_VERSION.tar.gz" \
        "$(awk -F'\t' '$1=="jq"{print $4}' "$root/sources.lock")")"
    tar -C "$JQROOT" -xzf "$jq_tar"
}

# -------------------------------------------------------- oniguruma ----
if [ ! -f "$JQROOT/onig-clean/lib/libonig.a" ]; then
    cd "$JQROOT/onig-$ONIG_VERSION"
    [ -f ios-config.site ] || cp "$root/net/wget/ios-config.site" ios-config.site
    CC="$CC" AR="$root/tools/darwin-ar" RANLIB="$root/tools/darwin-ranlib" \
        CONFIG_SITE="$PWD/ios-config.site" \
        ./configure --host=armv7-apple-darwin --prefix=/var/mobile/tools \
            --enable-static --disable-shared >/dev/null
    make -j"$(nproc)" >/dev/null
    # verify the archive is a real darwin one before harvesting it
    n=$("$root/tools/darwin-ar" t src/.libs/libonig.a | wc -l)
    [ "$n" -gt 0 ] || { echo "libonig.a has 0 members" >&2; exit 1; }
    mkdir -p "$JQROOT/onig-clean/lib" "$JQROOT/onig-clean/include"
    cp src/.libs/libonig.a "$JQROOT/onig-clean/lib/"
    cp src/onig*.h "$JQROOT/onig-clean/include/"
    echo "==> oniguruma: $n members into onig-clean/"
fi

# ----------------------------------------------------------------- jq ----
cd "$JQROOT/jq-$JQ_VERSION"
[ -f ios-config.site ] || cp "$root/net/wget/ios-config.site" ios-config.site

make distclean >/dev/null 2>&1 || true
CC="$CC" AR="$root/tools/darwin-ar" RANLIB="$root/tools/darwin-ranlib" \
    CONFIG_SITE="$PWD/ios-config.site" \
    ./configure --host=armv7-apple-darwin --prefix=/var/mobile/tools \
        --with-oniguruma="$JQROOT/onig-clean" \
        --disable-shared --enable-static >/dev/null

# SDK mode: configure's HAVE_POW10 probe lied (dynamic_lookup -- toolchain.md
# §8); musl has pow10, Darwin headers do not.  jq 1.7.1 has NO config.h --
# every probe answer rides the compile line as -D flags in Makefile's DEFS
# (the old config.h sed only ever worked against a stale musl-era file in a
# warm tree).  Drop the bogus define from DEFS so libm.h's own fallback
# (LIBM_DD_NO) engages.
sed -i 's/ -DHAVE_POW10=1//' Makefile
grep -q 'HAVE_POW10' Makefile && { echo "HAVE_POW10 still in Makefile DEFS" >&2; exit 1; }

make -j"$(nproc)" >/dev/null

ldid -S jq
mkdir -p "$root/out"
cp jq "$root/out/jq-$JQ_VERSION-armv7"
echo "==> $root/out/jq-$JQ_VERSION-armv7"
echo "    next: ./jq/make-deb.sh"
