#!/bin/bash
# Build QuickJS (qjs interpreter) for armv7 iOS 10.x on Linux.
#
# Origin: this engine was the comparison baseline for the node.js port
# (docs/quickjs.md, phase 1: `qjs -e 'print(40+2)'` -> 42 on the device).
# Productization here means: pinned upstream source (sources.lock), a clean
# reproducible tree, the standard check-undefined gate, and a deb.
#
# The Makefile is hand-rolled (no configure).  CC/AR/RANLIB passed on the
# command line override the in-file $(CROSS_PREFIX)clang defaults, which is
# exactly how the repo's other non-configure packages build.
#
# Usage: ./quickjs/build.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
QJS_VERSION="${QJS_VERSION:-2026-06-04}"
SRC="$root/tmp/src/quickjs-$QJS_VERSION"
CC="$root/tools/cc-wrapper.sh"

export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (docs/toolchain.md §16)" >&2; exit 1; }
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export LD_LIBRARY_PATH="${LD64_LIBS:-$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib}:${LD_LIBRARY_PATH:-}"

[ -d "$SRC" ] || {
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock quickjs)"
    tarball="$("$root/tools/fetch-src.sh" quickjs "$U" "$SHA")"
    tar -C "$root/tmp/src" -xJf "$tarball"
}

cd "$SRC"
# clean any phase-1 leftovers: productization builds from the pristine tree
rm -f qjs qjsc libquickjs.a *.o

# quickjs-libc.c needs <crt_externs.h> (_NSGetEnviron).  The SDK is the public
# cut and does not carry it; the repo's sysroot-overlay does.  Do NOT add the
# whole overlay to -I (it shadows SDK headers -- sys/param.h cascade,
# docs/toolchain.md §23 note); point a dedicated include dir at the overlay
# and copy just this header.
ABIINC="$root/tmp/quickjs-abi-include"
mkdir -p "$ABIINC"
cp -f "$root/tools/sysroot/overlay/usr/include/crt_externs.h" "$ABIINC/"

# A non-empty CROSS_PREFIX switches the Makefile to its host-qjsc path: the
# qjsc compiler (which generates repl.c / precompiled bytecode) is built with
# HOST_CC for the build host, while qjs itself is cross-built with our
# wrapper.  Without it, make compiles qjsc for armv7 and then tries to RUN it
# on the Linux host ("Syntax error: word unexpected").
# The command-line DEFINES= replaces the Makefile's own line wholesale
# (command-line origin ignores the makefile's :=, which carries
# -DCONFIG_VERSION from the VERSION file) -- so the replacement must be
# COMPLETE: without -DCONFIG_VERSION, qjs.c's printf("QuickJS version "
# CONFIG_VERSION) and both .host objects stop compiling (the first two
# full-build runs died on exactly that, in two different halves).
make -j"$(nproc)" qjs \
    CROSS_PREFIX=armv7-ios10.3- HOST_CC=gcc \
    CC="$CC" AR="$root/tools/darwin-ar" RANLIB="$root/tools/darwin-ranlib" \
    DEFINES="-D_GNU_SOURCE -DCONFIG_VERSION=\\\"$QJS_VERSION\\\" -I$ABIINC -g0" \
    >/dev/null
# -g0 (2026-11-24 byte-A/B wall #4): the Makefile's CFLAGS carry -g, and ld64
# absolutizes OSO stab paths at link time -- the absolute build dir lands in
# the shipped binary no matter how the compile maps paths, so two independent
# builds differ by the path-length delta.  -g0 arrives after -g (DEFINES is
# appended last by the Makefile's CFLAGS+=$(DEFINES)) and therefore wins;
# without input debug info ld64 has no OSO stabs to absolutize.  Symbol-table
# crash symbolication is unaffected (symtab is unrelated to -g).

# post-link gate (same as every other port)
[ -x qjs ] || { echo "qjs not produced" >&2; exit 1; }
"$root/tools/check-undefined.sh" qjs

# repo convention: build.sh emits out/<artifact>-armv7 (build.yaml's gate
# steps glob out/ -- an echo alone made the gate die on an empty glob; the
# local runs never noticed because the warm tree had a stale manual copy)
mkdir -p "$root/out"
cp qjs "$root/out/qjs-$QJS_VERSION-armv7"
echo "==> $root/out/qjs-$QJS_VERSION-armv7"
