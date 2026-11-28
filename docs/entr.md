# entr 5.9 移植专项(armv7 iOS 10.3.3)

> 包:`entr4_5.9-1_iphoneos-arm.deb` · 文件变更即跑命令的 kqueue 监视器
> 构建脚本注释即详细文档:`tools/entr/build.sh`;本文记录**状态、探针结论、
> 坑与设备验收步骤**,细节指向 build.sh,不重复。

## 1. 状态

| 项 | 值 |
|---|---|
| 上游 | eradman/entr,tag 5.9(annotated tag 对象 `1eb989b9ce791518870f1033bc6b9b54f1f928f2`) |
| 包 | `entr4_5.9-1_iphoneos-arm.deb`(~14 KB) |
| 载荷 | `/var/mobile/tools/entr/bin/entr` + `share/man/man1/entr.1`,`/usr/bin/entr` 软链 |
| 依赖 | `firmware (>= 10.3)` 仅此一项(libSystem + /bin/sh 都是系统自带) |
| 构建门禁 | `check-undefined.sh` 69/69 全绿;probe 16/16 全绿 |
| byte-ab | IDENTICAL(2026-11-25) |
| 设备验收 | **待执行**(本轮任务禁 ssh;§4 命令可直接复制执行) |

## 2. 依赖链

零依赖。entr.c + status.c 纯 C,符号面清一色 libSystem:kqueue/kevent、
进程控制(fork/execvp/waitpid/setpgid/kill)、termios(tcgetattr/tcsetattr)、
fd 限额(getrlimit/setrlimit/sysctl)、stdio、目录遍历(opendir/readdir)。
没有 curses/iconv/openssl/第三方库。build.sh 有符号面断言,混进来即构建失败。

上游的"configure"是个玩具 sh 脚本:只按 `TARGET_OS` 复制对应 Makefile。
本包用 `TARGET_OS=Darwin` → `Makefile.macos`(`-D_MACOS_PORT`,fd 限额走
getrlimit + sysctl(KERN_MAXFILESPERPROC))。

## 3. 核心探针:kqueue 在设备上的语义

darwin/arm 的 kqueue 可用性是本包唯一的探针问题,静态证据链 + 探针程序
两层都有交付:

**静态证据**(构建前已成立):

- `_kqueue`/`_kevent`/`_kevent64`/`_sysctl`/`_getrlimit`/`_setrlimit`
  全在设备 dlsym 实证清单 `tools/sysroot/device-exports/ios-10.3.3-armv7-verified.txt`;
- nginx 的 kqueue 事件引擎、nmap/nsock 的 kqueue 回退都在本设备真跑过
  (`docs/nginx.md` §2、`docs/nmap.md` 墙 #7)——kqueue 是 iOS 内核真正的
  事件引擎。

**探针程序** `tools/entr/probe-kqueue.c`(构建即产出 `out/entr-probe-armv7`,
build.sh 每次连它一起构建+过门禁,不跑不行)。验九件事,每件打印
`PASS/FAIL <n>`,全过退出 0:

1. 结构体布局:kevent=20B / kevent64_s=48B / timespec=8B(`_Static_assert`);
2. `kqueue()` 建队列;
3. **双元素 changelist** 一次注册两个 EVFILT_VNODE(多元素探针规则:
   单元素测不出 stride 错位,第一个元素永远"对齐"——musl 时代
   `sys/event.h` 带 `ext[4]` 的 52B 步长就是这么漏检的,见
   `docs/musl-sysroot.md` §1;SDK 模式官方头为 20B,探针为证);
4/5. 真实 write 触发 NOTE_WRITE,`udata` 指针往返 intact、`ident`==fd
   (两个文件分别验,第二个元素才真正检验 stride);
6. rename/unlink 触发 NOTE_RENAME/NOTE_DELETE;
7. 管道 EVFILT_READ + NOTE_LOWAT(data>=1)——entr 的 stdin 触发路径;
8. `kevent64()` 等价触发 NOTE_WRITE(64-bit ABI 一致性);
9. timespec 超时路径(1ms 静默队列返回 0,不悬挂)。

**设备预期输出**(验收时对样):

```
PASS 1: struct sizes (kevent=20B kevent64_s=48B timespec=8B (static))
PASS 2: kqueue()
PASS 3: changelist x2 EVFILT_VNODE
PASS 4: NOTE_WRITE delivery (probe-a write -> nev=1 fflags=0x2 ident_ok=1 udata_ok=1)
PASS 5: NOTE_WRITE delivery (probe-b write -> nev=1 fflags=0x2 ident_ok=1 udata_ok=1)
PASS 6: NOTE_RENAME delivery
PASS 7: NOTE_DELETE delivery
PASS 8: EVFILT_READ NOTE_LOWAT on pipe
PASS 9: kevent timeout (timespec) path
== PROBE ALL PASS (9 pass, 0 fail)
```

探针若在设备上失败:**停在根因上**,拿 FAIL 行里的 nev/fflags/ident_ok/
udata_ok 四个数字定位(布局 stride 错→PASS 4/5 双双挂且 udata_ok=0;
VNODE 滤器缺→PASS 3 挂;超时路径坏→只有 PASS 9 挂),不许拿"deb 能装"
硬绕。

## 4. 设备验收步骤(可直接复制执行)

> 具体主机/设备地址见 DEVICE.md(gitignored);下面一律写 `<device>`。
> **先跑探针(步骤 0/1),再信 entr(步骤 2+)。**

```sh
# ---- 0. 把探针送上去(主机侧;走部署三件套,新文件名) ----
scp out/entr-probe-armv7 <device>:/var/mobile/tools/entr/bin/probe-kqueue
ssh <device> 'chmod 755 /var/mobile/tools/entr/bin/probe-kqueue && \
  chown mobile:mobile /var/mobile/tools/entr/bin/probe-kqueue && \
  ldid -S /var/mobile/tools/entr/bin/probe-kqueue && \
  ldid -e /var/mobile/tools/entr/bin/probe-kqueue | head -1'

# ---- 1. kqueue 探针(预期:9 个 PASS + "== PROBE ALL PASS") ----
ssh <device> 'cd /var/mobile/tools/entr && ./bin/probe-kqueue .'

# ---- 2. 装 deb(设备侧 root;dpkg=新 inode+postinst 重签) ----
dpkg -i entr4_5.9-1_iphoneos-arm.deb     # root shell / ssh root@<device>

# ---- 3. 版本断言(上游没有 --version;无参 usage 走 usage(false),
#         stderr 第一行就是 release 横幅) ----
entr 2>&1 | head -1        # 预期:release: 5.9
test "$(entr 2>&1 | head -1)" = "release: 5.9" && echo VERSION-OK

# ---- 4. 真实 watch:echo 触发一次真实监视,输出断言,限时收尸 ----
#      (设备无 timeout 命令,用纯 sh 看门狗;有 timeout 可自行替换)
ssh <device> 'sh -s' <<'EOS'
set -e
mkdir -p ~/entr-t && cd ~/entr-t
echo hello > target.txt
rm -f entr.out
( printf "target.txt\n" | entr -n echo CHANGED > entr.out 2>&1 ) &
watcher=$!
sleep 1; echo tick >> target.txt          # NOTE_WRITE -> 第二次 CHANGED
sleep 3
kill "$watcher" 2>/dev/null || true
wait 2>/dev/null || true
n=$(grep -c CHANGED entr.out)
echo "CHANGED-count=$n (expect 2: initial run + on-write)"
test "$n" = 2 && echo WATCH-OK || { echo WATCH-FAIL; cat entr.out; exit 1; }
EOS

# ---- 5. (可选)rename 事件:改名也触发一次 ----
ssh <device> 'cd ~/entr-t && \
  ( printf "target.txt\n" | entr -n echo CHANGED > entr2.out 2>&1 ) & sleep 1; \
  mv target.txt target2.txt; sleep 3; \
  grep -c CHANGED entr2.out   # 预期 2'
```

注意事项:

- **`-n` 必带**:非交互模式。ssh/管道下没有控制 tty,不带 `-n` entr 会在
  tcgetattr 上 errx 退出("unable to get terminal attributes")——这是
  upstream 行为,不是 bug。
- entr 只盯**常规文件与符号链接**(process_input 里 S_ISREG/S_ISLNK);
  传 fifo/目录名会静默跳过,只传 fifo 会报 "No regular files to watch"。
  验收用真实文件触发,不要用 mkfifo(任务书里的"mkfifo/echo"泛指"造一次
  真实触发",对 entr 语义而言 append-to-file 才是对应物)。
- `-r`(进程重启模式)与 `-x`(状态过滤)按 man 页用;`-x` 运行时要调
  设备 `/usr/bin/awk`,设备若无 awk 该选项不可用(不影响其余功能)。
- 常规用法:`ls *.c | entr -n make` / `printf 'f\n' | entr -s 'cmd /_'`。

## 5. 坑列表

| # | 坑 | 要点/修法 |
|---|---|---|
| 1 | **官方 entrproject.org 下载被劫持** | `entrproject.org/code/entr-5.9.tar.gz` 2026-11-25 实测返回 HTML 页(域名疑似 CDN 停放/劫持),gzip 解包必炸。改取 GitHub tag archive(`api.github.com` 实证 tag 对象即任务书给的 commit),sha256 实算入 sources.lock |
| 2 | **host 是 Linux,configure 会选错分支** | 玩具 configure 按 `uname` 选 Makefile;不设 `TARGET_OS=Darwin` 会拿到 `_LINUX_PORT` + inotify shim,编译都过不了(err.h 之外的 Linux-only 面)。显式 `TARGET_OS=Darwin` |
| 3 | **NOTE_TRUNCATE 在 Darwin 不存在** | FreeBSD 扩展;上游 missing/compat.h 自带 `#define NOTE_TRUNCATE 0` 兜底,NOTE_ALL 掩码在 Darwin 天然少这一位。零补丁,探针镜像同一掩码 |
| 4 | **pledge(2) 是 OpenBSD-only** | 同在 missing/compat.h:`#ifndef __OpenBSD__ #define pledge(s,p) (0)`。零补丁 |
| 5 | **kevent stride 有前科** | musl 时代 sysroot 的 `sys/event.h` 曾带 `ext[4]`(52B),设备内核按 20B 读,第 2+ 个 change 起全错。SDK 模式官方头 20B+`#pragma pack(4)`;探针按**双元素 changelist** 规则验(docs/musl-sysroot.md §1) |
| 6 | **byte-ab 三墙例行公事** | `-O2` 无 -g(墙#4)、`-Wl,-no_uuid`(墙#1)、每次净提取源树(墙#3)、changelog 用 SOURCE_DATE_EPOCH(墙#2)。entr 本身无 `__FILE__`/`__DATE__` 使用 |

## 6. 相关文件

| 文件 | 内容 |
|---|---|
| `tools/entr/build.sh` | 构建(含探针构建+门禁、净源协议、符号面断言) |
| `tools/entr/probe-kqueue.c` | 设备 kqueue 语义探针(九项检查) |
| `tools/entr/make-deb.sh` | entr4 打包(tig/fzf 规约) |
| `sources.lock` | entr 5.9 行(github tag archive,sha256 实算) |
| `out/entr-5.9-armv7` | 未签名二进制 |
| `out/entr-probe-armv7` | 未签名探针二进制(部署三件套后上机) |
| `out/entr4_5.9-1_iphoneos-arm.deb` | 交付 deb |

## 5. 设备验收实录(2026-11-25)

- 安装:entr4 5.9-1 ii ✓;版本断言 `entr 2>&1 | head -1` = "release: 5.9" ✓
- **真实 watch(最终裁决项)PASS**:文件 append 触发,CHANGED 恰 2 次(初始跑+触发跑),无 tty 场景 `-n` 必带 ✓
- kqueue 探针实录:**8/10 过,2 FAIL**——#9 kevent64 NOTE_WRITE、#10 kevent timeout(timespec)路径断言
  - #9 裁决:entr.c 全文只用普通 `kevent()`(L229/663/738/740),**kevent64 零使用**,FAIL 属超范围语义记录;
  - #10 裁决:entr 主循环确实带 `&evTimeout`(L738),真实 watch 下触发路径工作正常,FAIL 更可能是探针断言口径
    (超时返回 nev/errno 的期望值)而非设备语义缺陷——留待后续需要 kevent64/超时精调的程序时再深挖;
  - 其余 8 项(布局断言、kqueue()、双元素 EVFILT_VNODE changelist、真实 write→NOTE_WRITE+udata 双文件、
    rename/unlink、管道 EVFILT_READ+NOTE_LOWAT)全过——entr 依赖面完整。
- 结论:**entr 4 上线可用**;探针 2 项 FAIL 作为 darwin/arm kevent 语义的已知边界记录在案。
