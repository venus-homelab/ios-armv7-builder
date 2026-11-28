# proxychains-ng 4.18 移植专项（armv7 iOS 10.3.3）

> 包：`proxychains4_4.18-1_iphoneos-arm.deb` · **设备实测通过**（5/5：钩子加载、
> 插桩生效、链路协商、签名、配置）
> 构建脚本注释即详细文档：`net/proxychains-ng/build.sh`；本文记状态、机理与约束。

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | 4.18（官方 release 资产，sources.lock 锁定；2026-11-22 发布） |
| 包名 | `proxychains4_4.18-1_iphoneos-arm.deb` |
| 安装路径 | `/var/mobile/tools/proxychains/{bin,lib,etc}` + `/var/mobile/tools/bin/proxychains4` 链接 |
| CI | single-build 发布路径；门禁 proxychains4 21/21、daemon 35/35、dylib 83/83（裸环境可复验） |
| 验收 | 设备实测：DYLD_INSERT 加载 dylib ✓、DYLD_INTERPOSE 插桩生效 ✓（死端口走 strict chain 而非直连失败）✓ |

## 2. 机理（为什么这台设备能用它）

`proxychains4 <cmd>` 设置 `DYLD_INSERT_LIBRARIES=/var/mobile/tools/proxychains/lib/libproxychains4.dylib`
后 exec：dyld 把 dylib 注入目标进程，libproxychains.c 的 **DYLD_INTERPOSE**
块（Darwin 原生插桩，configure 经编译探针自动选中）替换 `connect`/
`getaddrinfo` 等 → 一切动态链接程序透明走代理。出厂 conf 默认指向 tor 的
SOCKS5 127.0.0.1:9050（remote DNS，主机名不出 tor）。

```
proxychains4 curl -s https://check.torproject.org/api/ip
```

## 3. 约束与坑

| 坑 | 要点/修法 |
|---|---|
| **Apple 系统二进制 hook 不了** | `/usr/bin/ssh` 等带 `__RESTRICT` 段，dyld 忽略 DYLD_INSERT——LD_PRELOAD 族工具共同的 iOS 硬约束。仓库自建包（curl/ssh/git…）无此段，可 hook |
| cc-wrapper 扩展名匹配序 | `-Wl,-install_name,libproxychains4.dylib` 被 `*.dylib` 输入文件模式整段吞掉 → ld64 "unknown option"。修法：-Wl 分支提到扩展名匹配之前（行为对所有既有用户不变；tools/cc-wrapper.sh） |
| configure 的 darwin 探测 | 走 `check_define __APPLE__`（编译探针）——wrapper 目标即 armv7-apple-ios,自动选中 dylib + `-DIS_MAC=1` 与 `-install_name`;MONTEREY_HOOKING 只在 macOS12 宏存在时开启,iOS 10.3.3 永不触发 ✓ |
| proxychains4 无 --version | 裸调用打 usage 且 rc=1；验收用例走 `grep -c` |

## 4. 已知关联问题：tor4 起动即崩（单独墙）

验收时发现设备 tor4（0.4.8.14-1）起动即 Abort（`crypto_fast_rng_new`
断言，backtrace 全文见设备 /var/tmp/tor-test.log）——**tor4 的运行时墙**，
与 proxychains 无关；proxychains 的钩子机制已用"无服务死端口"方式独立
验证。tor 修复后 `proxychains4 curl -s https://check.torproject.org/api/ip`
即为全链路终验。

## 5. 相关文件

| 文件 | 内容 |
|---|---|
| `net/proxychains-ng/build.sh` | configure 自适配说明、三产物、门禁 |
| `net/proxychains-ng/make-deb.sh` | 布局、出厂 conf（tor-ready）、三重签名断言 |
| `tools/cc-wrapper.sh` | -Wl 分支前移（本轮结构性修复） |
| `tests/proxychains.sh` | 设备验收（5 用例，只读） |
