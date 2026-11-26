#!/bin/bash
# Build entr 5.9 (eradman/entr, the Event NOTIFY Test Runner) for armv7
# iOS 10.x on Linux (SDK sysroot mode).
#
# entr is a small, pure-C, single-binary package: entr.c + status.c +
# (empty on Darwin) compat.c, its own toy "configure" (plain sh that only
# copies Makefile.<os> -> Makefile), zero library dependencies beyond
# libSystem.  The whole port rests on ONE question -- does this device's
# kernel deliver EVFILT_VNODE events with correct 32-bit ABI -- and that
# question is answered by a probe BEFORE this script, not by hope:
#
#   * KQUEUE PROBE (tools/entr/probe-kqueue.c -> out/entr-probe-armv7):
#     registers EVFILT_VNODE (EV_ADD|EV_CLEAR, entr's exact NOTE_ALL mask)
#     on TWO regular files in one 2-element changelist (the multi-element
#     stride rule -- docs/musl-sysroot.md #14: a single-element changelist
#     cannot catch a wrong struct stride, and this is the exact bug class
#     that broke kevent in the musl era), triggers real write/rename/unlink
#     and asserts NOTE_WRITE/RENAME/DELETE delivery with udata round-trip,
#     plus EVFILT_READ+NOTE_LOWAT on a pipe (entr's stdin trigger), the
#     kevent64() 64-bit ABI, and the timespec timeout path.  Built and
#     gated (check-undefined) before the formal build; run it on the device
#     as step 1 of docs/entr.md acceptance.  Static evidence already on
#     record: _kqueue/_kevent/_kevent64/_sysctl/_getrlimit/_setrlimit are
#     in the device dlsym-verified export list (tools/sysroot/device-exports/
#     ios-10.3.3-armv7-verified.txt) and nginx/nmap already ran the kqueue
#     engine on this device (docs/nginx.md §2, docs/nmap.md wall #7).
#   * TARGET_OS=Darwin: the host uname is Linux, and configure would copy
#     Makefile.linux (inotify shim, _LINUX_PORT -- wrong syscall world
#     entirely).  TARGET_OS=Darwin selects Makefile.macos (_MACOS_PORT):
#     fd-limit raise via getrlimit + sysctl(KERN_MAXFILESPERPROC), no
#     missing/ sources compiled in (EXTRA_SRC empty -> compat.c empty).
#   * NOTE_TRUNCATE does not exist in Darwin's event.h (FreeBSD
#     extension); upstream missing/compat.h defines it to 0, so entr's
#     NOTE_ALL mask simply lacks that bit on Darwin.  Zero patch needed --
#     the probe mirrors the same mask.
#   * pledge(2) is OpenBSD-only; missing/compat.h maps it to a no-op
#     literal 0 outside __OpenBSD__.  Zero patch needed.
#   * -x status filter shells out to /usr/bin/awk on the device at RUNTIME
#     (optional feature; not a link-time or packaging dependency).
#
# Determinism (byte-ab walls, docs/byte-ab-report.md): -O2 with no -g (no
# OSO stabs for ld64 to absolutize, wall #4) and -Wl,-no_uuid (ld64
# generates a random LC_UUID per link otherwise, wall #1).  The source
# tree is re-extracted from the pinned tarball on every run (wall #3 --
# no stale object reuse).  No __FILE__/__DATE__ use in entr.c/status.c.
#
# Source: GitHub tag archive via sources.lock (the official
#         entrproject.org/code/entr-5.9.tar.gz currently serves an HTML
#         page -- domain parked/hijacked, 2026-11-25 -- see sources.lock).
#
# Usage: ./build.sh          # output ../out/entr-<ver>-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
ENTR_VERSION="${ENTR_VERSION:-5.9}"
SRC="${ENTR_SRC:-$root/tmp/src/entr-$ENTR_VERSION}"

# SDK sysroot (toolchain.md §16/§23)
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 0. the kqueue probe is part of this package's contract: build + gate it
#    so the acceptance run on the device (docs/entr.md §验收) always has a
#    matching artifact.  It must never be skipped silently.
PROBE="$here/probe-kqueue.c"
[ -f "$PROBE" ] || { echo "missing $PROBE" >&2; exit 1; }
PROBE_OUT="$root/out/entr-probe-armv7"
"$root/tools/cc-wrapper.sh" -O2 -Wall -Wl,-no_uuid "$PROBE" -o "$PROBE_OUT"
"$root/tools/check-undefined.sh" "$PROBE_OUT"

# 1. fetch the pinned tag archive and re-extract a pristine tree every run
read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock entr)"
tarball="$("$root/tools/fetch-src.sh" entr "$U" "$SHA")"
rm -rf "$SRC"
mkdir -p "$root/tmp/src"
tar -C "$root/tmp/src" -xzf "$tarball"
[ -f "$SRC/entr.c" ] || { echo "entr source layout unexpected (no entr.c)" >&2; exit 1; }

cd "$SRC"

# 2. configure: a toy sh script that only copies Makefile.<os> -> Makefile.
#    TARGET_OS=Darwin is the honest statement of the target (host uname is
#    Linux); it selects Makefile.macos -> -D_MACOS_PORT.
TARGET_OS=Darwin ./configure

# 3. build all three objects + link.  CFLAGS=-O2 (no -g), LDFLAGS carries
#    -Wl,-no_uuid (byte-ab walls #1/#4).  cc-wrapper compiles each .c with
#    -c and links the three objects with -e _main; pledge() collapses to 0
#    via missing/compat.h, NOTE_TRUNCATE to 0 likewise.
make entr CC="$root/tools/cc-wrapper.sh" \
    CFLAGS="-O2" \
    LDFLAGS="-Wl,-no_uuid"

BIN="$SRC/entr"
[ -f "$BIN" ] || { echo "entr was not built" >&2; exit 1; }

# 4. assertions: entr must depend on libSystem ONLY.  No curses, no iconv,
#    no openssl, nothing else.  Every undefined symbol must sit in the
#    device dlsym-verified list / tbd stubs (check-undefined enforces).
if "$root/tools/llvm-nm" -u "$BIN" | grep -qE '_(iconv|ncurses|ssl|crypto|pcre|event)'; then
    echo "FAIL: unexpected library dependency:" >&2
    "$root/tools/llvm-nm" -u "$BIN" | grep -E '_(iconv|ncurses|ssl|crypto|pcre|event)' >&2
    exit 1
fi
otool -L "$BIN" 2>/dev/null || true

# 5. post-link audit (the dynamic_lookup gate -- porting-flow.md §5)
"$root/tools/check-undefined.sh" "$BIN"

mkdir -p "$root/out"
cp "$BIN" "$root/out/entr-$ENTR_VERSION-armv7"
echo "==> $root/out/entr-$ENTR_VERSION-armv7"
file "$root/out/entr-$ENTR_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copy;"
echo "     probe binary: $PROBE_OUT -- run it on the device BEFORE the deb"
echo "     is trusted; see docs/entr.md §设备验收)"
