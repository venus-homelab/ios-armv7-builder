#!/bin/bash
# Build socat 1.8.0.3 for armv7 iOS 10.x.  SDK sysroot mode.
# Walls (docs/socat.md):
#   - HAVE_GETRESUID/HAVE_GETRESGID 恒真探针(Linux-only API)→ config.h 压制
#   - libtool GNU-ar 归档 ld64 无视(§2)→ 手链全部 .o
#     (排除 procan*/filan_main —— 它们是另外两个二进制的 main;filan.o
#      本体保留,socat 引用它的 filan_fd)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
CC="$root/tools/cc-wrapper.sh"
mkdir -p "$OUT"
# fetch-src 通道(2026-11-23 接入):此前整棵上游树 vendor 在 $here/src,
# 无 sha 锚定;对照过 pristine tarball 确认 vendored 树无源码改动后才切换。
SRC="$root/tmp/src/socat-1.8.0.3"
if [ ! -f "$SRC/error.h" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock socat)"
    tarball="$("$root/tools/fetch-src.sh" socat "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xjf "$tarball"
fi
[ -f "$SRC/error.h" ] || { echo "socat source layout unexpected" >&2; exit 1; }
cd "$SRC"
if [ ! -f Makefile ]; then
  # ac_cv_search_res_9_init=no: configure 的 AC_SEARCH_LIBS([res_9_init])
  # 经 -undefined dynamic_lookup 恒真(工具链.md §8 同型谎言),设备
  # libresolv 并无 res_9_*(2026-11-23 设备探针 MISS)——真链上 dyld 必死。
  # socat 的解析路径走 getaddrinfo,不需要 libresolv。
  ac_cv_search_res_9_init=no \
  CC="$CC" ./configure --host=armv7-apple-ios --prefix=/var/mobile/tools/socat \
    --disable-shared --enable-static
fi
sed -i 's|^#define HAVE_GETRESUID 1|/* #undef HAVE_GETRESUID */  /* Linux-only; probe lie */|; s|^#define HAVE_GETRESGID 1|/* #undef HAVE_GETRESGID */  /* Linux-only */|' config.h
# SDK 的 resolv.h 把 res_init 宏映射成 res_9_init(BIND-9 命名空间)——设备
# 只导出 _res_init(2026-11-23 设备探针:res_init OK / res_9_init MISS)。
# 在唯一调用点前解除宏,调用落回真名。
sed -i 's|^int Res_init(void) {|#undef res_init  /* device has _res_init, not the BIND-9 res_9_init alias */\nextern int res_init(void);  /* the sysroot decl got macro-renamed along with the call */\nint Res_init(void) {|' xio-ip.c
make -j4 >/dev/null 2>&1 || true
OBJS=$(ls *.o | grep -vE "^(procan|procan_main|procan-cdefs|filan_main)\.o$")
"$CC" -O2 -o "$OUT/socat4-armv7" $OBJS
ldid -S "$OUT/socat4-armv7" 2>/dev/null || true
echo "==> $OUT/socat4-armv7"
