#!/bin/bash
# Build traceroute (Apple network_cmds-457, Darwin 16 era) for armv7 iOS 10.x.
# SDK sysroot mode per the 2026-11-15 ruling (docs/toolchain.md §16).
#
# Why 457: iOS 10.3.3 = Darwin 16 = xnu-3789, same era as macOS 10.12
# (network_cmds-457).  Later tags drift to newer kernels/SDK idioms.
#
# Why -DPRIVATE and the include dirs (see docs/traceroute.md once written):
#   - The iOS 10.3 SDK ships PUBLIC cuts of <netinet/ip_var.h>,
#     <netinet/udp_var.h>, <netinet/tcpip.h>: it ships NONE of the three
#     (they live in System.framework/PrivateHeaders on the Mac).  Apple's
#     traceroute target (-DPRIVATE, PrivateHeaders search path) sees the real
#     ones.  Fix: xnu-3789.70.16 copies in this port's include/ (stamped,
#     userspace sections only -- no KERNEL_PRIVATE/BSD_KERNEL_PRIVATE defined,
#     same as Apple's userspace build).
#   - SO_RECV_ANYIF (xnu-3789.70.16 bsd/sys/socket.h:318, 0x1104, in the
#     '#ifdef PRIVATE' tail) is stripped from the SDK's public <sys/socket.h>.
#     One-line #ifndef guard added at the top of traceroute.c (in-family with
#     the arp.c/ndp.c NET_RT_DUMPX single-line fixes in ifconfig/).
#   - ifconfig/include/ (same network_cmds-457 family, same xnu-3789 kernel
#     header set) is reused via -I as required by the porting rule; nothing
#     is re-fetched or duplicated there.
#   - Net effect: ZERO functional patch lines upstream beyond the one
#     SO_RECV_ANYIF #ifndef -- which since 2026-11-25 lives in
#     patches/010-traceroute-so-recv-anyif.patch instead of a vendored file.
#
# Source provenance (2026-11-25, fetch-src 接入): traceroute.tproj is NO
# LONGER vendored in git.  Every build fetches the pinned network_cmds-457
# tarball through tools/fetch-src.sh (sources.lock row "network_cmds", sha256
# verified on every use), extracts it under $root/tmp/src (old tree removed
# first -- 净源协议), copies traceroute.tproj to a build area and applies the
# one port patch.  The patched result is byte-identical with the previously
# vendored file, so the binaries are unchanged.  include/ stays vendored BY
# DESIGN: those are xnu-3789.70.16 kernel headers absent from the tarball
# (docs/traceroute.md §源接入).
#
# Config macros mirror Apple's pbxproj target (network_cmds-457, target
# "traceroute", Debug/Release): GCC_PREPROCESSOR_DEFINITIONS = HAVE_SOCKADDR_SA_LEN
# only -- plus the autoconf ones true on Darwin (sys/sysctl.h, usleep,
# setlinebuf; NOT sys/select.h, NOT malloc.h, NOT os-proto.h).
#
# Install shape: Apple builds traceroute setuid root, mode 04555, root:wheel,
# INSTALL_PATH = /usr/sbin.  We follow the sibling ping port and ship
# setuid 4755 (see make-deb.sh): SOCK_RAW needs root on iOS 10 (ping port
# verdict: unprivileged SOCK_DGRAM ICMP sends but never receives).
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

# 构建位:拷出本包 .tproj,按序打移植补丁(净源树本身保持 pristine)。
BUILD="$root/tmp/src/traceroute-build"
rm -rf "$BUILD"
mkdir -p "$BUILD"
cp -R "$NETSRC/traceroute.tproj" "$BUILD/"
for p in "$here"/patches/[0-9]*.patch; do
    [ -e "$p" ] || continue
    patch --silent -d "$BUILD" -p1 < "$p"
done

TP="$BUILD/traceroute.tproj"
SRC="$TP/traceroute.c $TP/as.c $TP/findsaddr-socket.c $TP/ifaddrlist.c \
$TP/version.c"

CFLAGS=(-O2 -Wall -DPRIVATE
        -DHAVE_SOCKADDR_SA_LEN
        -DHAVE_SYS_SYSCTL_H
        -DHAVE_USLEEP
        -DHAVE_SETLINEBUF)

"$CC" "${CFLAGS[@]}" \
    -I"$here/include" -I"$root/net/ifconfig/include" -I"$TP" \
    -o "$OUT/traceroute-armv7" $SRC

"$root/tools/check-undefined.sh" "$OUT/traceroute-armv7"

ldid -S "$OUT/traceroute-armv7" 2>/dev/null || true
echo "==> $OUT/traceroute-armv7"