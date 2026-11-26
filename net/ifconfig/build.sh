#!/bin/bash
# Build ifconfig + route (Apple network_cmds-457, Darwin 16 era) for
# armv7 iOS 10.x.  SDK sysroot mode per the 2026-11-15 ruling (§16).
#
# Why 457: iOS 10.3.3 = Darwin 16 = xnu-3789, same era as macOS 10.12
# (network_cmds-457).  Later tags drift to newer kernels/SDK idioms.
#
# Why -DPRIVATE and port-local include/ (see docs/ifconfig.md):
#   - kldload/modstat (sys/module.h, sys/linker.h) are FreeBSD leftovers,
#     already inside #ifndef __APPLE__ upstream -- no patch needed.
#   - The iOS 10.3 SDK ships PUBLIC cuts of net/if.h, sys/sockio.h and
#     net/if_var.h; network_cmds needs the PRIVATE sections (if_descreq,
#     ifr_log/ifru_2kcl, SIOCSIFDESC/LINKPARAMS/THROTTLE/LOG/2KCL,
#     if_bandwidths/if_latencies/if_interface_state, if_traffic_class/...).
#     Fix: xnu-3789.70.16 kernel headers in include/ (stamped, some with
#     extern-"C" wraps around kernel-private decls per the fetch-tool gate)
#     + -DPRIVATE, exactly how Apple builds these tools internally.
#   - include/ = 18 SDK-missing xnu headers + 3 shadowing copies of
#     net/if.h, net/if_var.h, sys/sockio.h.  No patch on the .c files.
#
# Source provenance (2026-11-25, fetch-src 接入): the four .tproj trees are
# NO LONGER vendored in git.  Every build fetches the pinned network_cmds-457
# tarball through tools/fetch-src.sh (sources.lock row "network_cmds", sha256
# verified on every use), extracts it under $root/tmp/src (old tree removed
# first -- 净源协议), copies the needed .tproj dirs to a build area and
# applies the port patches in patches/ (010-arp-*, 020-ndp-*).  The patched
# result is byte-identical with the previously vendored files, so the
# compiler input -- and therefore the binaries -- are unchanged.  include/
# stays vendored BY DESIGN: those are xnu-3789.70.16 kernel headers that do
# not exist anywhere in the network_cmds tarball (docs/ifconfig.md §源接入).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here" && git rev-parse --show-toplevel)"
OUT="$root/out"

# Canonical build env (docs/toolchain.md §1); allow overrides.
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"   # hand-written stubs anchor -lSystem
export IOS_LD64="${IOS_LD64:-${LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}}"
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

CC="$root/tools/cc-wrapper.sh"
mkdir -p "$OUT"

# ---- 取源:network_cmds-457(sources.lock 钉版,fetch-src 全程校验) --------
NC_TOP="network_cmds-network_cmds-457"        # github tag archive 的顶层目录名
NETSRC="$root/tmp/src/$NC_TOP"
read -r NC_URL NC_SHA _ <<<"$("$root/tools/fetch-src.sh" --lock network_cmds)"
nc_tar="$("$root/tools/fetch-src.sh" network_cmds "$NC_URL" "$NC_SHA")"
# 净源协议:解前 rm 旧树,每次构建都从 tarball 原字节出发(byte-ab 的
# pristine-source 钩子按同一顶层目录名删树,两道防线一致)。
rm -rf "$NETSRC"
mkdir -p "$root/tmp/src"
tar -C "$root/tmp/src" -xzf "$nc_tar"

# 构建位:拷出本包 4 个 .tproj,按序打移植补丁(净源树本身保持 pristine,
# traceroute 等同 tarball 消费者不受本包补丁影响)。
BUILD="$root/tmp/src/ifconfig-build"
rm -rf "$BUILD"
mkdir -p "$BUILD"
for t in ifconfig route arp ndp; do
    cp -R "$NETSRC/$t.tproj" "$BUILD/"
done
for p in "$here"/patches/[0-9]*.patch; do
    [ -e "$p" ] || continue
    patch --silent -d "$BUILD" -p1 < "$p"
done

IFC="$BUILD/ifconfig.tproj"
SRC_IFC="$IFC/ifconfig.c $IFC/af_inet.c $IFC/af_inet6.c $IFC/af_link.c \
$IFC/ifclone.c $IFC/ifmedia.c $IFC/ifbond.c $IFC/ifbridge.c $IFC/ifvlan.c"

"$CC" -O2 -Wall -DPRIVATE -I"$here/include" -o "$OUT/ifconfig-armv7" $SRC_IFC
ldid -S "$OUT/ifconfig-armv7" 2>/dev/null || true
echo "==> $OUT/ifconfig-armv7"

"$CC" -O2 -Wall -DPRIVATE -I"$here/include" -o "$OUT/route-armv7" "$BUILD/route.tproj/route.c"

# arp + ndp (2026-11-20): same network_cmds-457 family, same include/ set.
# Patches: patches/010-arp-nlist-netrt-dumpx.patch (arp.c: unused <nlist.h>
#   include dropped; private NET_RT_DUMPX(8)/DUMPX_FLAGS(9) defines added --
#   xnu-3789 kernel header values, the SDK's public socket.h stops at DUMP2)
# and patches/020-ndp-nlist-netrt-sysctl.patch (ndp.c: same NET_RT defines,
#   unused <nlist.h> dropped, sysctlbyname newlen NULL->0 -- upstream type
#   bug).  Applied to the build copy above; the vendored tree never existed
#   as such since fetch-src 接入 (2026-11-25).
"$CC" -O2 -Wall -DPRIVATE -I"$here/include" -o "$OUT/arp-armv7" "$BUILD/arp.tproj/arp.c"
"$CC" -O2 -Wall -DPRIVATE -I"$here/include" -o "$OUT/ndp-armv7" "$BUILD/ndp.tproj/ndp.c"
# arp/ndp shipped UNSIGNED in 457-2 -- only ifconfig/route were signed
# (2026-11-24 pool audit).  Sign everything and PROVE it (set -e kills the
# script when ldid -e rejects an unsigned file -- no || true, the silent-
# failure rule): a payload member without a signature never leaves the tree
for b in ifconfig route arp ndp; do
    ldid -S "$OUT/$b-armv7"
    ldid -e "$OUT/$b-armv7" >/dev/null
done
echo "==> $OUT/route-armv7"
