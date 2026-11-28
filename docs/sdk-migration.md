# musl → SDK 批量迁移(2026-11-21,大哥拍板"用 musl 的包都在 CI 上 SDK 打包")

> 方法:本机 `tools/sdk-migrate-probe.sh <pkg>` 逐包 SDK 试构建
> (env:SDK 三件套 + OSSL 留存树),过墙 → CI 全链验证 → bump rev 打包。
> 通用坑模式见 `docs/toolchain.md` §23 与 `docs/curl.md` §7。

## 状态

| 包 | 状态 | 备注 |
|---|---|---|
| curl | ✅ SDK 已上线(8.16.0-6) | 见 docs/curl.md §7 |
| quickjs | ✅ 生来 SDK | docs/quickjs.md |
| ca-certificates4 | ✅ 数据包 | |
| whois | ✅ CI 绿(金丝雀 1) | 源 fetch 化 + _XOPEN_SOURCE 700 补丁 |
| rsync | ✅ CI 绿(金丝雀 2) | 源 fetch 化;12 符号 dlsym 实测入白名单 |
| make | ✅ **CI 绿** | 源 fetch 化;os-compat.h 探针预置 ac_cv_c_undeclared_builtin_options |
| openssl | ✅ **CI 绿** | env SDK 化(CROSS_TOP/SDKs 链接形);atomic_compat 撤销(dlsym 推翻旧结论) |
| p7zip | ✅ **CI 绿** | 曾死:~/scratch 老树+CXX 旧 wrapper 路径;已 fetch-src 自含。打包 rev bump 待做 |
| sqlite | ✅ **CI 绿** | 曾死:llvm-ar-21 straggler + stage-only 无 out/ 产物(gate 空 glob exit 2);已 darwin-ar + out/ 约定 |
| jq | ✅ **CI 绿** | HAVE_POW10 修复改打 Makefile DEFS(1.7.1 无 config.h);out/ 产物 + darwin-ar 已清 |
| tcpdump | ✅ **CI 绿** | 曾死:env landmine;libpcap 打通后一次过 |
| libpcap | ✅ 本机绿(墙倒) | BIOCSETIF 探针只认 CPPFLAGS;Makefile 用自有 INCLS(-I.)不被 CPPFLAGS 影响——make 行覆盖 INCLS。xnu bpf.h ABI 目录已就位;llvm-ar-21 straggler 已清 |
| nmap | ✅ **CI 复验中**(本地绿) | 每轮从缓存 tarball 重提净树;BSD net 头家族(xnu if_arp/route/if_ether/if_types)入 tools/sysroot/net-abi;LIBPCAPDIR 硬指 tarball 自带 pcap(--with-libpcap 不生效)→ sed 指向我们的 BPF 树;首轮 make -k + repack(liblinear 成员跨两目录);libpcre 冻结 autotools 时间戳 |
| less | ✅ **CI 绿**(93/93) | 真墙机理:SDK 无 curses 头 → configure 探针 tgetent(0,0) 成隐式声明,新 clang 硬错误。修:CPPFLAGS→ncdu/devhdr(已提交的设备 ncurses5.7 头);链接用已提交设备 dylib(libncursesw.5.dylib,LC_LOAD_DYLIB 落地);_tgetent 族 7 符号 dlsym 入册 |
| dropbear | ✅ **CI 绿**(四产物) | 曾死于老源布局($HOME/ios-tool/dropbear-src 硬报错);已 fetch-src --lock 自含 + env 默认值内嵌。endian -D→OSSwap*+预包含;SVR_DROP_PRIVS=0+MULTIUSER=0(复刻生产形态:0 setres/getrandom 引用);getrandom/clearenv config.site fallback;**大哥已拍板:不部署(2026-11-22)——SDK 重构建产物仅存 CI artifact** |
| tor | ✅ **CI 绿**(257/257) | 自含:libevent(tmux 配方内联+event-config.h SDK 化:sendfile/in6/FD_MASK/arc4random 改名)+ openssl/zlib 自动先建;environ 回退(SDK 无 crt_externs.h);readpassphrase 解禁(SDK 实有);c8fixed shim 入链接;设备全符号探针 DEV 门控 |
| vim | ✅ **CI 绿** | ncdu/devhdr 路线(已提交设备头+dylib);--disable-xattr(Apple xattr 原型带 options/position,musl 形调用本就是潜伏坏);LLVM_AR-21 死导出已清;源 fetch 进 tmp/src |
| git | ✅ **CI 绿**(gate 巡检 out/git-2.51.2-armv7) | SDK 迁移五修:curl/openssl 自动先建;zlib 镜像到 lib/(-lz 已不再被 cc-wrapper 丢弃);EXTLIBS 补 curl 8.16.0-6 静态闭包(nghttp2/brotli/zstd/c8fixed shim);imap-send 从 Makefile 摘除(2.51.2 无条件入 PROGRAM_OBJS,install: all 会编它);链接目标先 rm(GIT-LDFLAGS 不跟踪 EXTLIBS,闭包改动不触发重链) |
| node | ⏳ 用户拍板跳过 | "node太复杂了 先跳过吧" |
| openssh | ✅ **CI 绿**(八产物) | ppoll/setres python 补丁;utimensat compat;is_lock_free 链入 sshd;__res(_res 数据符号)+ 9 libc 符号 dlsym 入册;--with-sandbox=no(生产同形);**不部署(2026-11-22)** |
| mosh | ✅ **CI 绿** | 净树化(暖树 CXX 127);devhdr 头+IOS_DYLIBS(vim 路线);-D_DARWIN_C_SOURCE(IP_TOS/NI_MAXHOST 被 POSIX 宏藏);darwin-ar repack;c8fixed shim;host protoc + protobuf-cpp 3.20.3 头目录布局;**不部署(2026-11-22)** |
| lsof | ⏳ env 已 SDK 化 | 下一墙:自带 ./Configure -n darwin 静默退出(LSOF_VSTR=16.7.0 硬编码;dlsof.h/machine.h 补丁链已跑);需摸 Configure 内部 |
| class-dump | ✅ **CI 绿** | SDK env;源走 lock(全 sha 目录名动态发现);Framework tbd 拷贝+门禁 glob 均随 IOS_STUBDIR;ObjC 类符号(_OBJC_CLASS_/METACLASS)由运行时元数据绑定,门禁豁免(tbd 从不列 ObjC 符号) |

## curl 依赖链的 CI 专项(2026-11-21 深夜)

- **CI 单跑架构已落地**(大哥方案):build.yaml(reusable,inputs.package)+
  build.yaml(reusable)+ single-build.yaml(单包手触);full-build.yaml 与
  nightly.yml 已于 2026-11-25 删除(全仓审计改走本地 gate-local);
  curl/build.sh 自含 openssl 依赖(matrix 无序)。
- 首轮 matrix:whois ✅ rsync ✅ openssl 构建 ✅(门禁差 10 符号,已
  dlsym 实测入册);curl 差最后一墙:**CI 上 curl 的 vtls/openssl.c 编译
  报 asn1_string_st 不完整(opaque/头配置差异),本机同源同命令过**——
  怀疑点:CI 新 Configure 生成的 configuration 头 vs 本机留存树旧头、
  或系统 /usr/include/openssl 污染;待取证(make 命令行 dump)。
- openssl 的 atomic_compat 已撤销(dlsym 证明设备 libSystem 有全套
  __atomic_* helper——当年"设备缺"的结论被实测推翻)。

- **nghttp2 autotools → cmake**:本机过、CI 的 conftest 探测必死且
  config.log 拒绝展示原因(三轮 dump 无果)→ 换 brotli 同款 cmake 交叉
  (要点:`BUILD_STATIC_LIBS=ON` 必须显式——其 ALIAS 假设 static 目标
  存在,只给 BUILD_SHARED_LIBS=OFF 会让 ALIAS 悬空报错)。
- **openssl 的 atomic_compat 撤销**:dlsym 实测设备 libSystem **有**全套
  __atomic_* runtime helper(当年"设备缺"的结论错了);compat 的
  alias 桩(.word 长跳)也被现代 ld64 的 PIE text-relocation 拒绝。
  compat 文件保留作墙记录,链接不再引用。
- **教训强化**:本机"过"≠CI"过"——本机留存树的旧对象会让增量构建
  跳过重编(假绿);每包过墙必须以 CI 干净 runner 的真全量为准。

## 本日新墙记录(2026-11-22)

1. **注释插进续行链 = 静默换成宿主编译器(第三次:rsync、tor、openssh)**。
   `CC=... CFLAGS="..." \` 后面跟 `# 注释` 会把前缀赋值从命令上切下来:赋值
   变成独立语句(**不导出**),./configure 裸跑 → configure 探不到交叉 CC
   → 抓宿主 `cc` → 全程用 /usr/include 的宿主头,报一堆莫名其妙的
   "implicit declaration"/"No such file"。**症状特征**:错误信息里出现
   `/usr/include/...` 或 glibc/OpenSSL3 的 deprecation note;configure 输出
   `checking for cc... cc`。**检查手段**:看 configure 的 CC 解析行。
2. **LD64_LIBS 委托式默认的坑**:`LD_LIBRARY_PATH="${LD64_LIBS:-}:..."` 在
   调用方没设 LD64_LIBS 时等于把搜索路径清空,ld64 死于
   `libBlocksRuntime.so: cannot open shared object file`。自含默认
   `$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib` 已进
   openssh/dropbear/git/less 的 build.sh。CI 之所以不炸,是 build.yaml 的
   job env 兜底——**本地裸跑 build.sh 才是 env 自含的真考场**。
3. **git 的 Makefile 重链判定只跟踪 ALL_LDFLAGS,不跟踪 EXTLIBS**:只改
   config.mak 的归档闭包时 make 认为一切最新,连链接配方都不跑(canary5
   原样发了个字节级旧二进制)。改闭包必须先 `rm` 掉链接目标。
4. **非引用 heredoc(`<<MAK`)里反引号会执行宿主命令**:注释里写了
   `` `git` ``,宿主 git 的 usage 文本被直接注入 config.mak。heredoc 内
   禁止反引号与未转义 `$()`(现有 `\$(...)` 转义是有意的)。
5. **白名单流水线已是日常操作**:CI 报 UNRESOLVED → 抓全名单 →
   `tools/device-symprobe.sh <Mach-O 形符号>` dlsym 实测 → 全 OK 则
   append→commit→retrigger。openssh 本日两轮共补 10+4 符号;less 补 4。
   注意数据符号(_res)与 _chk 族都在 libSystem,而 curses 族要用**链了
   设备 dylib 的探针**才 dlsym 得到(dylib 不默认加载)。
6. **git 2.51.2 的 imap-send 无条件进 PROGRAM_OBJS**(旧版
   `ifndef NO_IMAP_SEND` 守卫被上游删除),`install: all` 会连坐编译它,
   撞 OpenSSL 4 opaque ASN1。修法:提取后 sed 掉那一行。旧的"绿色"是
   musl 时代残留 .o 掩盖的假绿。
7. **jq 1.7.1 根本没有 config.h**:所有探测答案以 `-D` 形式打在生成的
   Makefile 的 DEFS 行。旧的 HAVE_POW10 config.h-sed 只在 warm 树(残留
   musl 时代 config.h)上"管用",干净树上 sed 直接报错致死。修法:改
   strip Makefile DEFS 里的 `-DHAVE_POW10=1`。
8. **build.yaml gate 依赖 out/<artifact>-armv7 仓库约定**:只 stage 不产
   out/ 产物的包(git、sqlite)在 CI 上要么 gate 的空 glob 直接 exit 2
   (sqlite),要么 gate 错误地检查了 out/ 里别的包的产物(git 第一轮捞到
   curl 的产物,"假绿")。两包已补 out/ 产物;新包接入 matrix 前自查。
9. **cxx-wrapper.sh exec 的是旧项目树($HOME/ios-tmux-builder)的
   cc-wrapper**:本地有旧树所以从不出事,CI 干净 runner 上每个 C++ 端口
   必死 127。已改为解析自身目录。libcxx15-headers(LLVM15 libc++,8MB)
   已入库 tools/sysroot/,bootstrap stage4 自动安装(原来是 NOTE 让人手拷)。
10. **p7zip 的 CXX 同类旧路径**($HOME/ios-tool/cxx-wrapper.sh)。
11. **设备 libSystem 连 C++ typeinfo(_ZTI*)都直接 dlsym 得到**
    (libc++abi 在共享缓存且 RTLD_DEFAULT 平坦查找可见)——p7zip 的
    __ZTIPKc/__ZTIPKw 7 符号一次入册。
12. **collector 是裸 runner,审计白名单必须免 toolchain 自给**:audit-and-
    publish 不装 toolchain(也不吃缓存),/opt/ios-tool 不存在——class-dump
    的 ObjC/CF/CC/NX/blocks 36 符号在包 gate 全绿、collector gate 全挂。
    修法:SDK 权威 tbd 六件(267KB)入库 tools/sysroot/tbd/,check-undefined
    加这个来源;上线前用"全新 clone + 假 HOME"模拟 collector 裸环境跑
    全量 34 产物(34/34)再触发。
13. **per-package gate 只审主产物 = 漏审洞**:build.yaml gate 原来只
    check 一个 `ls -t | head -1` 的二进制——dropbear 的 dbclient/dropbear/
    dropbearkey 从没被审过,里面藏着 `_memset_s`(设备 libsystem_c 实有,
    dlsym 入册)。已改为审计 out/ 全部 *-armv7,out/ 为空直接 fail。
14. **git 文件模式也是 CI 依赖**:scripts/publish-gh-pages.sh 入库时是
    100644,collector 直接执行 → exit 126(Permission denied)。且
    `git update-index --chmod=+x` 不改工作区文件,下一次内容修改 +
    git add 会把 mode 冲回去——**chmod +x 磁盘文件再 git add**,否则
    修复会在下一轮自我回滚(publish 两连 126 的根因)。
15. **single-build 发布路径(2026-11-22 起 = 默认)**:build job 绿后
    publish job 下载 artifact → gh-pages 存量池 cp -n 合并 → make-repo
    签名 → force-push。新 deb 赢的前提是 **rev 已 bump**(同文件名
    cp -n 不覆盖)。
16. **zsh 5.9 的三面墙**:configure 探测谎言 ×7(逐个设备 dlsym 后
    ac_cv 预置);设备无 libiconv.2.dylib → 静态编 GNU libiconv,但
    GNU ar 归档 ld64 拒收 → darwin-ar 重打,且**归档注入必须在
    configure 期**(post-make 的 Makefile 改动被 Makemod 再生成冲掉);
    `___mb_cur_max_l`(SDK MB_CUR_MAX_L 宏指向)设备缺失 →
    libios-compat.a 优雅降级桩。lua 5.4.7 反而是全仓最易移植
    (无 configure 纯 C89,唯一坑 = guess 目标选宿主配方 → generic)。

## CI 侧(full-build.yaml,2026-11-22 现状)

- 三层架构:build.yaml(reusable,inputs.package)/ full-build.yaml
  (19 包 matrix + audit-and-publish collector)/ single-build.yaml(单包手触)
- toolchain 缓存:actions/cache@v4 打 /opt/ios-tool(~137MB),key=
  ios-toolchain-<SDK commit>-<bootstrap hash>;stage-0 apt 永跑,bootstrap
  仅 miss 时跑,smoke --force 永远验证(restore 路径也被测过)
- collector:下载 19 包 artifact → 合并 out/ → audit gate(全产物)→
  **存量池合并**(gh-pages 旧 deb cp -n 回 out/,防发布刮包)→
  make-repo → publish-gh-pages(需 permissions: contents: write)。
  **首发完成 2026-11-22:43 包在线**(旧包零丢失,新包全进场);
  调通过程三条墙记在「本日新墙记录」12–14 + PUBLISH_URL(git-init
  裸目录无凭据,workflow 传带 token 的推送 URL)。
- dropbear/openssh/mosh 的 SDK 重构建产物**仅存 artifact,不部署设备**
  (大哥拍板 2026-11-22)
- lsof 未入 matrix:自带 ./Configure -n darwin 静默退出(LSOF_VSTR 硬
  编码),env 已 SDK 化,待摸 Configure 内部

## 已固化工具

- `tools/sdk-migrate-probe.sh <pkg>`:单包 SDK 试构建 + 门禁
- `tools/device-symprobe.sh [--dry] <sym>...`:设备 dlsym 实测 → 白名单
  (rsync 的 12 个 libc/_chk/ctype 符号即此法入册)
