#!/bin/bash
# Build the lz4 1.11.1 CLI (programs/) for armv7 iOS 10.3.3 on Linux
# (SDK sysroot mode, plain-make family -- no configure).
#
# Version pinning story: the task named the "v1.10.0 line, release page as
# the authority" -- and the release page's latest STABLE release is v1.11.1
# (2026-11-10, "Point fix", not a prerelease), so that is what sources.lock
# pins (official release asset, sha256 computed from the downloaded bytes AND
# cross-checked against the upstream lz4-1.11.1.tar.gz.sha256 sidecar:
# 683fed08...).  "Latest stable" per the release page beats a memory of an
# older line -- same rule that moved whois from a remembered tag to a pinned
# commit.
#
# Walls and choices, each with its evidence:
#
#   * Target `lz4-release` (upstream's default posture): DEBUGFLAGS emptied
#     by the target, NDEBUG added, -O3 from USERCFLAGS.  lz4's makefiles
#     carry NO -g anywhere (only -W* warning flags in DEBUGFLAGS), so no OSO
#     stabs can absolutize host paths -- the quickjs -g0 wall cannot trigger
#     here by construction.  CFLAGS="-O3" passed explicitly anyway (tig WALL
#     3 hygiene: cached trees must match the recipe's flags).
#
#   * The pthread probe (build/make/lz4defs.make PTHREAD_PROBE) is
#     always-true under cc-wrapper's -undefined dynamic_lookup link
#     (toolchain.md §8 -- the probe that always says yes).  That is actually
#     the DESIRED result here: -DLZ4IO_MULTITHREAD -DLZ4F_MULTITHREAD=1 go
#     in, pthread_* stays undefined at link time and resolves from the
#     device's libSystem like every other package (the -pthread link flag is
#     dropped by cc-wrapper; it would add no dylib on Darwin anyway).
#
#   * No AR/darwin-ar needed: the lz4 CLI does not link liblz4.a -- the
#     c_program rule compiles lib/*.c + programs/*.c straight into the
#     executable (single archive-free link, no GNU-ar hazard at all).
#
#   * -Wl,-no_uuid NOT passed: tig/build.sh measured this ld64 does not
#     randomize LC_UUID (docs/tig.md "UUID 旁证"); byte-ab.sh is the
#     arbiter -- a DIFFER localizing to UUID bytes earns the flag its own
#     wall entry (same measured posture as tig/zstd).
#
#   * man page: the release tarball SHIPS programs/lz4.1 pre-generated (the
#     in-tree Makefile would need `ronn` to regenerate it from lz4.1.md, and
#     the build host has no ronn) -- shipping the tarball's file keeps the
#     build tool-free.
#
# Source: official release asset via sources.lock (fetched through
#         tools/fetch-src.sh, like every package).
#
# Usage: ./build.sh          # output ../out/lz4-<ver>-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
LZ4_VERSION="${LZ4_VERSION:-1.11.1}"
SRC="${LZ4_SRC:-$root/tmp/src/lz4-$LZ4_VERSION}"

# ---- SDK-sysroot toolchain env (docs/toolchain.md §16/§23) -----------------
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || {
    echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

CC="$root/tools/cc-wrapper.sh"
JOBS="${JOBS:-$(nproc)}"

# ---- fetch the pinned release tarball --------------------------------------
if [ ! -f "$SRC/programs/lz4cli.c" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock lz4)"
    tarball="$("$root/tools/fetch-src.sh" lz4 "$U" "$SHA")"
    rm -rf "$SRC"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/programs/lz4cli.c" ] || { echo "lz4 source layout unexpected (no programs/lz4cli.c)" >&2; exit 1; }

# ---- 1. the CLI -------------------------------------------------------------
# lz4-release: upstream default posture (DEBUGFLAGS=, NDEBUG, -O3).  The
# pthread probe runs and "succeeds" under dynamic_lookup (see header): that
# compiles the multithreaded IO path in, exactly like a normal Linux build.
( cd "$SRC/programs" \
  && make -j"$JOBS" lz4-release CC="$CC" CFLAGS="-O3" >/dev/null )

BIN="$SRC/programs/lz4"
[ -f "$BIN" ] || { echo "lz4 was not built" >&2; exit 1; }

# ---- 2. post-link audit (the dynamic_lookup gate -- porting-flow.md §5) ---
"$root/tools/check-undefined.sh" "$BIN"

# Only libSystem may be recorded (LC_LOAD_DYLIB names are verbatim strings
# inside the Mach-O -- no otool needed on the build host; otool is absent
# here and tig/privoxy only ever used it best-effort, never as a gate).
DYLIBS="$(grep -ao 'lib[a-zA-Z0-9+._-]*\.dylib' "$BIN" | sort -u)"
echo "$DYLIBS" | grep -q "libSystem" || { echo "FAIL: no libSystem load command" >&2; exit 1; }
extra="$(echo "$DYLIBS" | grep -v "^libSystem\.B\.dylib$" || true)"
[ -z "$extra" ] || { echo "FAIL: unexpected dylibs recorded:"; echo "$extra" >&2; exit 1; }

# ---- 3. deliver (host cannot exec armv7 -- the banner check runs on-device,
# see docs/lz4.md device acceptance steps) -----------------------------------
mkdir -p "$root/out"
cp "$BIN" "$root/out/lz4-$LZ4_VERSION-armv7"
echo "==> $root/out/lz4-$LZ4_VERSION-armv7"
file "$root/out/lz4-$LZ4_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copy)"
echo "    dylibs recorded:"; echo "$DYLIBS" | sed 's/^/      /'
