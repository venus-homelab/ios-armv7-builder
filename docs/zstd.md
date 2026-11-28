# zstd 1.5.7 CLI 移植专项（armv7 iOS 10.3.3）

> 包：`zstd4_1.5.7-1` · 同源树补 CLI（lib 侧早被 curl 子构建证明，本次只补
> programs/ 可执行）。**构建完成，byte-ab IDENTICAL；设备验收待补。**
> 构建脚本注释即详细文档：`tools/zstd/build.sh`；本文只留状态、坑与用法。

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | zstd 1.5.7（sources.lock 既有行，与 curl 子构建共享，未新增行） |
| 包 | `zstd4_1.5.7-1_iphoneos-arm.deb` |
| 载荷 | `/var/mobile/tools/zstd/bin/{zstd,unzstd→zstd,zstdcat→zstd}`、`share/man/man1/zstd.1`、`/usr/bin` 三软链 |
| 依赖 | `firmware (>= 10.3)` 兜底；**唯一记录的 dylib 是 `libSystem.B.dylib`**（构建内断言） |
| 门禁 | check-undefined 95/95 全绿；无白名单绕行 |
| 复现 | `tools/byte-ab.sh tools/zstd` → **IDENTICAL**（A=B deb sha256 一致） |
| 构建 | 无 configure，plain make：`make -C lib libzstd.a` + `make -C programs zstd`，~20 s |

## 2. 依赖链

无外部依赖。锁行复用：`net/curl/build.sh` 的 zstd 段已经锁了
`zstd 1.5.7`（curl 的 transfer-encoding 子构建），本包在同源树上构建
CLI，`lib/libzstd.a` 的配方（CC/AR/RANLIB 覆盖 + darwin-ar 重打包断言）
从 curl 段原样照抄，两个消费者互不干扰。

## 3. 坑列表

| 坑 | 要点/修法 |
|---|---|
| `__FILE__` 绝对路径嵌入（byte-ab DIFFER 实测） | `lib/dictBuilder/divsufsort.c` 用 `assert(__FILE__, ...)`，构建路径直接落进二进制 `__cstring`——quickjs `-g0` 墙的**无调试变体**（不需要 -g 就能发生）。修法 `-ffile-prefix-map=$root/=`（curl 墙 #6 对 nghttp2 的同款修法）。 |
| **`-ffile-prefix-map` 静默失效**（byte-ab 第二轮 DIFFER） | 传在 `MOREFLAGS` 里无效：libzstd.mk 用 `CFLAGS += $(MOREFLAGS)` 追加，而**命令行 CFLAGS 会屏蔽 makefile 对 CFLAGS 的一切赋值（+= 在内）**，map 根本进不了编译行。修法：map 直接并进 `CFLAGS` 值本身。两层（lib 与 programs）都要。 |
| LC_UUID 随机差（byte-ab 实测 16 字节差） | tig/build.sh 曾实测本机 ld64 **不**随机化 LC_UUID（docs/tig.md「UUID 旁证」）并因此不加 `-no_uuid`；zstd 的 byte-ab **复现了** 16 字节 UUID 差——tig 的结论是链接特例，不是工具链常量。按实测拍板：本包加 `-Wl,-no_uuid`（whois 墙 #1；dyld 不要求可执行文件带 UUID，whois 已在设备验证）。 |
| zlib/lzma/lz4 支持探测恒真（toolchain.md §8） | programs/Makefile 的 `HAVE_ZLIB/HAVE_LZMA/HAVE_LZ4` 探测是"编译+链接"探针，在 `-undefined dynamic_lookup` 下**恒真**——一旦误开，`.gz/.xz/.lz4` 分支会把 zlib 符号留成 undefined。修法：显式 `HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0` 跳过探测；tar.zst 工作流本就只要 `.zst`。 |
| pthread 探测恒真（无害且是期望行为） | `HAVE_PTHREAD` 是 `:=` 硬探测，恒真 → `-DZSTD_MULTITHREAD` 编入，`pthread_*` 留 undefined 由设备 libSystem 运行时解析（仓库一贯姿势）；`-pthread` 链接旗标被 cc-wrapper 丢弃，不产生额外 dylib。 |

## 4. 设备侧用法 / 验收步骤

部署照三件套（deb 走 dpkg = 新 inode + postinst 重签，天然免疫 cp 覆盖坑）：

```sh
# root 下装包
dpkg -i zstd4_1.5.7-1_iphoneos-arm.deb

# 冒烟 1：版本 + 帮助（无崩溃报告的 SIGKILL = 签名问题，先查 ldid -e zstd）
zstd --version && zstd -h >/dev/null && echo OK

# 冒烟 2：tar.zst 工作流（管道式，不依赖设备 tar 的 --zstd 支持）
mkdir -p /tmp/zt && echo hello > /tmp/zt/a.txt
tar -C /tmp/zt -cf - . | zstd -q -o /tmp/t.tar.zst
mkdir -p /tmp/zt2 && zstd -dcq /tmp/t.tar.zst | tar -C /tmp/zt2 -xf -
cmp /tmp/zt/a.txt /tmp/zt2/a.txt && echo ROUNDTRIP-OK

# 冒烟 3：argv[0] 别名
unzstd --version && zstdcat --version
```

### 宿主 ↔ 设备互操作（宿主自带 zstd 1.5.7）

```sh
# 设备压缩 → 宿主解压
ssh <device> 'zstd -q -19 -o /tmp/x.zst /etc/hosts'
scp <device>:/tmp/x.zst /tmp/x.zst
zstd -dcq /tmp/x.zst | cmp - <(ssh <device> 'cat /etc/hosts') && echo DEV2HOST-OK

# 宿主压缩 → 设备解压
zstd -q -19 -k /etc/hostname -o /tmp/y.zst
scp /tmp/y.zst <device>:/var/mobile/Documents/y.zst
ssh <device> 'zstd -dcq /var/mobile/Documents/y.zst | md5' ; md5sum /etc/hostname
```

## 5. 相关文件

| 文件 | 内容 |
|---|---|
| `tools/zstd/build.sh` | 配方 + 全部墙记录（CC/AR/RANLIB、map、-no_uuid、HAVE_*=0） |
| `tools/zstd/make-deb.sh` | zstd4 打包（staging/tmp、SOURCE_DATE_EPOCH、双签名、软链） |
| `sources.lock` | `zstd 1.5.7` 行（既有，curl 共享） |
| `net/curl/build.sh` | libzstd.a 配方出处（zstd 段） |
| `tmp/byte-ab/zstd/report.md` | byte-ab 判定报告（构建机本地，gitignored） |
