# w 1.0 移植专项（armv7 iOS 10.3.3）

> 包：`w4_1.0-1_iphoneos-arm.deb` · **自研单文件**（无上游二进制依赖）；
> 2026-11-28 部署设备并验收：header 与 stock uptime 逐字节一致、
> tests/w.sh 3 PASS + 1 SKIP（设备当时无登录会话）、dpkg -V 全净
> 构建脚本注释即详细文档：`tools/w/build.sh` / `tools/w/w.c` 头注释
> 本文记录**状态、数据源事实、格式决策、坑与结论**。

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | 1.0（自研，argv[0] 分流 w/uptime） |
| 包名 | `w4_1.0-1_iphoneos-arm.deb` |
| 安装路径 | **只装 `/usr/bin/w`** |
| 验收 | ✅ 设备实测：header 与 stock `/usr/bin/uptime` **逐字节一致**（A/B）；符号门禁 25/25；tests/w.sh 3 PASS + 1 SKIP（SKIP=当时无 utmpx 登录会话，非缺陷）；dpkg -V 全净 |

**为什么只装 w**：设备实测（2026-11-28）没有 `/usr/bin/w`——移植有正当性；
但 stock `/usr/bin/uptime`、`/usr/bin/who` 都在且能用（iOS 9 时代
adv_cmds 二进制），不制造影子二进制。二进制内保留 `uptime` 分流名
（pgrep/pkill 先例）仅供本地/测试使用。

## 2. 数据源（全部设备探针实证，`tools/probes/probe-w.c`）

| 数据 | 来源 | 设备证据（2026-11-28 探针） |
|---|---|---|
| 开机时刻 | `sysctl(KERN_BOOTTIME)` | boot=1795841154 与 utmpx BOOT_TIME 记录吻合 |
| 负载 | **`getloadavg(3)`** | 在 `tools/sysroot/device-exports/ios-10.3.3-armv7-verified.txt` 已验证导出；探针实测 `{CTL_VM,VM_LOADAVG}` 裸 mib 返回垃圾（fscale=0），**禁用** |
| 登录名单 | `getutxent()` 族 | utmpx API 由 openssh 移植期证实导出（`net/openssh/ios-config.site`）；设备 `/var/run/utmpx` 644 root:daemon 存在 |
| 进程表 | `sysctl(KERN_PROC_ALL)` | pgrep 同款两阶段读取 |
| 前台命令 | `KERN_PROCARGS2`（3 元 mib） | 同 uid 实测 argv/envp 布局正确（pgrep 1.1 修复形态） |
| tty 空闲 | `stat(/dev/<ut_line>).st_atime` | 经典 BSD 源；探针确认无 `/dev/ttysNNN` 节点（无 pty 时） |

### utmpx 的设备现实（决定 `w` 什么时候有行）

- `/var/run/utmpx` 平时**只有一条 BOOT_TIME 记录**（type=2，tv=boot）。
- **dropbear(22) 不写登录记录**；openssh(22226) 对**非交互 exec 会话也
  不写**（探针两次实测 mtime 不变、`tty: not a tty`）。
- **交互式 pty 登录才产生 USER_PROCESS 行 → `w` 出现登录行**——此路径
  2026-11-28 已设备闭环：openssh4 10.6p2-6 修复 pty 崩溃（见
  docs/openssh.md）后，`ssh -tt` 登录即写 utmpx（1256→2512 字节），
  `w` 打出完整登录行（mobile s0 <host> 18:00pm 0 sh -c ...），WHAT 列
  同 uid 全参可读，tests/w.sh 4/4 全绿。

## 3. 坑列表

| 坑 | 要点/修法 |
|---|---|
| `VM_LOADAVG` 裸 mib 恒垃圾 | xnu-3789 上 `{CTL_VM,VM_LOADAVG}` 返回 fscale=0 的乱值；改 `getloadavg(3)`（已验证导出）。**别按 macOS 直觉走裸 mib** |
| `devname(3)` 不导出 | device-symprobe 实测不在设备 dylib；tty 设备号匹配改为直接 `stat(/dev/<ut_line>)` 比对 `st_rdev` |
| PROCARGS2 的 envp 泄漏 | 缓冲布局 = argc + exec_path + NUL padding + **argc 个** argv 串 + envp；必须按 argc 计数拼 argv，否则环境变量冒充命令行（探针 [5] 实录） |
| OpenBSD 的 +30s 进位 | stock uptime 是**截断**不是进位——带上 +30s 后 w 与 stock 一半概率差 1 分钟，tests/w.sh 逐字节比对会闪红；弃进位保 oracle |
| <1 天 uptime 恒为 H:MM | stock 在 43 分钟时打 **"up   0:43"**（不是 "43 mins"！）——OpenBSD 的 mins/hrs 分支在 Apple 版不存在；<1 天一律 `up %3ld:%02ld`，>1 天沿用 OpenBSD "N day(s), H:MM"（设备尚未观测到该分支） |
| 时钟是 24h + 小写 am/pm | stock 输出 `" 14:28pm"`（**%3d 宽度**，单数字小时补两个空格）；不是 OpenBSD 的 `%l:%M%p`（12h 大写） |
| postinst 重签制造 dpkg -V 漂移 | 构建期已签的二进制，deb 里再放 postinst 跑 `ldid -S` 会改字节 → `dpkg -V w4` 永远报 5；dpkg 全新安装本就是新 inode（签名随字节走，天然免疫），**postinst 直接删掉**，dpkg -V 全净 |
| IDLE 列自带间隔 | OpenBSD 的 IDLE piece（`"    %2ld "` 等共 5 种）**前后空格自含**，行 printf 不得再加分隔符，否则 WHAT 从 44 列漂到 45 列 |
| 交叉 uid 读 argv 失败 | mobile 只能读同 uid 进程全参（`docs/pgrep.md` §3）；跨 uid 回退 p_comm（OpenBSD `kvm_getargv()==NULL` 同形语义） |
| proc_compare 不可移植 | Darwin kinfo_proc 不导出 `p_estcpu/p_slptime`；择优简化为"前台进程组内最小 pid"，文档如实记录差异 |

## 4. 格式决策（两条线，各有权威）

1. **header = 设备 stock uptime**（Apple adv_cmds 血统，活体 oracle）：
   ` 14:28pm  up   1:42,  0 users,  load average: 0.84, 4.87, 6.36`
   ——tests/w.sh 把 `w | head -1` 与 `/usr/bin/uptime` 逐字节比对。
   "load average" 恒为单数（Apple 风格），非 OpenBSD 的 "load averages"。
2. **登录行 = OpenBSD usr.bin/w w.c 1.70**（源码逐串核对，2026-11-28；
   Apple 自家 w 源码在 adv_cmds 各 tag 均 404，无从对照）：
   `USER    TTY FROM              LOGIN@  IDLE WHAT`（47 字符，WHAT 从
   44 列起）；TTY 去 `tty` 前缀（ttys001→s001）；USER/FROM 截 8/16；
   LOGIN@ 今天 `%H:%Mpm` / 本周 `%a%I%p`（小写化）/ 更早 `%d%b%y`；
   IDLE 分钟 / `H:MM` / `Ndays`（无 "old"）；WHAT = 前台进程组
   （e_pgid == e_tpgid）完整 argv，取不到显示 `-`。

## 5. 设备侧用法

```sh
w                 # header + 登录行（pty 会话才有行，见 §2）
uptime            # stock 自带；w 的 header 与其逐字节一致
```

- 2026-11-28 已 dpkg 安装（deb 无 postinst，二进制构建期已签；
  /usr/bin/w 设备原不存在，全新安装无覆盖场景）。
- 已知预期行为：非交互 ssh exec 跑 `w` 永远 0 users（utmpx 无记录），
  不是 bug。

## 6. 待办

- [x] 交互 pty 会话实测登录行 + WHAT 列——2026-11-28 随 openssh4
      10.6p2-6（pty 崩溃修复）闭环，tests/w.sh 4/4
- [ ] make-repo 进池发布（与部署均需大哥拍板；w 部署与 ossh 修复部署
      2026-11-28 已完成）

## 7. 相关文件与排障副产品

| 文件 | 作用 |
|---|---|
| `tools/w/w.c` | 实现（头注释含全部数据源依据与格式出处） |
| `tools/w/build.sh` / `make-deb.sh` | 构建（w+uptime 双产物）/ 打包（只装 w，无 postinst） |
| `tools/probes/probe-w.c` | 设备探针（utmpx/loadavg/ttys/PROCARGS2 五问） |
| `tests/w.sh` | 设备验收（header 对 stock oracle 逐字节） |

**排障副产品（2026-11-28，为大哥查 Insomnia 时发现并已修复）**：ossh
pty 交互会话曾 spawn 即死（`_setutent` 不在 iOS libSystem 导出表），
openssh4 10.6p2-6 修复——详见 docs/openssh.md「pty 会话崩溃」节。此
修复同时点亮了 w 登录行的端到端验证。
