# 载荷字节级 A/B 报告（tools/byte-ab.sh）

> 工具:`tools/byte-ab.sh <cat/pkg>` —— 同一 commit 双独立构建(原树原地 + 不同绝对
> 路径的净克隆,工作树未提交改动一并覆盖)产物 deb 逐字节对比。容器层确定性已由
> SOURCE_DATE_EPOCH 钳制解决(2026-11-23);本报告验证**载荷层**。out/ 在运行前后
> 快照恢复,不污染池面;双侧净源协议(见墙 #3)保证对比公平。
> 首跑 2026-11-24 于真实池包 net/whois(AGENTS.md 规则 12)。

## 判定与首次修墙(whois)

**最终:IDENTICAL**(`whois4_5.6.6-1`,A/B deb sha 一致)。此前三轮 DIFFER 各自
命名了三堵墙——这正是该工具的价值:把"重建有时不一样"变成一份文件清单。

| # | 墙 | 证据 | 修法 |
|---|---|---|---|
| 1 | **cctools ld64 每次链接生成随机 LC_UUID**(二进制内可见 `uuid_generate_random`),载荷在 load commands 处必然不同 | 编译层跨路径同 sha、链接层跨路径同 sha,唯链接产物 UUID 16 字节差 | whois 链接加 `-Wl,-no_uuid`(ld64 二进制内确认支持;dyld 对可执行文件不要求 UUID) |
| 2 | **make-deb changelog 用壁钟 `$(date -R)`** | 同树重建 deb 的 changelog 日期=当天,池内 deb=旧构建日 | openssh/tailcat/go/quickjs 四处 make-deb 改 `$(date -R -u -d "@${SOURCE_DATE_EPOCH:-0}")`;openssh 顺带补 export(其 SOURCE_DATE_EPOCH 之前未设) |
| 3 | **build.sh 复用已存在的 tmp/src 树** —— A 侧拿到 11-21 的旧树(陈旧 whois.o,大 128 字节),B 侧净提取,布局差异级联 | A.log 无 `-c whois.c` 编译行;两树只有 whois.o 不同;跨路径 .o/链接对照实验均一致 | byte-ab 建立双侧净源协议:构建前按**缓存 tarball 顶层目录名**删除 tmp/src 提取树(从 URL 推导对 codeload 形态无效) |
| 4 | **-g 产物经 ld64 链接后 OSO 路径被绝对化**(quickjs:Makefile CFLAGS 自带 -g,DWARF comp_dir 编译层可 map,但 ld64 把成员路径写死成链接时的绝对路径) | 两树只差路径长度时 qjs 二进制差 208-240 字节;strings 可见各自 `.obj/*.o` 绝对路径 | quickjs 经 DEFINES 通道压 `-g0`(Makefile `CFLAGS+=$(DEFINES)` 把它排在 -g 之后,后写者胜);无输入调试信息则 ld64 无 OSO 可写。symtab 崩溃符号化不受影响 |
| 5 | **Go replace 绝对路径烧进 BuildInfo**(fzf/git-lfs 金丝雀抓到):go.mod 里 `replace x/sys => /abs/...` 被原样嵌进二进制 build info(`=> /abs/path (devel)`),**-trimpath 不清洗 BuildInfo** | 修前 fzf 二进制 2 处 `/home/hesper` 命中,修后 0 | godeps replace 一律写**相对 go.mod 的路径**(build.sh 内 os.path.relpath 计算);tailscale/tailcat 已回灌同修,双包重建绿;`-mod=mod` 同时立为第三方 Go 包默认(git-lfs 类 go.sum 缺项是 MVS 结构性的) |
| 6 | **墙 #1/#4 在子构建层复发**(curl:nghttp2 子构建把 12 个 `lib/*.c` 的 `__FILE__` 路径嵌进静态库) | curl 二进制 strings 可见整套 nghttp2 源文件绝对路径;两树差 288 字节 | nghttp2 cmake 加 `-DCMAKE_C_FLAGS="-ffile-prefix-map=$root/="`(其余子构建 openssl/zlib/brotli/zstd 实测零宿主路径);终链加 `-Wl,-no_uuid` |
| 7 | **OpenSSL 把编译器命令行烧进产物**:cversion.o 的 `compiler:` 串携带 CC 绝对路径与 `-isysroot` 路径;`CROSS_TOP=$root/tmp` 让 isysroot 随树走 | 双树 cversion.o 差 48×2 字节(路径长度差),其余 1187 对象全同;mkbuildinf.pl 确认 SDE 已生效(日期串相同)——时间戳从来不是主因 | openssl/build.sh:CC/AR/RANLIB 改 **PATH 裸名**(`cc-wrapper.sh`),`CROSS_TOP` 移到宿主稳定区 `$IOS_STUBDIR/SDKs/sdk`(符号链接,链接目标不变) |
| 8 | **裸 glob 档案=readdir 序**:curl 的 zlib/zstd darwin-ar 重打包用 `"$SRC"/*.o`,成员序随目录枚举漂移 → ld64 按档案序布局,输出"同尺寸乱序内容"(3.1MB/68 簇的真正主因) | libzstd.a 两树成员内容全同、**顺序不同**;openssl 的档案序反而稳定(上游用显式清单) | 重打包一律 `$(ls … | LC_ALL=C sort)`;教训:**凡 darwin-ar 重打包,成员清单必须排序** |
| 9 | **Go 包不带 `-trimpath`:编译器把绝对源路径烧进 pclntab**(tailscale/tailcat 从没加过——fzf/git-lfs/caddy 金丝雀带了,所以绿的从来是它们;墙 #5 的"双包重建绿"只是构建绿) | 零构建实锤:A 侧 tailscale 二进制含 **1733 处 `/home/hesper`**;A/B 尺寸差形态=路径长度差(~27 字符)× 出现次数(tailscale +53920B、tailscaled +58080B) | 两包 build 行补 `-trimpath`;DEBREV 铁律双 bump(tailscale4 **-5**、tailcat4 **-3**)。附带修 byte-ab 捕获缺陷:`find out -newer marker \| head -1` 不认包名——A 侧构建窗口内并发落地的 traceroute deb 被误当 A.deb(15KB traceroute 冒名 tailscale DIFFER 报告);改按 make-deb 自报路径捕获,日志无据时多 deb 即报错。**教训:验证输出不许 `2>&1 \| grep VERDICT` 截断——证据丢了只能靠落盘日志找回来** |

对照:同 commit 连续两包 sha 一致 —— openssh4_10.6p2-3 修复后双跑同为
`10d2d085…`。"同版本不同字节"的池陷阱(openssl4-8 的教训)正是墙 #2/#3 的产物;
下次重发布触及这两类改动的包,按 DEBREV 铁律同时 bump。

## 首轮矩阵(commit b55e0b0 + 当日修复,2026-11-24)

| 包 | 结果 | 备注 |
|---|---|---|
| net/whois | **IDENTICAL** | 首只载荷可复现金丝雀;墙 #1/#3 修复后达成 |
| lang/quickjs | **IDENTICAL** | 墙 #4(-g/OSO 绝对化)修复后达成 |
| tools/fzf | **IDENTICAL** | Go 金丝雀;B 侧含全量工具链重建+冷 module cache |
| tools/git-lfs | **IDENTICAL** | Go 金丝雀;墙 #5 发现地 |
| net/curl | **IDENTICAL** | 五子构建最大样本;五轮递进,墙 #7(编译器命令行烧录)+ #8(glob 档案序)关闭全部残差 |

## curl 追记 → 结案(2026-11-25)

五轮递进:①暖 vs 净 → 只差 changelog/小节;②`-no_uuid`+nghttp2 map →
UUID 与宿主路径清零;③双侧 `--fresh` → 残差放大为 3.1MB/68 簇"同尺寸乱序
内容"(此形态即档案成员序洗牌的指纹);④补 SOURCE_DATE_EPOCH 不变——
时间戳从来不是主因;⑤**`--keep` 保留双侧构建树逐对象比对**定案:
1188 个 openssl 对象里仅 cversion.o 不同(= `compiler:` 串里的树路径,
墙 #7);其余子构建对象全同,唯 libzstd.a 档案成员序漂移(裸 glob,
墙 #8)。两修后第五轮 **IDENTICAL**。

方法论入册:**残差形态学**——"同尺寸 + 乱序内容"指向档案序/链接布局;
"少量定长差"指向内嵌字符串;对象级二分(with `--keep`)比猜快十倍。
openssl4 自身构建同样吃到墙 #7 修复(其池内 -8 的重发布随波 bump DEBREV)。
# byte-A/B: quickjs  (2026-11-24)
- commit: `b55e0b0a7385279a3fc9b920c193e3325cc780a9` (dirty entries in A tree: 9)
- A (in-place):  `5d7201fdd90f3a73714e0ea22e23d167185057ba5252cc5fa8bf2fe99425a9fb` (503498 bytes)
- B (clean clone, different path): `2e213542ce627698fc8445f51b4ce71e25de30db4e5288f10026f27e6b9db24e` (503548 bytes)
- verdict: **DIFFER**

| payload member | A size | B size | first difference |
|---|---|---|---|
| `var/mobile/tools/bin/qjs` (Mach-O) | 915744 | 915984 | /home/hesper/ios-armv7-builder/tmp/byte-ab/quickjs/xA/var/mobile/tools/bin/qjs /home/hesper/ios-armv7-builder/tmp/byte-ab/quickjs/xB/var/mobile/tools/bin/qjs differ: byte 913, line 3 |
# byte-A/B: quickjs  (2026-11-24)
- commit: `b55e0b0a7385279a3fc9b920c193e3325cc780a9` (dirty entries in A tree: 11)
- A (in-place):  `e88fbfc32ed0881c67c700133ac323a57388bb015a464919bd164f605a31b30c` (503470 bytes)
- B (clean clone, different path): `94b184de44661ef3c431863862d7d934a67845084c5911a8690927e257cac797` (503542 bytes)
- verdict: **DIFFER**

| payload member | A size | B size | first difference |
|---|---|---|---|
| `var/mobile/tools/bin/qjs` (Mach-O) | 915696 | 915904 | /home/hesper/ios-armv7-builder/tmp/byte-ab/quickjs/xA/var/mobile/tools/bin/qjs /home/hesper/ios-armv7-builder/tmp/byte-ab/quickjs/xB/var/mobile/tools/bin/qjs differ: byte 913, line 3 |
# byte-A/B: quickjs  (2026-11-24)
- commit: `b55e0b0a7385279a3fc9b920c193e3325cc780a9` (dirty entries in A tree: 11)
- A (in-place):  `0b5361fdfd219c7bcc1a36d236d31f1210c05ff2fdf8c19810158df9e427efa8` (480004 bytes)
- B (clean clone, different path): `0b5361fdfd219c7bcc1a36d236d31f1210c05ff2fdf8c19810158df9e427efa8` (480004 bytes)
- verdict: **IDENTICAL** -- payload layer is deterministic at this commit
# byte-A/B: fzf  (2026-11-24)
- commit: `568db4f887439af156d046ab5000ebdd03061d07` (dirty entries in A tree: 4)
- A (in-place):  `4c92360cf16ee67ac305081639fe30ad65dac75d2fdd4991d135615561ea5068` (2211898 bytes)
- B (clean clone, different path): `4c92360cf16ee67ac305081639fe30ad65dac75d2fdd4991d135615561ea5068` (2211898 bytes)
- verdict: **IDENTICAL** -- payload layer is deterministic at this commit
# byte-A/B: git-lfs  (2026-11-24)
- commit: `568db4f887439af156d046ab5000ebdd03061d07` (dirty entries in A tree: 5)
- A (in-place):  `855785a9180d7ea8758855f9e2d26bca7d0f3728b10c967ddc9c8dd95d837521` (5377536 bytes)
- B (clean clone, different path): `855785a9180d7ea8758855f9e2d26bca7d0f3728b10c967ddc9c8dd95d837521` (5377536 bytes)
- verdict: **IDENTICAL** -- payload layer is deterministic at this commit
# byte-A/B: curl  (2026-11-24)
- commit: `568db4f887439af156d046ab5000ebdd03061d07` (dirty entries in A tree: 5)
- A (in-place):  `a53ddc40ad44933a65498e6c471c16b77bd9ced4f77abacf72b73e18938fdf53` (2439590 bytes)
- B (clean clone, different path): `b8aaa4584f35942ca2e7930d1c0891fc4e9e2ab3be7189431142638e7f36e062` (2439558 bytes)
- verdict: **DIFFER**

| payload member | A size | B size | first difference |
|---|---|---|---|
| `var/mobile/tools/curl` (Mach-O) | 4696720 | 4696688 | /home/hesper/ios-armv7-builder/tmp/byte-ab/curl/xA/var/mobile/tools/curl /home/hesper/ios-armv7-builder/tmp/byte-ab/curl/xB/var/mobile/tools/curl differ: byte 173, line 1 |
# byte-A/B: curl  (2026-11-24)
- commit: `568db4f887439af156d046ab5000ebdd03061d07` (dirty entries in A tree: 6)
- A (in-place):  `55618d0837749aaf97493bca0e1a14fe9075c72c6e39b9cda0b99009a54849e1` (2439456 bytes)
- B (clean clone, different path): `9bc816b3a61c59685e4b75de8f5c1d82f7d6e732b9eb2bf8b58b54d3cebd07ee` (2439648 bytes)
- verdict: **DIFFER**

| payload member | A size | B size | first difference |
|---|---|---|---|
| `var/mobile/tools/curl` (Mach-O) | 4696720 | 4696720 | /home/hesper/ios-armv7-builder/tmp/byte-ab/curl/xA/var/mobile/tools/curl /home/hesper/ios-armv7-builder/tmp/byte-ab/curl/xB/var/mobile/tools/curl differ: byte 173, line 1 |
# byte-A/B: curl  (2026-11-24)
- commit: `568db4f887439af156d046ab5000ebdd03061d07` (dirty entries in A tree: 14)
- A (in-place):  `b4280a7c3a0e4050a7c91a003bc6d3eb9996182be8b48097b36115761155042d` (2439444 bytes)
- B (clean clone, different path): `c999682c2cb4f7cf56b77e3c355e19a6685336c39c8ed0cd37931c85a2c3ff3d` (2439650 bytes)
- verdict: **DIFFER**

| payload member | A size | B size | first difference |
|---|---|---|---|
| `var/mobile/tools/curl` (Mach-O) | 4696720 | 4696720 | /home/hesper/ios-armv7-builder/tmp/byte-ab/curl/xA/var/mobile/tools/curl /home/hesper/ios-armv7-builder/tmp/byte-ab/curl/xB/var/mobile/tools/curl differ: byte 173, line 1 |
# byte-A/B: curl  (2026-11-24)
- commit: `115dffb71adf80cb462804f9227e83f17dac6303` (dirty entries in A tree: 5)
- A (in-place):  `1ab27655d2b03beb93ae95ae383422fa1efbd9855e9e3e4ced10b21106e38415` (2439444 bytes)
- B (clean clone, different path): `3933547ae2efbde7c9359b8606484a3f148abfd7a45b351474baa21728d05263` (2439650 bytes)
- verdict: **DIFFER**

| payload member | A size | B size | first difference |
|---|---|---|---|
| `var/mobile/tools/curl` (Mach-O) | 4696720 | 4696720 | /home/hesper/ios-armv7-builder/tmp/byte-ab/curl/xA/var/mobile/tools/curl /home/hesper/ios-armv7-builder/tmp/byte-ab/curl/xB/var/mobile/tools/curl differ: byte 173, line 1 |

# byte-A/B: caddy  (2026-11-24)
- commit: `64b61f82eabf1eeb6aa1dc92b8946bfb59d15fd3` (dirty entries in A tree: 6)
- A (in-place):  `0a45aae8af23116c9f19a87543f8fd0db1a79014fc09e1704ab0b4388d6610d6` (19083930 bytes)
- B (clean clone, different path): `0a45aae8af23116c9f19a87543f8fd0db1a79014fc09e1704ab0b4388d6610d6` (19083930 bytes)
- verdict: **IDENTICAL** -- payload layer is deterministic at this commit
# byte-A/B: curl  (2026-11-24)
- commit: `db29d5c4ae7c43b279c2de118ab29ac92b8c37b9` (dirty entries in A tree: 2)
- A (in-place):  `7736f2eb963b25dc5266c9093f4feb8bca989507f764398fdcfcb1c72f10805c` (2439520 bytes)
- B (clean clone, different path): `7736f2eb963b25dc5266c9093f4feb8bca989507f764398fdcfcb1c72f10805c` (2439520 bytes)
- verdict: **IDENTICAL** -- payload layer is deterministic at this commit

# byte-A/B: tailscale (2026-11-25, 修墙 #9 前)
- commit: `2d106aebbb8eea88a9272dc1ca7180e3b380f16d`
- A (in-place): `d4dd670a…` (15578 bytes) ← **此 A.deb 是捕获缺陷的受害者**:A 侧构建窗口内 out/ 落地了一个 traceroute deb,`find -newer | head -1` 抓了它;A 侧真身 tailscale4 deb sha `6e22ad12…` (16209966 bytes)
- B (clean clone): `58bbfd5b…` (16211016 bytes)
- verdict: **DIFFER**——真身对比:payload 二进制 A 16,766,992 / B 16,820,912(+53,920),内嵌路径 1733 处 vs B-tree 形态,即墙 #9

# byte-A/B: tailcat (2026-11-25, 修墙 #9 前)
- verdict: **DIFFER**——同墙 #9(无 -trimpath,pclntab 嵌绝对路径)

# byte-A/B: tailscale (2026-11-25, 修墙 #9 后)
- commit: `fd4e4cabb072eb2a5c446b0b313dcaee23bd9048`
- verdict: **IDENTICAL** —— `-trimpath` 后载荷层确定性成立;tailscale4_1.104.7-5

# byte-A/B: tailcat (2026-11-25, 修墙 #9 后)
- verdict: **IDENTICAL** —— tailcat4_0.7.0-3

# byte-A/B: dnscrypt-proxy (2026-11-25)
- commit: `9d439c30def4e05c9def776c88dc119748b828ca`
- verdict: **IDENTICAL** —— 首跑即绿(模板 §一/§三 + 墙 #5 相对 replace + -trimpath 全套照抄);同轮实战验证了 restore_out 修复(并发落地的 torsocks deb 被"keeping"注记保留)
