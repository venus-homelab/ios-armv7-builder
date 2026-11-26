#!/bin/bash
# Build tor 0.4.8.14 for armv7 iOS 10.x on Linux.
#
# Deps (self-contained -- matrix builds run on independent runners):
#   * libevent 2.1.12 static  -- auto-built here (tmux/build.sh's recipe:
#                                fixups + hand-written event-config.h)
#   * OpenSSL 4.0.3 static    -- auto-built (openssl/build.sh)
#   * zlib 1.3.1 static       -- auto-built (git/build.sh's recipe); the SDK
#                                has zlib.h but libSystem does NOT re-export
#                                zlib on iOS, so it must be a real static lib.
#
# Trims: dirauth module off (no need to be an authority); asciidoc off
# (no manpages); everything else stock.
#
# Source: tor_0.4.8.14.orig.tar.gz from Debian pool (sources.lock; the GitHub
# mirror only carries alpha tags; see docs/porting-backlog.md).
#
# Usage: ./build.sh          # output ../out/tor-<ver>-armv7 (UNSIGNED)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
TOR_VERSION="${TOR_VERSION:-0.4.8.14}"
SRC="${TOR_SRC:-$root/tmp/src/tor-$TOR_VERSION}"
LE_PREFIX="${LE_PREFIX:-$root/tmp/src/libevent-install}"
OSSL_PREFIX="${OSSL_PREFIX:-$root/tmp/src/openssl-4.0.3}"
ZLIB="${ZLIB:-$root/tmp/src/zlib-1.3.1}"
ZPREFIX="$root/tmp/src/zlib-prefix"

# SDK sysroot (toolchain.md 16/23)
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
[ -d "$IOS_SYSROOT/usr/include" ] || { echo "missing $IOS_SYSROOT (bootstrap-toolchain.sh stage 3)" >&2; exit 1; }
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
[ -n "$IOS_LD64" ] && [ -x "$IOS_LD64" ] || { echo "set IOS_LD64 to the cctools ld64" >&2; exit 1; }
export LD_LIBRARY_PATH="${LD64_LIBS:-$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ------------------------------------------------------------ openssl ----
[ -f "$OSSL_PREFIX/libssl.a" ] || {
    echo "==> building openssl first (tor's static dependency)"
    (cd "$root/net/openssl" && ./build.sh)
}
[ -f "$OSSL_PREFIX/libssl.a" ] || { echo "openssl build did not produce $OSSL_PREFIX/libssl.a" >&2; exit 1; }

# --------------------------------------------------------------- zlib ----
# git/build.sh's recipe verbatim: configure --static, darwin-ar conversion
# with a member-count check, then a prefix shape for tor's --with-zlib-dir.
if [ ! -f "$ZLIB/libz.a" ]; then
    [ -d "$ZLIB" ] || {
        mkdir -p "$root/tmp/src"
        read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock zlib)"
        ztar="$("$root/tools/fetch-src.sh" zlib "$U" "$SHA")"
        tar -C "$root/tmp/src" -xzf "$ztar"
    }
    ( cd "$ZLIB" \
      && CC="$root/tools/cc-wrapper.sh" AR="$root/tools/darwin-ar" RANLIB="$root/tools/darwin-ranlib" \
         CHOST=armv7-apple-darwin ./configure --static >/dev/null \
      && make -j"$(nproc)" libz.a >/dev/null )
    "$root/tools/darwin-ar" rcs "$ZLIB/libz.a.new" "$ZLIB"/*.o
    [ "$("$root/tools/darwin-ar" t "$ZLIB/libz.a.new" | wc -l)" -gt 0 ] || { echo "libz.a conversion produced 0 members" >&2; exit 1; }
    mv "$ZLIB/libz.a.new" "$ZLIB/libz.a"
fi
mkdir -p "$ZPREFIX/include" "$ZPREFIX/lib"
cp -f "$ZLIB/zlib.h" "$ZLIB/zconf.h" "$ZPREFIX/include/"
cp -f "$ZLIB/libz.a" "$ZPREFIX/lib/"

# ------------------------------------------------------------ libevent ----
# tmux/build.sh's recipe, inlined: conflict renames (strlcpy uses the SYSTEM one -- strlcpy.c's event_strlcpy_
# fallback went undefined on CI; strtok_r/strsep in the
# bundled fallbacks vs the sysroot declarations; arc4random_addrandom/buf
# statics vs the SDK's stdlib.h -- the device provides all three natively,
# dlsym-verified) + the hand-written event-config.h (libevent's own configure
# output cannot describe this target), static-only.
if [ ! -f "$LE_PREFIX/lib/libevent.a" ]; then
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock libevent)"
    letar="$("$root/tools/fetch-src.sh" libevent "$U" "$SHA")"
    rm -rf "$root/tmp/src/libevent-2.1.12-stable"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$letar"
    ( cd "$root/tmp/src/libevent-2.1.12-stable" \
      && sed -i 's/\bstrtok_r\b/evdns_strtok_r/g' evdns.c \
      && sed -i 's/\bstrsep\b/evhttp_strsep/g' http.c \
      && sed -i 's/\barc4random_addrandom\b/le_arc4random_addrandom/g; s/\barc4random_buf\b/le_arc4random_buf/g' arc4random.c \
      && CC="$root/tools/cc-wrapper.sh" AR="$root/tools/darwin-ar" RANLIB="$root/tools/darwin-ranlib" \
         ac_cv_func_strlcpy=yes \
         ac_cv_func_sendfile=no \
         ac_cv_header_sys_sendfile_h=no \
         ac_cv_header_netinet_in6_h=no \
         ./configure --host=armv7-apple-darwin --prefix="$LE_PREFIX" \
             --disable-shared --enable-static --disable-openssl \
             --disable-libevent-regress --disable-samples --disable-libevent-install >/dev/null \
      && cp "$root/tools/tmux/patches/event-config.h" include/event2/event-config.h \
      && make -j"$(nproc)" >/dev/null \
      && mkdir -p "$LE_PREFIX/lib" "$LE_PREFIX/include/event2" \
      && cp .libs/libevent*.a "$LE_PREFIX/lib/" \
      && cp include/event.h include/evdns.h include/evhttp.h include/evrpc.h \
            include/evutil.h "$LE_PREFIX/include/" \
      && cp include/event2/*.h "$LE_PREFIX/include/event2/" )
    [ -f "$LE_PREFIX/lib/libevent.a" ] || { echo "libevent build did not produce libevent.a" >&2; exit 1; }
fi

# ----------------------------------------------------------------- tor ----
[ -d "$SRC" ] || {
    read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock tor)"
    tor_tar="$("$root/tools/fetch-src.sh" tor "$U" "$SHA")"
    rm -rf "$SRC"
    mkdir -p "$root/tmp/src"
    tar -C "$root/tmp/src" -xzf "$tor_tar"
}
[ -f "$SRC/configure" ] || { echo "tor source layout unexpected" >&2; exit 1; }

# Device-verified runtime wall (2026-11-22): tor aborts at startup in
# crypto_fast_rng_new -- the SDK's sys/mman.h declares minherit(2) but
# carries NO inherit flags ("previously unimplemented MAP_INHERIT"), so
# map_anon.c's FLAG_NOINHERIT chain resolves to nothing and new_from_seed
# asserts on INHERIT_RES_KEEP.  Device probe: minherit(2, VM_INHERIT_NONE=1)
# returns 0 on iOS 10.3.3 -- the syscall works, only the header chain was
# missing.  Include <mach/vm_inherit.h> so FLAG_NOINHERIT = VM_INHERIT_NONE
# resolves and the RNG region really is unmapped in children.
if ! grep -q 'vm_inherit.h' "$SRC/src/lib/malloc/map_anon.c"; then
    sed -i 's|#include <errno.h>|#include <errno.h>\n#if defined(__APPLE__)\n#include <mach/vm_inherit.h>  /* VM_INHERIT_NONE: see the device-verified note above */\n#endif|' \
        "$SRC/src/lib/malloc/map_anon.c"
fi

cd "$SRC"
make distclean >/dev/null 2>&1 || true

# 全部环境变量用独立 export 行：自包含语句没有续行链，注释可以随便插。
# （本文件里"注释吞掉续行反斜杠导致 env 断链"的事故发生了三次，固化为
# 结构性规避；configure 之后有断言兜底。）
#
# SecureZeroMemory/RtlSecureZeroMemory/explicit_bzero/memset_s: 全是
# dynamic_lookup 恒真探针的受害者（check_decl 对"未声明"符号反而返回 yes
# 的反向逻辑 + check_func 恒真）——设备 iOS 10 只真有 memset_s，但 sysroot
# string.h 没声明，先全压掉走 tor 的可移植 memset 擦除路径。
export ac_cv_func_SecureZeroMemory=no
export ac_cv_func_RtlSecureZeroMemory=no
export ac_cv_func_explicit_bzero=no
export ac_cv_func_memset_s=no
export ac_cv_func_getresuid=no
export ac_cv_func_getresgid=no
export ac_cv_func_get_current_dir_name=no
export ac_cv_func_cap_set_proc=no
export ac_cv_func_gethostbyname_r=no
export ac_cv_func_libscrypt_scrypt=no
export ac_cv_func_pthread_condattr_setclock=no
export ac_cv_func_eventfd=no
export ac_cv_func_pipe2=no
export ac_cv_func_timingsafe_memcmp=no
export ac_cv_func_gnu_get_libc_version=no
export ac_cv_func_accept4=no
export ac_cv_func_prctl=no
# SDK mode: crt_externs.h is not in the SDK (the _NSGetEnviron FUNCTION probe
# lies yes under dynamic_lookup, so tor's env.c would call it with no
# declaration).  The device's environ data symbol exists (dlsym OK) -- take
# tor's plain-environ fallback, which declares extern char **environ itself.
export ac_cv_func__NSGetEnviron=no
export CC="$root/tools/cc-wrapper.sh"
# NULL: sysroot 手写头（sys/socket.h 等）不提供（stddef 链缺失，backlog 有
# 记）。值必须用 0 而不是 ((void*)0)：configure 的 shell 把未加引号的括号
# 当元字符，AC_PROG_CC 被毒倒后整条探针链回落宿主 gcc（2026-11-14 实录）。
export CFLAGS="-O2 -DNULL=0 -I$LE_PREFIX/include -I$LE_PREFIX/include/event2"

./configure \
    --host=armv7-apple-darwin \
    --prefix=/var/mobile/tools/tor \
    --disable-asciidoc \
    --disable-module-dirauth \
    --disable-tool-name-check \
    --disable-lzma \
    --disable-zstd \
    --enable-static-openssl \
    --enable-static-libevent \
    --enable-static-zlib \
    --with-zlib-dir="$ZPREFIX" \
    --with-openssl-dir="$OSSL_PREFIX" \
    --with-libevent-dir="$LE_PREFIX"

# 断言：探针必须用我们的 wrapper（CC 失联 = 探针跑在宿主 gcc 上，全部
# 结论不可信——libevent 明明在却报找不到就是这么来的）。
grep -q "cc-wrapper" config.log || { echo "FATAL: configure probes did not use the cross wrapper" >&2; exit 1; }

# The OpenSSL 4 static archives reference ___atomic_is_lock_free (the ONE
# atomic helper the device libSystem lacks) -- link the honest thumb shim,
# same as curl/git/nmap.  LIBS is empty here and lands LAST on the link line.
C8OBJ="$root/tmp/curl-c8fixed.o"
mkdir -p "$root/tmp"
"$root/tools/cc-wrapper.sh" -c "$root/tools/shims/c8fixed.S" -o "$C8OBJ"
sed -i "s|^LIBS = *$|LIBS = $C8OBJ|" Makefile
grep -q "c8fixed.o" Makefile || { echo "LIBS atomic-shim sed did not apply" >&2; exit 1; }

# libtor.a 等归档必须 darwin 格式（toolchain.md §2/§15：GNU ar 会被 ld64
# 整体无视），AR/RANLIB 换 darwin 变体。
make -j"$(nproc)" AR="$root/tools/darwin-ar" RANLIB="$root/tools/darwin-ranlib"

BIN="$SRC/src/app/tor"
[ -f "$BIN" ] || BIN="$(find "$SRC/src" -name tor -type f | head -1)"
[ -f "$BIN" ] || { echo "tor was not built" >&2; exit 1; }

# Post-link audit + FULL-SYMBOL device probe (a daemon this size deserves
# the strongest gate: every undefined symbol must bind at launch on the
# device, not just the ones --version happens to touch).
"$root/tools/check-undefined.sh" "$BIN" || true
# the full-symbol device probe needs the device -- CI runs gate-only
if [ -n "${DEV:-}" ]; then
    "$root/tools/llvm-nm" -u "$BIN" | awk '{print $NF}' | "$root/tools/probe-symbols.sh" > "$root/out/tor-verified-symbols.txt"
else
    echo "    (DEV not set -- skipping the full-symbol device probe)"
fi

mkdir -p "$root/out"
cp "$BIN" "$root/out/tor-$TOR_VERSION-armv7"
echo "==> $root/out/tor-$TOR_VERSION-armv7"
file "$root/out/tor-$TOR_VERSION-armv7" | sed 's/^/    /'
echo "    (unsigned by design -- make-deb.sh signs the staged copy;"
echo "     device-verified symbol list: out/tor-verified-symbols.txt)"
