#!/bin/bash
# Build uuidgen (e2fsprogs 1.47.2 misc/uuidgen.c) for armv7 iOS 10.3.3.
#
# Why: BigBoss 'uuid' 1.6.0-2p CLI is dead on this device -- dyld fails to
# resolve libgcc_s.1.dylib's re-export through libSystem.B (Abort trap 6,
# verified 2026-11-15, three runs).  The device's libSystem uuid_* API is
# fine (dlsym + probe verified same day): this CLI is a thin frontend over
# uuid_generate / uuid_generate_time / uuid_generate_random / uuid_unparse,
# all left undefined at link time (-undefined dynamic_lookup) and resolved
# from the device's libSystem at runtime.
#
# Source: e2fsprogs-1.47.2.tar.xz (kernel.org, tytso).  Only misc/uuidgen.c
# is compiled; uuid/uuid.h comes from the real iPhoneOS10.3.sdk.  This is
# the FIRST port under the SDK sysroot mode default (AGENTS.md rule 5,
# 2026-11-15).  Two build-time shims: a minimal config.h (no NLS; getopt
# declared by the SDK's unistd.h -- iOS SDK has no getopt.h) and a no-op
# support/nls-enable.h.
#
# Usage: ./build.sh          # output ../out/uuidgen-1.47.2-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
# fetch-src 通道(2026-11-23 接入):此前依赖 $HOME/scratch/e2fsprogs 的
# 手工解包树;只消费 misc/uuidgen.c(+ 它 include 的同目录头)。
E2SRC="${E2FSPROGS_SRC:-$root/tmp/src/e2fsprogs-1.47.2}"
SDK="${IOS_SDK:-$HOME/ios-tool/iPhoneOS10.3.sdk}"

if [ ! -f "$E2SRC/misc/uuidgen.c" ]; then
	read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock e2fsprogs)"
	tarball="$("$root/tools/fetch-src.sh" e2fsprogs "$U" "$SHA")"
	rm -rf "$E2SRC"
	mkdir -p "$root/tmp/src"
	tar -C "$root/tmp/src" -xJf "$tarball"
fi
[ -f "$E2SRC/misc/uuidgen.c" ] || { echo "e2fsprogs source layout unexpected" >&2; exit 1; }
# uuid/uuid.h comes from the SDK, but the CI toolchain cache may predate
# the mirror gaining that directory (2026-11-23 run) -- fall back to the
# committed copy (tools/sysroot/sdk-extra/, same pattern as libproc).
EXTRA_USR="$root/tools/sysroot/sdk-extra/usr/include"
[ -f "$SDK/usr/include/uuid/uuid.h" ] || [ -f "$EXTRA_USR/uuid/uuid.h" ] || {
	echo "missing uuid/uuid.h in both $SDK and $EXTRA_USR" >&2; exit 1; }
[ -f "$SDK/usr/include/uuid/uuid.h" ] || SDK="$EXTRA_USR/.."   # colon paths break -isysroot; the fallback dir mirrors usr/include layout

export IOS_SYSROOT="${IOS_SYSROOT:-$SDK}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}" IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

build="$here/obj"
rm -rf "$build"
mkdir -p "$build/support"

# Minimal e2fsprogs config.h: uuidgen.c needs only HAVE_STDLIB_H.  Do NOT
# define HAVE_GETOPT_H (iOS SDK ships no getopt.h; unistd.h already
# declares getopt).
cat > "$build/config.h" <<'EOF'
#define HAVE_STDLIB_H 1
EOF

# No-op NLS shim: ENABLE_NLS stays undefined, _()/N_() pass through.
cat > "$build/support/nls-enable.h" <<'EOF'
#define _(x) (x)
#define N_(x) (x)
EOF

out="$root/out"
mkdir -p "$out"
"$root/tools/cc-wrapper.sh" -O2 -Wall \
	-I"$build" \
	-o "$out/uuidgen-1.47.2-armv7" \
	"$E2SRC/misc/uuidgen.c"

echo "Built $out/uuidgen-1.47.2-armv7 (unsigned)"
