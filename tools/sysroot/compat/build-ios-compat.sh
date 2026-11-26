#!/bin/bash
# build-ios-compat.sh -- (re)build tools/sysroot/overlay/usr/lib/libios-compat.a
#
# The compat stubs (see ios-compat.c) must be a DARWIN flat archive: ld64
# silently ignores GNU-format archives (toolchain.md §2), and this archive
# is appended to links by tools/cc-wrapper.sh.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"   # tools/sysroot/compat -> repo root (2026-11-25: compat moved under tools/sysroot/, old ../.. landed in tools/)
OUT="$root/tools/sysroot/overlay/usr/lib/libios-compat.a"

export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}" \
       IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}" \
       IOS_LD64="${IOS_LD64:?set IOS_LD64}" \
       LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# curses.h: the iOS SDK ships none; the device ncurses build (tmux/less era,
# $HOME/ios-tool/build-ios) carries the real headers -- the terminfo stubs
# only need the prototypes and ERR.  2026-11-25: the old musl-usr sysroot
# this script pinned is a pruned relic (AGENTS 规则 5: SDK 模式), and its
# layout no longer resolves <sys/socket.h> at all.
CURSES_INC="$HOME/ios-tool/build-ios/ncurses-6.5/include"
[ -f "$CURSES_INC/curses.h" ] || { echo "missing $CURSES_INC/curses.h (device ncurses build)" >&2; exit 1; }

w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
mkdir -p "$(dirname "$OUT")"
"$root/tools/cc-wrapper.sh" -O1 -I"$CURSES_INC" -c "$here/ios-compat.c" -o "$w/ios-compat.o"
"$root/tools/cc-wrapper.sh" -O1 -fno-builtin -c "$here/atomic-compat.c" -o "$w/atomic-compat.o"
"$root/tools/darwin-ar" rcs "$OUT" "$w/ios-compat.o" "$w/atomic-compat.o"
# verify the archive is usable by ld64 (Darwin flat, non-empty)
n=$(llvm-ar-21 t "$OUT" | wc -l)
[ "$n" -gt 0 ] || { echo "resulting archive has 0 members" >&2; exit 1; }
echo "==> $OUT ($n members)"
