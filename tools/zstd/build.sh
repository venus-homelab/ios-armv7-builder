#!/bin/bash
# Build the zstd 1.5.7 CLI (programs/) for armv7 iOS 10.3.3 on Linux
# (SDK sysroot mode, plain-make family -- no configure).
#
# Same-source-tree contract with net/curl/build.sh: that script already
# cross-builds lib/libzstd.a from $root/tmp/src/zstd-1.5.7 (the sources.lock
# "zstd 1.5.7" row is shared, no new lock row for this package).  What is new
# here is the CLI: `make -C programs zstd` links the lib objects + the
# programs objects into one executable.  Nothing about the curl subbuild is
# disturbed -- its guard re-checks lib/libzstd.a and finds the same archive
# (same CC/AR/RANLIB recipe, darwin-ar repack included).
#
# Walls and choices, each with its evidence:
#
#   * HAVE_ZLIB / HAVE_LZMA / HAVE_LZ4 are forced to 0 explicitly.
#     The detectors compile-and-link a probe with `-lz` / `-llzma` / `-llz4`;
#     cc-wrapper links everything with -undefined dynamic_lookup, so any
#     probe that gets that far "succeeds" trivially (toolchain.md §8 -- the
#     probe that always says yes).  Explicit 0 skips the probes entirely:
#     the CLI handles .zst only, which is exactly the tar.zst workflow this
#     port exists for, and keeps the binary's only dylib dependency libSystem.
#     (Upstream defaults to the same behaviour when the libs are absent.)
#
#   * HAVE_PTHREAD cannot be overridden (:= in the Makefile): the probe is
#     always-true under dynamic_lookup, so -DZSTD_MULTITHREAD is compiled in
#     and pthread_* stays undefined at link time, resolved from the device's
#     libSystem like every other package (the -pthread flag itself is dropped
#     by cc-wrapper -- it would add no dylib on Darwin anyway).
#
#   * CFLAGS="-O3" is passed explicitly (the Makefile default via
#     libzstd.mk's `CFLAGS ?= -O3`).  Explicit beats accidental: a stale
#     shared tree built with different flags would otherwise silently mix
#     (tig WALL 3, docs/tig.md -- "按实测拍板" hygiene).  DEBUGFLAGS holds
#     only -W* warning flags -- NO -g anywhere in zstd's makefiles, so no
#     OSO stabs can absolutize host paths (the quickjs -g0 wall cannot
#     trigger here by construction).
#
#   * -Wl,-no_uuid IS passed -- by measurement, not doctrine: tig/build.sh
#     observed this ld64 NOT randomizing LC_UUID and skipped the flag, but
#     zstd's byte-ab A/B DID localize a 16-byte LC_UUID difference between
#     two identical builds (so tig's "UUID 旁证" is link-specific, not a
#     toolchain constant).  whois WALL #1 applies here; dyld does not require
#     LC_UUID in an executable (whois shipped without it and runs).
#
#   * lib/libzstd.a is (re)verified through tools/darwin-ar: the plain make
#     may still emit a GNU-format archive that ld64 rejects; the repack logic
#     is copied verbatim from net/curl/build.sh's zstd section.
#
# Source: github tag archive v1.5.7 via sources.lock (fetched through
#         tools/fetch-src.sh, like every package).
#
# Usage: ./build.sh          # output ../out/zstd-<ver>-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
ZSTD_VERSION="${ZSTD_VERSION:-1.5.7}"
SRC="${ZSTD_SRC:-$root/tmp/src/zstd-$ZSTD_VERSION}"

# ---- SDK-sysroot toolchain env (docs/toolchain.md §16/§23) -----------------
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || {
    echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

CC="$root/tools/cc-wrapper.sh"
DARWIN_AR="$root/tools/darwin-ar"
DARWIN_RANLIB="$root/tools/darwin-ranlib"
JOBS="${JOBS:-$(nproc)}"

# ---- fetch the pinned tree (shared with net/curl/build.sh's zstd section) --
if [ ! -f "$SRC/lib/zstd.h" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock zstd)"
    tarball="$("$root/tools/fetch-src.sh" zstd "$U" "$SHA")"
    rm -rf "$SRC"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/lib/zstd.h" ] || { echo "zstd source layout unexpected (no lib/zstd.h)" >&2; exit 1; }

# ---- 1. libzstd.a -- the exact curl recipe (CC/AR/RANLIB override) ---------
# -ffile-prefix-map=$root/=: lib/dictBuilder/divsufsort.c asserts with
# __FILE__ (byte-ab finding: the absolute build path lands in the archive
# member -- quickjs -g0 wall's no-debug-needed variant; curl WALL #6 fixed
# nghttp2's identical leak with exactly this flag).  It MUST ride inside the
# CFLAGS value, not MOREFLAGS: libzstd.mk appends MOREFLAGS via
# `CFLAGS += ...`, and a command-line CFLAGS silences every makefile
# assignment to CFLAGS (+= included) -- the map would silently drop out.
if [ ! -f "$SRC/lib/libzstd.a" ]; then
    ( cd "$SRC/lib" \
      && CC="$CC" AR="$DARWIN_AR" RANLIB="$DARWIN_RANLIB" \
         CFLAGS="-O3 -ffile-prefix-map=$root/=" \
         make -j"$JOBS" libzstd.a >/dev/null )
fi
[ -f "$SRC/lib/libzstd.a" ] || { echo "libzstd.a build failed" >&2; exit 1; }
# verify/re-pack: automake-free make may still emit a GNU thin archive
# (curl's repack logic verbatim -- darwin-format or bust).
if [ "$("$DARWIN_AR" t "$SRC/lib/libzstd.a" 2>/dev/null | wc -l)" -eq 0 ]; then
    "$DARWIN_AR" rcs "$SRC/lib/libzstd.a.new" "$SRC/lib"/*.o
    [ "$("$DARWIN_AR" t "$SRC/lib/libzstd.a.new" | wc -l)" -gt 0 ] \
        || { echo "libzstd.a repack produced 0 members" >&2; exit 1; }
    mv "$SRC/lib/libzstd.a.new" "$SRC/lib/libzstd.a"
fi

# ---- 2. the CLI ------------------------------------------------------------
# HAVE_ZLIB/HAVE_LZMA/HAVE_LZ4=0: skip the always-true link probes (§8).
# CFLAGS carries -O3 (upstream default) AND the file-prefix-map inline --
# same command-line rule as the lib step: libzstd.mk's `CFLAGS += $(MOREFLAGS)`
# is dead under a command-line CFLAGS, so MOREFLAGS would be a silent no-op.
# -Wl,-no_uuid: byte-ab measured a 16-byte LC_UUID difference between two
# builds (unlike tig, where this ld64 never randomized it) -- whois WALL #1
# posture, measured, not assumed.  dyld does not require LC_UUID in an
# executable (whois shipped without it).
( cd "$SRC/programs" \
  && make -j"$JOBS" zstd \
       CC="$CC" \
       CFLAGS="-O3 -ffile-prefix-map=$root/=" \
       LDFLAGS="-Wl,-no_uuid" \
       HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 >/dev/null )

BIN="$SRC/programs/zstd"
[ -f "$BIN" ] || { echo "zstd was not built" >&2; exit 1; }

# ---- 3. post-link audit (the dynamic_lookup gate -- porting-flow.md §5) ---
"$root/tools/check-undefined.sh" "$BIN"

# The CLI's only load-command dylib must be libSystem (assert the fact the
# audit whitelist implies: no libz/liblzma/liblz4 crept in via a probe).
# LC_LOAD_DYLIB records its install-name verbatim, so scanning the Mach-O for
# "*.dylib" strings enumerates every recorded dylib -- no otool needed on the
# build host (otool is device/SDK-side and absent here; tig/privoxy only ever
# used it best-effort, never as a gate).
DYLIBS="$(grep -ao 'lib[a-zA-Z0-9+._-]*\.dylib' "$BIN" | sort -u)"
echo "$DYLIBS" | grep -q "libSystem" || { echo "FAIL: no libSystem load command" >&2; exit 1; }
extra="$(echo "$DYLIBS" | grep -v "^libSystem\.B\.dylib$" || true)"
[ -z "$extra" ] || { echo "FAIL: unexpected dylibs recorded:"; echo "$extra" >&2; exit 1; }

mkdir -p "$root/out"
cp "$BIN" "$root/out/zstd-$ZSTD_VERSION-armv7"
echo "==> $root/out/zstd-$ZSTD_VERSION-armv7"
file "$root/out/zstd-$ZSTD_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copy)"
echo "    dylibs recorded:"; echo "$DYLIBS" | sed 's/^/      /'
