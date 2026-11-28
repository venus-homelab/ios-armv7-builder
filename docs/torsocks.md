# torsocks 2.5.0 移植专项（armv7 iOS 10.3.3）

> 包：`torsocks4_2.5.0-1_iphoneos-arm.deb` · **构建完成；机理设备实测通过（真库
> 全链路 E2E）；deb 部署验收待补**（tests/torsocks.sh 上机前 SKIP）
> 构建脚本注释即详细文档：`net/torsocks/build.sh`；可行性探针证据：
> `net/torsocks/probe/`。本文记**状态、机理、坑与结论**，细节指向 build.sh。

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | 2.5.0（Debian pool 的上游 orig tarball，sources.lock 锁定；sha256 31a917328b…41f） |
| 包名 | `torsocks4_2.5.0-1_iphoneos-arm.deb` |
| 安装路径 | `/var/mobile/tools/torsocks/{bin,lib/torsocks,etc/tor}` + `/var/mobile/tools/bin/torsocks` 链接 |
| 验收 | 构建完成（门禁 67/67 未定义符号设备白名单解析；byte-ab IDENTICAL）；**机理在设备实测通过**（真 libtorsocks 注入 curl 全链路 E2E，见 §4）；deb 上机验收待补 |
| 立项依据 | 生死题先探后建：DYLD_INSERT 类工具在本机可行性由最小探针实证（probe/matrix-20261125.log），三态结论=**带条件活** |

## 2. 机理与依赖链

```
torsocks(1) wrapper          ← src/bin/torsocks.in 生成；导出两个环境变量
  ├─ DYLD_INSERT_LIBRARIES=/var/mobile/tools/torsocks/lib/torsocks/libtorsocks.dylib
  └─ DYLD_FORCE_FLAT_NAMESPACE=1   ← ★ 没有它插桩不生效（见 §3 坑 #4）
        ↓
libtorsocks.dylib（导出 connect/socket/getaddrinfo/gethostbyname/…）
  ├── 目标程序必须可 hook：仓库自建二进制 ✓；Apple 系统二进制有
  │   __RESTRICT 段，dyld 忽略注入（LD_PRELOAD 族共同硬约束，proxychains.md §3）
  └── 接管后 → tor SOCKS5（设备 tor4 默认 127.0.0.1:9050）
```

- 原函数解析走 `dlopen("libSystem.dylib") + dlsym` 存进 `tsocks_libc_*`
  指针——库从不按名字调被钩函数，flat namespace 重绑不会自递归。
- getaddrinfo → **SOCKS5 RESOLVE**（tor 扩展 CMD 0xF0，ATYP=DOMAIN）：主机名
  在设备上不解析，不出端。`.onion` 走 OnionAddrRange 假 IP cookie（127.42.42.0/24）。
- 依赖：仅 libSystem（门禁 67/67 全部来自设备 dylib 白名单，零自建依赖）。

与邻包分工：privoxy4 管 HTTP 入口，proxychains4 管通用代理链；torsocks 的
增量在 **tor 语义**——SOCKS5 远端解析、.onion 主机名透传、per-process 流隔离
（`--isolate`/`IsolatePID`）、非 TCP/敏感调用拒绝面。

## 3. 坑列表

| # | 坑 | 要点/修法 |
|---|---|---|
| 1 | Apple SDK `secure/_string.h` | string.h **无条件**包含它，`strlcpy/strlcat` 恒为 fortify 宏——上游自带的 ext/strl{cpy,cat}.c 定义必炸。config.h 定义 `HAVE_STRLCPY/STRLCAT`，调用绑设备 libSystem（BSD 血统，恒有） |
| 2 | config.h 不会自己被包含 | 上游只有 torsocks.h `#include "config.h"`，其余编译单元全靠 configure 的 `-include config.h` 强制注入；漏掉则 HAVE_STRL* 守卫失明，坑 #1 复发。build.sh 照抄 `-include config.h` |
| 3 | 上游 darwin bug：accept4 | `init_libc_symbols()` 无条件引用 `tsocks_libc_accept4`，声明却只有 `__linux__` 分支有（iOS 无 accept4，dlsym 必 NULL → 启动即退）。`patch-darwin.py` 按 upstream 自己的守卫惯例补 `#if defined(__linux__)`（accept.c:90 同款） |
| 4 | **只注入不插桩** | DYLD_INSERT_LIBRARIES 装载成功 ≠ 接管。两级命名空间的宿主仍直连；**必须同时 `DYLD_FORCE_FLAT_NAMESPACE=1`**（wrapper 在 darwin* 分支导出）。设备实测：不带它 curl 直连真网，带它才走 SOCKS5。探针矩阵 (b) vs (d) 同一结论 |
| 5 | 无 generated configure + 无 libtool | Debian orig tarball = git tag 重打包，只有 configure.ac；`AC_PROG_LIBTOOL` 需要 libtoolize（CI Dockerfile 只装 libtool-bin）。放弃 configure，手写 config.h + 直编（sqlite「故意不跑 configure」先例）；host_os 的 darwin 分支语义（LIBC_NAME、DYLD_INSERT、SHLIB_EXT）由 build.sh 直接实现 |
| 6 | tor4 引导墙（关联，非本包） | 本网络下 tor4 bootstrap 卡 14%（relay 不可达；对应 backlog obfs4proxy 触发条件）。E2E 因此用本地罐头 SOCKS5 服务器验满协议，tor 直连基线未成 |

## 4. 设备侧用法 / 注意事项

```sh
torsocks curl -s https://check.torproject.org/api/ip   # 逐命令接管（tor4 在 9050）
torsocks --isolate curl …        # 每进程独立 tor 电路（SOCKS5 隔离认证）
torsocks -u NAME -p PASS curl …  # 指定 SOCKS5 认证
. torsocks on                    # 整个 shell 进 tor 模式（须 source）
. torsocks off                   # 退出 tor 模式
torsocks --shell                 # 起一个 torified shell
TORSOCKS_CONF_FILE=… torsocks …  # 换配置
```

- 装载两个环境变量由 wrapper 导出；**别手动只设 DYLD_INSERT_LIBRARIES**
  （坑 #4）。设备 `/bin/sh → bash`（实测），wrapper 的 darwin OSTYPE 判定可用。
- Apple 自带二进制（/usr/bin/*）hook 不了——LD_PRELOAD 族共同硬约束。
- tor4 需在跑；本网络引导问题见坑 #6（obfs4proxy 升级触发条件）。
- 预期内的"异常"：`.onion`/被拒调用打 WARN 日志（默认 level）；
  `torsocks show` 永远可用（只读环境变量），适合上机冒烟。

## 5. 相关文件

| 文件 | 内容 |
|---|---|
| `net/torsocks/build.sh` | 构建（三堵墙全文、config.h 生成、wrapper sed、门禁） |
| `net/torsocks/make-deb.sh` | 打包（布局、tor-ready conf、host+device 双签名） |
| `net/torsocks/patch-darwin.py` | 坑 #3 的 accept4 守卫补丁（幂等） |
| `net/torsocks/probe/` | **可行性探针**：最小 dylib+宿主、设备矩阵脚本与 2026-11-25 原始输出、E2E 服务器与记录 |
| `tests/torsocks.sh` | 上机验收（只读；上机前 SKIP） |
