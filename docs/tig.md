# tig 2.6.1 移植专项（armv7 iOS 10.3.3）

> 包：`tig4_2.6.1-1_iphoneos-arm.deb` · 构建完成，check-undefined 门禁 164/164 全绿，
> byte-ab 确定性自测 IDENTICAL；**设备验收待补**（由主 agent 按本文 §5 执行）。
> 构建脚本注释即详细文档：`tools/tig/build.sh`
> 本文记录**状态、依赖链、坑与设备验收步骤**。

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | 2.6.1（上游 tag tig-2.6.1，release tarball） |
| 包名 | `tig4_2.6.1-1_iphoneos-arm.deb`（DEBREV=1） |
| 安装路径 | `/var/mobile/tools/tig/tig` + `/var/mobile/tools/tig/etc/tigrc`，`/usr/bin/tig` 软链（postinst 建、prerm 清） |
| 动态依赖 | 仅 `/usr/lib/libSystem.B.dylib` + `/usr/lib/libncursesw.5.dylib`（llvm-otool -L 实测两条） |
| 门禁 | check-undefined 164/164 全绿；byte-ab IDENTICAL（无 -no_uuid/-g0 压制旗标） |
| 运行时依赖 | **git（Depends: git4）**——tig 每个视图都 shell 出 git；terminfo 用设备 `/usr/share/terminfo` |

## 2. 依赖链

| 依赖 | 形态 | 说明 |
|---|---|---|
| ncursesw | 设备自有 | 头：入库的设备提取 ncurses 5.7 wide（`tools/ncdu/devhdr`）；库：入库的设备 dylib 显式上链接行（less 配方，见 `tools/less/build.sh`） |
| iconv | **静态内嵌** | GNU libiconv 1.17（sources.lock `libiconv` 行，与 zsh 共用）；设备没有 libiconv.2.dylib（zsh 实测），不能靠设备解析 |
| git | 设备 git4 | tig 运行期强依赖；只 shell 调用，无链接依赖 |
| readline/PCRE | 无 | `--without-readline`（设备无 libreadline，tig 的 prompt 有上游 fallback）、`--without-pcre` |
| wordexp/mkstemps | tig 自带 compat | 见 §3.4 |

## 3. 坑列表（现象 → 根因 → 处置）

### 3.1 PKG_CONFIG=/bin/false 直接让 configure 硬死

- **现象**：`checking pkg-config is at least version 0.9.0... no` →
  `configure: error: pkg-config not found`。
- **根因**：whois 的 `PKG_CONFIG=/bin/false` 防泄漏手法依赖 configure 对
  pkg-config **优雅降级**；tig 的 `AX_WITH_CURSES` 走 `PKG_PROG_PKG_CONFIG`，
  版本握手失败即把 `PKG_CONFIG` 置空并 `as_fn_error`（生成 configure 里是硬错误分支）。
- **处置**：build.sh 生成一个假 pkg-config（`tmp/tig-fake-pkg-config.sh`）：
  `--version/--atleast-pkgconfig-version` 退出 0 完成握手，其余查询退出 1 ——
  configure 于是走它**标准的 fallback 探针**（无头链接探测 → 选 `-lncursesw`），
  宿主 pkg-config 全程不参与，防泄漏目的不变。

### 3.2 iconv：configure 硬要求 + 设备没有 libiconv + 缓存种子反杀

- **现象**：第一轮 `configure: error: iconv() not found. Please install
  libiconv...`，且报 `(cached)` ——探针**根本没跑**。
- **根因**（三层）：
  1. tig 的 `AM_ICONV` 是**硬要求**（找不到直接 `AC_MSG_FAILURE`），不像多数包可关；
  2. cc-wrapper 的 `-undefined dynamic_lookup` 让"iconv in libc"探针**恒真**
     （toolchain.md §8），configure 永远走"libc iconv"分支、永远不发 `-liconv`——
     而 tig 若真用设备 libc 的 iconv，会以 flat-namespace 落空：设备
     **没有 libiconv.2.dylib**（zsh 移植时设备实测；SDK 的 `libiconv.2.tbd`
     只是门禁白名单制品，不是运行期文件，见 `lang/zsh/build.sh` 注释）；
  3. 想"种缓存逼它走 -liconv 分支"（`am_cv_func_iconv=no`）也不行——
     autoconf 把环境里的 `am_cv_*` 当**已缓存结果**，整个探针块被跳过，
     直接判"无 iconv"硬死。**ac_cv/am_cv 种子是双刃剑：种子=结论，不是暗示。**
- **处置**：种 `am_cv_func_iconv=yes`（跳过会撒谎的链接探针；HAVE_ICONV 为真——
  iconv 确实有，来自我们的静态档案），GNU libiconv 的 iconv.h 会把
  `iconv_open/iconv/iconv_close` 改名成 `libiconv_*` 三件套，链接行由 build.sh
  自己把重打包过的 `libiconv.a` 压到 config.make 的 `LDLIBS` 末尾；
  build.sh 第 6 步 `llvm-nm -u` 断言**零未定义 libiconv 符号**（静态确实吃进去了，
  `__libiconv_version` 为 D 型已验证）。capability 自述不可信——断言才是真门禁。

### 3.3 共享 libiconv 缓存带 -g：跨路径必 DIFFER（byte-ab 成员表定案）

- **现象**：首次 byte-ab DIFFER，成员表只有 `var/mobile/tools/tig/tig` 一个成员，
  且**尺寸差 40 KB**（A 1608192 > B 1567824）。
- **根因**：`tmp/iconv-prefix/lib/libiconv.a` 是 zsh 时代构建的共享缓存，
  当时 configure 没给 CFLAGS → autoconf 默认 `-g -O2`；ld64 链接时把 OSO stabs
  的路径**绝对化**（quickjs -g0 墙同款机理，docs/tig.md 当时未及记录的变体：
  这回藏在我方**复用的依赖库缓存**里，不在自家编译行上）。byte-ab 的 B 树
  tmp/ 是空的，按 build.sh 新配方（`CFLAGS="-O2"`）重建 → 无 stabs、小 40 KB。
- **处置**：`rm -rf tmp/iconv-prefix` 让 A 侧也按 -O2 重建；build.sh 的
  libiconv 段显式传 `CFLAGS="-O2"`（注释里写明缘由），任何环境首次构建即
  无 debug 信息，缓存复用与全新构建逐字节一致。**教训：byte-ab 前先清共享
  依赖缓存，或保证缓存的构建参数与配方一致。**
- **UUID 旁证**：whois 教训说"cctools ld64 每链随机 LC_UUID，要 `-Wl,-no_uuid`"，
  但 tig 同路径双链接实测**逐字节相同**（cmp = 0）——本机这套 ld64 未复现随机
  UUID，故**不加** `-no_uuid`；byte-ab 最终 IDENTICAL 是按实测拍的板。

### 3.4 wordexp/mkstemps：链接探针恒真 vs 设备白名单缺口

- **现象**：`AC_CHECK_FUNCS([wordexp mkstemps])` 全报 yes（dynamic_lookup 下
  链接探测恒真，toolchain.md §9），但 `_wordexp/_wordfree/_mkstemps` 不在
  任何入库 tbd 或 `device-exports/ios-10.3.3-armv7-verified.txt` 里。
- **根因**： configure 会"探测成功"但真机上这些调用落 flat-namespace；
  门禁会正确地标红——而**白名单不许绕**（也不该为 TUI 的波浪号展开去动设备清单）。
- **处置**：`ac_cv_func_wordexp=no` + `ac_cv_func_mkstemps=no`，让 tig 编进
  自带的 `compat/wordexp.c`/`compat/mkstemps.c`（compat_wordexp 只做 tilde
  展开，恰是 tig 对 wordexp 的唯一用法：io.c 用 `WRDE_NOCMD` 约束）。
  `setenv/strndup` 保留真实现（libSystem.tbd 与设备 verified 清单**双证**）。

### 3.5 curses 沿用 less 配方（记录性，非新墙）

- 头：`-I tools/ncdu/devhdr`（设备提取 ncurses 5.7 wide，`ncursesw/curses.h`
  探测通过 → tig 走 `HAVE_NCURSESW_CURSES_H`）。
- 链接：configure 把 `-lncursesw` 写进 config.make 的 `LDLIBS` 后，sed 换成
  入库设备 dylib `tools/ncdu/devhdr/libncursesw.5.dylib` → ld64 记录
  `LC_LOAD_DYLIB /usr/lib/libncursesw.5.dylib`（cc-wrapper 会把裸
  `-lncurses*` 丢弃，docs/less.md §2、docs/vim.md WALL 3）。
- 运行期 terminfo 来自设备 `/usr/share/terminfo`。

## 4. 构建配方（要点）

```sh
bash tools/tig/build.sh      # → out/tig-2.6.1-armv7（未签名），门禁内嵌
bash tools/tig/make-deb.sh   # → out/tig4_2.6.1-1_iphoneos-arm.deb（host ldid 预签）
bash tools/byte-ab.sh tools/tig   # 期望 IDENTICAL
```

- configure：`--host=armv7-apple-darwin --prefix=/var/mobile/tools/tig
  --without-readline --without-pcre`，`CFLAGS=-O2`（无 -g → 无 stabs 可绝对化），
  `CPPFLAGS=-I$DEVHDR -I$IPREFIX/include`。
- 只 `make src/tig`（`all` 会把 test-graph/doc-gen 也链成 armv7 死重）。
- `src/builtin-config.c` 由 `tools/make-builtin-config.sh`（宿主 sed）从 tigrc
  生成，无宿主工具链依赖。
- man 页不造：configure 的 asciidoc/xmlto 默认 `false`，`src/tig` 目标不碰文档。
- 打包规约同 fzf/git-lfs 金丝雀：staging 在 `$root/tmp`、SOURCE_DATE_EPOCH
  顶部 export、changelog `date -R -u -d "@…"`、host `ldid -S` + `ldid -e` 断言、
  postinst 设备重签、`-Zgzip --root-owner-group`。

## 5. 设备验收步骤（主 agent 执行；全程只读，符合 tests/ 纪律）

```sh
# 0. 传包上机（scp/dpkg 路径按既有部署习惯，本仓不入库）
dpkg -i tig4_2.6.1-1_iphoneos-arm.deb          # root；dpkg = 新 inode + postinst 重签

# 0.5 ★ 主机侧：_btowc 白名单缺口收口（裸 collector 唯一待办）
#   tig 的 string.h 把 isalnum/isdigit/... 重定义成 isw*(btowc(c))，二进制引用
#   _btowc；本机门禁经 $HOME/ios-tool/sdk-libsystem_c.tbd 放行，但该 tbd 不入库，
#   device-exports/verified 清单也没有它 —— 裸 collector 门禁会标 UNRESOLVED。
#   处置（porting-flow.md §5 纪律）：
#     tools/device-symprobe.sh _btowc        # 设备 dlsym 实测
#     OK → 脚本自动 append 进 verified 清单 → commit；MISS → 回 build.sh 解决
#   （不做这步则全仓审计会红——由本地 tools/gate-local.sh 承担；single-build 不受影响。）


# 1. 部署三件套断言
ls -l /var/mobile/tools/tig/tig                # 755 mobile:mobile
ldid -e /var/mobile/tools/tig/tig | head -1    # 有输出 = 已签名（无输出先 ldid -S）
otool -L /var/mobile/tools/tig/tig             # 期望两条：libSystem.B + libncursesw.5

# 2. 冒烟（无崩溃报告的 SIGKILL=先查签名，见 AGENTS.md 部署三件套）
/usr/bin/tig --version                         # 期望：tig version 2.6.1
/usr/bin/tig < /dev/null                       # 非 tty 启动应干净退出、不挂死

# 3. TUI 实测（在设备上任一 git 仓库内）
cd ~/somewhere/git-repo && tig                 # main/log 视图渲染，q 退出
#   - j/k 移动、Enter 看 diff、s 进 status、S stage 单文件（交互式 staging）
#   - 期望状态栏、分屏、着色正常（ncursesw + 设备 terminfo）
tig blame <file>                               # blame 视图
tig stash                                      # stash 视图

# 4. UTF-8 / 宽字符
#   含中文 commit message 的仓库：标题/正文不应出现乱码或错位（ncursesw 宽字符路径）
#   tig 的交互 prompt（: 命令行）应能输入（无 readline 的上游 fallback 路径）

# 5. 依赖与卸载路径
dpkg -l tig4                                   # ii 状态；Depends: git4（见下"注意"）
#   卸载/升级后 prerm 应已移除 /usr/bin/tig 软链（ls -l /usr/bin/tig 确认消失）
```

**注意（Depends: git4）**：包按任务钉的事实写 `Depends: git4`（设备已有 git4）。
本机池快照（`repo/dists/.../Packages`）里该包当前名为 `git`（无 git4 行）——
若设备 `dpkg -i` 因依赖名不满足而报错，按设备实际包名把 control 里的
`git4` 改成对应名字并 **bump DEBREV** 重发（发布铁律：control 字段变化必须升 rev）。

## 6. 相关文件

| 文件 | 作用 |
|---|---|
| `tools/tig/build.sh` | 构建（假 pkg-config、静态 libiconv、curses 换库、门禁与断言） |
| `tools/tig/make-deb.sh` | 打包（fzf/git-lfs 金丝雀规约） |
| `lang/zsh/build.sh` | 静态 libiconv 配方出处（设备无 libiconv.2.dylib 的证据链） |
| `tools/less/build.sh` | ncurses 设备 dylib 链接机制正本 |
| `docs/less.md` / `docs/vim.md` | curses 策略与 WALL 3 出处 |
| `sources.lock` | `tig 2.6.1` 行（sha256 取自下载字节）+ 复用 `libiconv 1.17` 行 |
