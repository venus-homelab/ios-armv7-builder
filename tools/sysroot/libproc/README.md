# tools/sysroot/libproc/ -- lsof 的 Apple 头补包

iPhoneOS SDK 相比 macOS SDK 缺四件 lsof ≥4.80 Darwin dialect 要用的头。
这里放四件，`lsof/build.sh` 把它们叠到 SDK include 的合并树上：

| 文件 | 来源 | 性质 |
|---|---|---|
| `libproc.h` | 手写，仅函数声明 | 结构体/常量全部来自下面的 proc_info.h（历史上手声明 PROC_PIDTBSDINFO=4 是错的，内核值 3——这就是"内核 ABI 别手改"的出处） |
| `sys/proc_info.h` | **原文** `xnu-3789.70.16`（与设备内核 uname 精确匹配的 tag） | 内核 ABI，**勿手改** |
| `netinet/tcp_fsm.h` | 最小化重写，取值对照 xnu-3789.70.16 核验 | TCP 状态号 + `TCPSTATES` 下的状态名表（lsof ptti.c 打印用） |
| `netinet/tcp_timer.h` | 最小化重写，同上核验 | `TCPT_KEEP` 等 index（`tcp_sockinfo.tcpsi_timer[]` 下标） |

为何入库：audit-and-publish / single-build 的 collector 不装 toolchain，
白名单与头必须免工具链自给（同 `net-abi/`、`libcxx15-headers/` 的理由）。
