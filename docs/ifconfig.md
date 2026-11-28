# ifconfig + route + arp + ndp(network_cmds-457)移植专项(armv7 iOS 10.3.3)

> 包:`ifconfig4_457-2_iphoneos-arm.deb`(root:wheel 0755,**不 setuid**)· 2026-11-20 完成并设备验证(457-2 增 arp/ndp)
> 上游:Apple `network_cmds-457`(Darwin 16 / xnu-3789 时代,与 iOS 10.3.3 精确同代)
> 源:**tarball 取源**(sources.lock 钉版,fetch-src 全程校验,见 §7);端口侧只存
> 补丁 `net/ifconfig/patches/` 与头 `net/ifconfig/include/`——.tproj 不再 vendor

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | network_cmds-**457**(iOS 10.3.3 = Darwin 16 = xnu-3789,同代对齐;更新的 tag 漂向新内核成语) |
| 源 | tarball 取源(sources.lock 行 `network_cmds`,sha256 每次校验;补丁清单与命令见 §7) |
| 构建 | SDK sysroot 模式(§16)+ `-DPRIVATE` + 端口自带 `include/`(xnu-3789.70.16 头) |
| 安装 | `/var/mobile/tools/ifconfig/{ifconfig,route}` + `/usr/bin` 符号链接(postinst 建、prerm 清,rsync 3.3.0-2 先例) |
| 权限 | root:wheel 0755,**不 setuid**——setuid ifconfig = 把整个接口控制权(含 en0 down)交给 mobile,绝不 |
| 验收 | 见 §4 |

iproute2 没有 Darwin 版:它整个建立在 Linux netlink(rtnetlink)上,Darwin 无此
socket 族,无从移植。Homebrew 的 `iproute2mac` 只是拿 ifconfig/route/netstat 拼
的 CLI 壳,恰好证明 BSD 侧正解就是 ifconfig + route + netstat(自研 netstat 已有)。

## 2. 墙实录(按撞上顺序)

1. **iOS SDK 头是"公开裁剪版",不是完整内核头**。SDK 的 `net/if.h`、
   `sys/sockio.h`、`net/if_var.h` 全部删掉了 PRIVATE 段:`if_descreq`/
   `if_linkparamsreq`/`if_throttlereq`、`ifr_log`/`ifru_2kcl`、
   `SIOCSIFDESC/SIOCSIFLINKPARAMS/SIOCSIFTHROTTLE/SIOCSIFLOG/SIOCSIF2KCL`、
   `if_bandwidths`/`if_latencies`/`if_interface_state`、
   `if_traffic_class`/`if_data_extended`/`if_packet_stats`/`if_rxpoll_stats`
   一个都不在。解法 = **xnu-3789.70.16 完整头 + `-DPRIVATE`**(Apple 内部
   构建 network_cmds 的同款姿势),见 §3。
2. **shadow 陷阱**:`-I sysroot-overlay/usr/include` 会把 xnu 的
   `sys/param.h` 等同名头遮住 SDK 头,xnu 世界头文件互相引用 SDK 没有
   的 `endian.h` → 雪崩。解法 = 端口自带 `include/` **只放 SDK 真缺的
   头**(18 个)+ 3 个必须整头换用的 shadow(net/if.h、net/if_var.h、
   sys/sockio.h),SDK 其余头原样生效。
3. **`tmp/sysroot` 是 musl 时代的旧 sysroot**(epoll.h/inotify.h 等
   Linux 头都在),§16 拍板后只服务存量 24 包,新移植禁止再用;其中
   连 SDK 自带的 `sys/queue.h` 都没有。第一次误当 SDK 用,撞墙即回。
4. **kldload/modstat(sys/module.h、sys/linker.h)是 FreeBSD 遗留**,
   上游已包在 `#ifndef __APPLE__` 里,Darwin 构建天然跳过,零补丁。
5. **fetch-darwin-header.sh 的 extern "C" 门禁是文本检查**,看不见
   `#ifdef KERNEL_PRIVATE` 护栏:这些内核头的"函数声明"全在私有护栏
   内(用户态不可见),但正则会命中 `return (...)`/`__attribute__` 成员
   等假阳性。解法 = 按工具自己的处方,在护栏**内侧**补
   `#if defined(__cplusplus) extern "C" { #endif` 包裹(语义诚实),
   原文补丁保留 provenance。
6. **uuid_t 的出处**:xnu `net/if.h` 的 `struct if_agentidreq`(PRIVATE
   段)用 uuid_t;内核构建从 KERNEL 侧 uuid 头拿,用户态 SDK 从
   `sys/_types/_uuid_t.h` 拿。stamped if.h 里补一行该 include(已注明)。
7. **arp/ndp 并入(457-2)**:两件与 ifconfig 同 include/ 集,**几乎零改动**——
   arp.c 只删了未使用的 `<nlist.h>`、补了私有 NET_RT_DUMPX(8)/DUMPX_FLAGS(9)
   define(xnu-3789 bsd/sys/socket.h:761-762 的内核值,SDK 公开头停在
   DUMP2);ndp.c 同款 define + `<nlist.h>` 删除 + `sysctlbyname` 第 5 参
   NULL→0(上游类型 bug,新头惯出来的)。`net/iso88025.h`(token-ring 遗物,
   xnu-3789 已删)从 FreeBSD releng/10.3 原版取,`netinet/if_ether.h`、
   `net/if_arp.h` 从 xnu 拉入端口 include/。
8. **ld64 起不来**(`libBlocksRuntime.so not found`)= 环境变量不全。
   §1 的标准 export 必须整块带上(尤其 `LD_LIBRARY_PATH=x-libdispatch/
   lib:x-tapi/lib`);build.sh 已固化全默认值,裸跑即可。

## 3. 头清单(端口 `net/ifconfig/include/`,21 个)

- **SDK 真缺(18)**:`net/route.h`、`net/if_media.h`、`net/if_types.h`、
  `net/if_mib.h`、`net/if_vlan_var.h`、`net/if_bond_var.h`、
  `net/if_bridgevar.h`、`net/lacp.h`、`net/if_bond_internal.h`、
  `net/pktsched/pktsched.h`、`net/net_kev.h`、`netinet/in_var.h`、
  `netinet6/nd6.h`、`netinet6/in6_var.h`、`netinet6/scope6_var.h`、
  `sys/kern_event.h`、`sys/sys_domain.h`(级联拉取,×2 未走外层工具门禁
  的三个由端口内直落)
- **整头 shadow(3)**:`net/if.h`、`net/if_var.h`、`sys/sockio.h`
  (xnu-3789.70.16 原文 + provenance 戳;if.h 加一行 `_uuid_t.h` include)
- 其余(ether.h、if_dl.h、queue.h、in.h、ifaddrs.h……)全用 SDK 自带。

私有护栏内的 extern "C" 包裹记录:if_vlan_var(KERNEL_PRIVATE)、
if_bridgevar/if_bond_internal(XNU_KERNEL_PRIVATE/KERNEL_PRIVATE)、
nd6.h(两段 BSD_KERNEL_PRIVATE)、in6_var(557-582 与 1092-1166 两段)、
scope6_var、kern_event(`#ifdef KERNEL` 区)、lacp(无真声明,整段包裹)。

## 4. 验收(2026-11-20 设备实测)

| 探针 | 结果 |
|---|---|
| mobile `ifconfig -a` | lo0/en1/en2/en0/awdl0/utun0 全列,en0 带 192.168.31.70 |
| mobile `ifconfig en0` | ether MAC、inet6 secured、`media: autoselect`、`status: active`、`type: Wi-Fi`(ifmedia 全通) |
| mobile `route -n get default` | gateway 192.168.31.1、interface en0、STATIC flags |
| mobile `lo0 <ip> alias` | **SIOCAIFADDR: permission denied**(接口 ioctl 需 root,符合预期) |
| root `lo0 10.173.0.1 alias` → `ping 10.173.0.1` | **2/2 received, 0.33ms**;`-alias` 删除后恢复 |
| root `route add -host 10.173.0.2 127.0.0.1` → `route -n get` | gateway 127.0.0.1 / lo0 / HOST,STATIC;`delete` 后回落 default 网关 |
| check-undefined.sh | ifconfig 72/72、route 62/62、arp 51/51、ndp 54/54 全解析 |
| `arp -a`(mobile) | 9 条邻居全出:小米路由/gogs 主机/iPad 自身(permanent)/组播条目 |
| `ndp -a`(mobile) | lo0/en0/awdl0 邻居与 Router 位全出 |

## 5. 用法

```sh
ifconfig -a                  # 全接口(mobile 可用)
ifconfig en0                 # 单接口状态(media/status/type)
ifconfig lo0 10.173.0.1 alias    # root:加地址别名
ifconfig lo0 10.173.0.1 -alias   # root:删
route -n get default         # 默认路由(mobile 可用)
route add -host 10.173.0.2 127.0.0.1   # root
route delete 10.173.0.2      # root
route -n monitor             # 路由表变化监听
```

## 6. 已知限制

- 写操作(up/down、alias、route add/del/flush)必须 root——刻意不 setuid。
- ifbond/ifbridge/ifvlan 子命令依赖内核 clone 类型;设备内核是否编译
  bridge 等未逐一验证,`ifconfig create bridge` 失败即内核不支持,非本包问题。
  (arp/ndp 已于 457-2 并入,见 §2 第 7 条。)

## 7. 源接入(2026-11-25 fetch-src 收口)

**锁定版本**:Apple `network_cmds-457` tag archive
`https://github.com/apple-oss-distributions/network_cmds/archive/refs/tags/network_cmds-457.tar.gz`,
sha256 `7b4daad05ddd7d64df6e4921c3b0c1f15f06d8f69ee4645d9eac567cc9c201e8`
(实算自下载字节,516,698 B)。sources.lock 只追加一行(pkg `network_cmds`);
`tools/fetch-src.sh --check network_cmds` 常态校验,缓存命中零网络。
tarball 顶层目录 `network_cmds-network_cmds-457/` 含数百个工具,本包只取
ifconfig/route/arp/ndp 四个 .tproj(byte-ab 的 pristine-source 钩子按该顶层
目录名删树,与 build.sh 的净源协议对齐)。

**补丁清单**(`net/ifconfig/patches/`,build.sh 按序 `patch -p1` 应用到
构建位副本,净源树本身不被污染):

| 文件 | 内容 |
|---|---|
| `010-arp-nlist-netrt-dumpx.patch` | arp.c:删未使用的 `<nlist.h>`(iOS SDK 无此头);补私有 `NET_RT_DUMPX(8)`/`NET_RT_DUMPX_FLAGS(9)` define(xnu-3789 bsd/sys/socket.h 内核值,SDK 公开头停在 DUMP2) |
| `020-ndp-nlist-netrt-sysctl.patch` | ndp.c:同款 nlist/NET_RT 处理;`sysctlbyname("net.inet6.send.cga_parameters")` 第 5 参 `NULL→0`(上游类型 bug) |

原 vendored 39 个 .tproj 文件中 36 个与 tarball 原版逐字节相同,差异全部
集中在上述两个 .c——补丁保真已验证:净树+补丁 == 原 vendored 文件(逐字节)。

**include/ 特例(保留 vendored)**:21 个头是 xnu-3789.70.16 内核头(§3),
network_cmds tarball 内**没有任何 include/ 目录**、不含其中任何一个——
无从替代,必须随包走。`APPLE_LICENSE` 与 tarball 顶层同名文件逐字节相同,
保留包目录副本(授权文本必须随包)。

**净源构建命令**(build.sh 已固化,手动等价式):

```sh
read -r URL SHA _ <<<"$(tools/fetch-src.sh --lock network_cmds)"
tarball="$(tools/fetch-src.sh network_cmds "$URL" "$SHA")"
rm -rf tmp/src/network_cmds-network_cmds-457     # 净源协议:解前 rm 旧树
tar -C tmp/src -xzf "$tarball"
# build.sh 随后:拷 4 个 .tproj → tmp/src/ifconfig-build,按序 patch -p1,
# 再以原有编译参数(-DPRIVATE -I include/)出 4 个二进制
bash net/ifconfig/build.sh && bash net/ifconfig/make-deb.sh
```

**净源 vs vendored 对照**:同编译器同参数下,净源+补丁与原 vendored 树
产出的二进制(ifconfig/route/arp/ndp,连同 traceroute 包的 traceroute)
`cmp` 全部逐字节一致;`tools/byte-ab.sh net/ifconfig` 双构建 **IDENTICAL**
(2026-11-25,日志 tmp/byte-ab/ifconfig/)。
