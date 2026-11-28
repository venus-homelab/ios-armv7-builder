# 新软件接入流程(build → 门禁 → 打包 → 文档 → 测试 → CI → 发布)

> 定位:**往本仓库接入一个新软件**的完整作业流程,按实际走过的路写。
> 每步指向仓库里真实存在的脚本与文档;跨包通用的坑已编号沉淀
> (`docs/toolchain.md` §、`docs/sdk-migration.md` 本日新墙记录 1–14),
> 本文只给流程与"每步必须满足什么",不重复展开坑机理。

## 0. 流程总览

| 步 | 做什么 | 产出 | 关键工具/命令 |
|---|---|---|---|
| 1 | 立项排期 | backlog 条目 + 用户拍板 | `docs/porting-backlog.md` |
| 2 | 源锁定 | `sources.lock` 新行 | `tools/fetch-src.sh --check` |
| 3 | 写 build.sh 并本地过 | `out/<artifact>-armv7` | `tools/sdk-migrate-probe.sh <pkg>` |
| 4 | 门禁白名单 | verified 符号清单 | `tools/device-symprobe.sh` |
| 5 | 推送前自检 | 干净的 diff | `tools/gate-local.sh` |
| 6 | 打包脚本 | `<pkg>/make-deb.sh` → `.deb` | `dpkg-deb` |
| 7 | 专项文档 | `docs/<pkg>.md` | 模板见 `docs/doc-conventions.md` |
| 8 | 设备验收 | `tests/<pkg>.sh` + REPORT | `tests/run-all.sh` |
| 9 | CI 单包验证 | 全绿 run | `single-build.yaml`(手触) |
| 10 | 进池发布 | gh-pages 仓库更新 | `single-build.yaml`(手触)或本地 `scripts/make-repo.sh` |
| 11 | 部署设备 | deb 上机 | **须用户拍板** |

## 1. 前置:工具链与本地环境(一次性)

- `tools/bootstrap-toolchain.sh` → `$HOME/ios-tool`:SDK、x-ld64、tapi、
  libdispatch、cc/cxx-wrapper、libSystem.tbd、libcxx15-headers。
  CI 同脚本(stage 0 apt 永跑,bootstrap 仅 cache miss 时跑)。
- 主机要 llvm 工具族(`llvm-nm`/`llvm-ar`/lldb-21);仓库 `tools/llvm-nm`、
  `tools/darwin-ar` 是封装,别直接调裸版本。
- 设备连接:ssh 别名走 `IPAD_HOST`(具体值见 `DEVICE.md`,gitignored)。
- **工作集禁 `/tmp`**(tmpfs:全局 8G,但 usrquota 每用户 ~1.1G 限额
  2026-11-25 实测;inode 上限已放宽到 4m——三层限制的分层诊断见
  `~/.dsh/AGENTS.md` 规则 0):构建树、源缓存一律放
  `tmp/`(gitignored)+ 显式 `TMPDIR`。

## 2. 立项:porting-backlog

1. `docs/porting-backlog.md` 加候选条目(动机/依赖链预判/风险)。
2. **大哥拍板**优先级与部署预期(上线 deb?还是仅 CI artifact?——
   dropbear/openssh/mosh 2026-11-22 起即"CI artifact only")。
3. 预判原则:依赖链能静态自含就自含;能 `--disable-*` 就 disable;
   C++ 软件先估 libc++ 头/ABI 负担;p7zip 有跨目录归档成员的坑。

## 3. 源锁定:sources.lock + fetch-src

1. `sources.lock` 加行:`pkg <TAB> version <TAB> url <TAB> sha256`
   (CI 强制校验;间接依赖如 zlib/openssl 也要有行)。
2. 无 release 的上游**照样可 pin**:指 commit tarball(whois 先例)。
3. build.sh 里只经 `tools/fetch-src.sh` 取源,不硬编码 url/sha:

   ```sh
   read -r U SHA _ <<<"$("$root/tools/fetch-src.sh" --lock <pkg>)"
   tarball="$("$root/tools/fetch-src.sh" <pkg> "$U" "$SHA")"
   ```

4. 下载缓存 `tmp/src-cache/`(gitignored,内容寻址;命中即零网络)。

## 4. build.sh(施工日志)

**契约**(CI gate 与 collector 都依赖):
- 产出 `out/<artifact>-armv7`(**未签名**二进制;out/ 为空 = gate fail);
- env 自含:SDK 三件套 + LD_LIBRARY_PATH 全部 `${VAR:-default}` 形态
  (裸跑 build.sh 必须成功,CI 只是兜底);
- 源自取(§3),交叉依赖库自建(openssl/zlib/libevent 有现成配方可抄)。

```sh
export IOS_SYSROOT="${IOS_SYSROOT:-$HOME/ios-tool/iPhoneOS10.3.sdk}"
export IOS_LD64="${IOS_LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}"
export IOS_STUBDIR="${IOS_STUBDIR:-$HOME/ios-tool}"
export LD_LIBRARY_PATH="$HOME/ios-tool/x-libdispatch/lib:$HOME/ios-tool/x-tapi/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

写脚本时的固定动作:
- `PKG_CONFIG=/bin/false`,防宿主 pkg-config 泄漏宿主 -I/-L;
- 归档统一 `tools/darwin-ar` 转格式(llvm-ar 系 straggler 也走它);
- 链接闭包 shim(c8fixed 等)sed 进**最后**一条 LIBS;
- **注释永远写在整条续行链上方**(插进链中 = 前缀赋值被切下、静默换宿主
  编译器,一年撞了四回);非引用 heredoc 禁反引号/未转义 `$()`;
- 暖树假绿:每轮从 tarball 重提净树,或改闭包后 `rm` 链接目标。

本地试构建:`tools/sdk-migrate-probe.sh <pkg>`(rc + gate 结果一行)。
细节坑表:`docs/sdk-migration.md`「本日新墙记录」。

**Go 包另有一套模板**:`source "$root/tools/go-env.sh"`(工具链自举 + 环境铁律
一行顶五包)+ `-trimpath` 显式上 build 行,完整门禁链见
`docs/go-app-template.md`——旗舰 tailscale/tailcat 漏了 -trimpath,被
byte-ab 抓成墙 #9(2026-11-25),别再抄老 build.sh。

## 5. 门禁:check-undefined + 白名单流水线

- 原理:cc-wrapper 用 `-undefined dynamic_lookup`,链接**恒真**;真闸是
  链后符号审计 `tools/check-undefined.sh`(每个未定义符号必须在白名单里)。
- 白名单来源:`tmp/stubs/*.tbd`、`${IOS_STUBDIR}/*.tbd`、`$HOME/ios-tool/*.tbd`、
  **入库的 `tools/sysroot/tbd/*.tbd`**、`tools/sysroot/device-exports/*.txt`。
- UNRESOLVED 处置(纪律,勿跳):
  1. `tools/device-symprobe.sh <sym>...` 设备 dlsym 实测;
  2. 全 OK → 自动 append 进 verified 清单 → commit → retrigger;
  3. MISS → 回 build.sh 解决(缺库/关特性),**不许绕闸**。
- 特殊家族:数据符号(`_res`)、`_chk` 族可 dlsym;curses 族要**链了设备
  dylib 的探针**;`_OBJC_*_$_*` 由运行时元数据绑定,gate 已豁免;
  `DARWIN_EXTSN` 裸标记 tbd 已覆盖。
- **collector 是裸 runner**(无 toolchain):白名单必须免工具链自给——
  这就是符号要进入库 tbd / verified 清单的原因。
- 推送前:`tools/gate-local.sh`(全仓 bash -n / shellcheck / lock 校验);
  大改动后用「全新 clone + 假 HOME」模拟 collector 裸环境跑全量产物。

## 6. 打包:make-deb.sh

- 什么时候写:软件要"装到设备用"才打包;纯构建树产物(如库)不写。
- 布局约定(以 `net/whois/make-deb.sh` 为模板):
  `/var/mobile/tools/<pkg>/` 放主二进制(root:wheel,host ldid -S 预签)+
  入口链接(`/var/mobile/tools/bin/` 或 `/usr/bin/`,prerm 里清)。
- control 必填:`Architecture: iphoneos-arm`;**Section / Depiction /
  Description 是 make-repo 元数据门禁的硬要求**,缺了发布直接 abort。
- 版本 `<upstream>-<rev>`:同一 upstream 重建 bump rev(newest-revision
  逻辑按它判定新旧)。
- postinst:设备侧重跑 `ldid -e` 验签;**凡 cp 覆盖既有已签名二进制,
  必须重 `ldid -S`**(dpkg 全新安装天然免疫)。
- 构建:`dpkg-deb --root-owner-group -Zgzip --build`;脚本会被 CI 直接
  执行,**入库必须可执行位**——`chmod +x` 磁盘文件再 `git add`。
  (只 `git update-index --chmod=+x` 不改工作区文件,下一次内容修改 +
  `git add` 会把 mode 改回 644——publish-gh-pages 126 连环两轮的根因。)
- **载荷可复现性验收**:`tools/byte-ab.sh <cat/pkg>`(原地 vs 不同绝对路径
  净克隆,deb 逐字节对比)。DIFFER 不是"重建有噪声",是一堵有名字的墙——
  按报告定位修掉,修复动载荷字节必 bump rev(DEBREV 铁律)。九堵墙的
  台账:`docs/byte-ab-report.md`。

## 7. 专项文档:docs/<pkg>.md

- **先读 `docs/doc-conventions.md`**(文档模板在那里):build.sh 注释 =
  施工日志,docs = 产品说明书 + 坑→修法索引;不互相抄。
- 验收措辞纪律:**只构建过 = "构建完成",没上设备实测不许写"验收通过"**。
- 脱敏:内网地址一律 `<device>`;私有细节进 `DEVICE.md`(gitignored)。

## 8. 设备验收:tests/

- 写 `tests/<pkg>.sh`:`source tests/lib.sh` 后用 `expect_rc0` /
  `expect_out` 组用例,收尾 `summary <pkg>`(`tests/jq.sh` 是最短范本)。
- 铁律(README 原文):**只读**——不写文件、不重启服务、不碰生产 ssh 路径;
  二进制用绝对路径;断言只能对应 README 表 / docs 里已验证过的行为,
  回归网不自造新结论。
- 跑:`tests/run-all.sh [<pkg>...]` → `tests/REPORT.md`(gitignored);
  设备不在线 = SKIP 不 FAIL。

## 9. CI 接入(**2026-11-25 起:GitHub 账号被停,Actions 全线冻结**;
single-build/full-build/nightly 均不可触——full-build/nightly 已删,
single-build.yaml 留档,账号恢复前发布只走 §10 本地路)

1. **日常发布走 single-build**:Actions → `single-build` → 填包名
   (publish 默认 true)——绿了自动"池合并 + make-repo 签名 + force-push
   gh-pages",全链 ~3 分钟;本地等价 = 重建 + `scripts/make-repo.sh`。
2. **full-build.yaml / nightly.yml 已删(2026-11-25)**:矩阵一次 build 太多,
   nightly 的 GH runner 够不着局域网设备。全仓审计改由本地
   `tools/gate-local.sh` 承担(钩子链 + pool 完整性 + shellcheck);新包
   无需 matrix 登记——skip 清单只声明"不自动建"的包。
3. build.yaml 步骤链:build → gate(审计 out/ **全部** `*-armv7`)→
   make-deb(有则自动跑)→ upload(`<pkg>-out` artifact)。
- **commit 先于触发**(run 快照触发时的 HEAD,推晚了跑旧代码);
- 盯 run 用显式 `databaseId`(`gh workflow run` 打印的是 URL,别拼 id)。

## 10. 发布(两条路,同一套机制)

**single-build 发布**(冻结——GitHub 账号 2026-11-25 被停,恢复后即默认):
build job 绿后,publish job 下载
`<pkg>-out` → 新 deb 落 out/ → clone gh-pages 把存量池 `cp -n` 并进来 →
make-repo(元数据门禁 + GPG 签名)→ publish-gh-pages(带 token 的
`PUBLISH_URL`)。**新 deb 赢的前提是 rev 已 bump**:同文件名 `cp -n`
不覆盖(旧包幸存机制的另一面)——重建必 bump rev。

**全仓审计-and-publish**(偶尔手动,本地):`tools/gate-local.sh` 全绿 →
存量池合并 → make-repo → publish。发布后本地跑
`tools/pool-freshness.sh`(配方↔池版本/依赖一致;**"build 已跑未 publish"
也会被抓出来**——DYN 行比对 out/ 最新 deb,ffmpeg -2 在 out/ 躺了一天池里
还是 -1 的教训,2026-11-25 起此盲区已封)和
`scripts/gen-package-table.sh` 重新生成 `docs/PACKAGES.md`(从 Packages
索引生成,防文档漂移;列含 docs/tests 映射)。gh-pages 推送在 GitHub
账号恢复前同样冻结,池以本地 `repo/` + scp 上机为准。

## 11. 部署决策(设备是生产机)

- **用户拍板才部署**;dropbear(端口 22)是命脉,永不动。
- 正规部署走 deb:`dpkg -i`(新 inode + rename + postinst 重签,天然免疫
  内核拒载);手工放二进制 = 三件套 `chmod 755 && chown mobile:mobile &&
  ldid -S`,且 cp 覆盖后必重签。
- 症状速查:**无崩溃报告的 SIGKILL(exit 137)= 签名/entitlements 先查**
  (`ldid -e X` 有输出 = 已签),最后才怀疑应用 bug。

## 12. 新包一页 checklist

```text
[ ] backlog 立项 + 大哥拍板(含部署预期)
[ ] sources.lock 加行(fetch-src --check 过)
[ ] build.sh:env 自含 / out/ 产物 / 源自取 / 净树
[ ] sdk-migrate-probe 本地过;UNRESOLVED → device-symprobe → 入册
[ ] gate-local.sh 过;脚本可执行位齐(+x)
[ ] make-deb.sh:布局/必填 control/rev/postinst ldid/prerm
[ ] byte-ab.sh <cat/pkg> 验载荷可复现(DIFFER = 找墙,不许当噪声放过)
[ ] docs/<pkg>.md(doc-conventions 模板;措辞纪律)
[ ] tests/<pkg>.sh(只读用例)+ run-all 实测
[ ] 发布 = 本地 make-repo(GitHub 冻结期);**建完就发**,publish 后跑
    tools/pool-freshness.sh(DRIFT = 池落后,含"建了没发"的新检查)
[ ] rev 已 bump(同文件名发布会被池合并拒之门外;载荷字节变也必 bump)
[ ] 偶尔本地跑一次 tools/gate-local.sh 全仓审计;发布后重生成 PACKAGES.md
[ ] 部署 = 大哥拍板;走 deb;cp 覆盖必重签
```
