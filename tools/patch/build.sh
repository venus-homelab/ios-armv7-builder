#!/bin/bash
# Build GNU patch 2.7.1 for armv7 iOS 10.x.  SDK sysroot mode.
#
# 墙实录(docs/patch.md §2):configure 恒真探针 5 件
#   HAVE_FUTIMENS/HAVE_FUTIMESAT/HAVE_UTIMENSAT/HAVE_NANOTIME/
#   HAVE_CANONICALIZE_FILE_NAME(iOS 10 无这些 API;gnulib 模板占位
#   #undef 会被 config.status 按(假)探针结果写回 #define —— 必须
#   **删除模板占位行** + 改 config.h + touch 压 mtime,缺一不可)
# gnulib 模块剔除:msvc-inval/msvc-nothrow(Windows 专属,恒真探针误纳,
#   从 lib/Makefile 的 gl_LIBOBJS/gl_LTLIBOBJS 删)
# 链接:libtool 归档 ld64 无视(§2)→ 手链 src/*.o + src-compat.o +
#   lib/*.o(排除 xalloc-die.o:patch 自带实现,gnulib 版重复)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
CC="$root/tools/cc-wrapper.sh"
mkdir -p "$OUT" "$here/include"

# fetch-src 通道(2026-11-23 接入):此前整棵上游树 vendor 在 $here/src
# (其中的 configure/config.hin/parse-datetime.c 是 autoconf 2.72 重生成
# 产物,非源码改动;pristine 树用自带 2.68 configure,探针压制块照常生效)
SRC="$root/tmp/src/patch-2.7.1"
if [ ! -f "$SRC/src/patch.c" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock patch)"
    tarball="$("$root/tools/fetch-src.sh" patch "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tarball"
fi
[ -f "$SRC/src/patch.c" ] || { echo "patch source layout unexpected" >&2; exit 1; }

# patch 2.7.1 自带的 autoconf 2.68 config.sub 不认识 armv7-apple-ios
# ("system `ios' not recognized") -- 当年 vendor 树里的 configure 是
# autoconf 2.72 重生成的,根因就是它。换成 sha 锚定的新版脚本对,避免
# 在 CI 上装 autotools 重生成整棵 configure。
read -r U2 S2 _ <<<"$("$root/tools/fetch-src.sh" --lock gnu-config.sub)"
install -m 0755 "$("$root/tools/fetch-src.sh" gnu-config.sub "$U2" "$S2")" "$SRC/build-aux/config.sub"
read -r U3 S3 _ <<<"$("$root/tools/fetch-src.sh" --lock gnu-config.guess)"
install -m 0755 "$("$root/tools/fetch-src.sh" gnu-config.guess "$U3" "$S3")" "$SRC/build-aux/config.guess"

cd "$SRC"
if [ ! -f Makefile ]; then
  CC="$CC" ./configure --host=armv7-apple-ios --prefix=/var/mobile/tools/patch
fi
# 恒真探针压制(幂等):模板删占位 + config.h 注释 + touch
python3 - <<'PYEOF'
import re, os
os.chdir(os.environ.get("PWD", "."))
for f in ["config.h", "config.hin"]:
    if not os.path.isfile(f): continue
    t = open(f).read()
    for s in ["HAVE_FUTIMENS", "HAVE_FUTIMESAT", "HAVE_UTIMENSAT",
              "HAVE_CANONICALIZE_FILE_NAME", "GNULIB_TEST_CANONICALIZE_FILE_NAME",
              "HAVE_NANOTIME"]:
        t = re.sub(r'^#define %s 1\b' % s, '/* #undef %s */  /* iOS 10 lacks it (probe lie) */' % s, t, flags=re.M)
        t = re.sub(r'^#undef %s\n' % s, '', t, flags=re.M)
    open(f, 'w').write(t)
PYEOF
touch config.h
sed -i 's/msvc-inval\.o msvc-nothrow\.o //; s/msvc-inval\.lo msvc-nothrow\.lo //' lib/Makefile 2>/dev/null || true
make -j4 CPPFLAGS="-I$here/include" >/dev/null 2>&1 || true
"$CC" -c -O2 -o src-compat.o "$here/src-compat.c"
"$CC" -O2 -o "$OUT/patch4-armv7" src/*.o src-compat.o $(ls lib/*.o | grep -v xalloc-die)
ldid -S "$OUT/patch4-armv7" 2>/dev/null || true
echo "==> $OUT/patch4-armv7"
