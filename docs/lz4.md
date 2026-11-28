# lz4 1.11.1 CLI 移植专项（armv7 iOS 10.3.3）

> 包：`lz4_1.11.1-1` · 全仓最顺的 plain-make 移植之一：**一次构建过门禁、
> byte-ab 一次 IDENTICAL、零墙**。**构建完成；设备验收待补。**
> 构建脚本注释即详细文档：`tools/lz4/build.sh`；本文只留状态、钉版依据与用法。

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | lz4 1.11.1（2026-11-10 point fix，上游 latest stable） |
| 包 | `lz4_1.11.1-1_iphoneos-arm.deb`（包名照 `git` 先例，无数字后缀） |
| 载荷 | `/var/mobile/tools/lz4/bin/{lz4,lz4c→lz4,unlz4→lz4,lz4cat→lz4}`、`share/man/man1/lz4.1`(+三个 man 软链)、`/usr/bin` 四软链 |
| 依赖 | `firmware (>= 10.3)` 兜底；**唯一记录的 dylib 是 `libSystem.B.dylib`**（构建内断言） |
| 门禁 | check-undefined 85/85 全绿；无白名单绕行 |
| 复现 | `tools/byte-ab.sh tools/lz4` → **IDENTICAL**（A=B deb sha256 一致，一次过） |
| 构建 | 无 configure，plain make：`make -C programs lz4-release`，~3 s |

## 2. 依赖链

无外部依赖。唯一值得记录的是**钉版依据**：

- 任务交代"v1.10.0 线，以 release 页实钉为准"；release 页的 latest stable
  实为 **v1.11.1**（2026-11-10，point fix：修 `LZ4_resetStreamHC()` 在脏
  状态越界、恢复 obsolete enums、CLI `-h` 出 stdout 等），非 prerelease。
- 按"以 release 页为准"钉 v1.11.1，URL 用官方 release 资产（非 tag
  archive），sha256 实算自下载字节并与上游 sidecar
  `lz4-1.11.1.tar.gz.sha256` 逐字对照一致（`683fed08…`），再由
  `tools/fetch-src.sh --check` 常态校验。sources.lock 仅追加这一行。

## 3. 坑列表

**零墙**——一次 IDENTICAL。原因记录（不是没检查，是检查过且天然免疫）：

| 检查项 | 结论 |
|---|---|
| `__FILE__` 路径嵌入（zstd 踩到的） | 天然免疫：`lz4-release`（上游默认姿态）自带 `-DNDEBUG` 且清空 DEBUGFLAGS，assert 全部编译为空；makefile 全程无 `-g`。 |
| LC_UUID 随机差 | 一次 IDENTICAL 即实测本链路未触发；未加 `-no_uuid`（与 tig 同款按实测拍板）。若日后 DIFFER 且定位到 UUID 字节，加旗标即可。 |
| pthread 探测恒真（toolchain.md §8） | 探测恒真 → `-DLZ4IO_MULTITHREAD -DLZ4F_MULTITHREAD=1` 编入，`pthread_*` 留 undefined 由设备 libSystem 解析；`-pthread` 链接旗标被 cc-wrapper 丢弃，不产生额外 dylib。**这是期望行为**（正常 Linux 构建同样多线程）。 |
| GNU ar / 归档格式（toolchain.md §2） | 无此雷：lz4 CLI 不链 `liblz4.a`——`c_program` 规则把 `lib/*.c` + `programs/*.c` 直接编译进可执行文件，全程无 archive，连 darwin-ar 都不需要。 |
| man 页工具依赖 | release tarball 自带预生成的 `programs/lz4.1`（源内 Makefile 重新生成需要 `ronn`，宿主没有也不影响）——直接带货。 |

## 4. 设备侧用法 / 验收步骤

```sh
# root 下装包
dpkg -i lz4_1.11.1-1_iphoneos-arm.deb

# 冒烟 1：版本 + argv[0] 别名
lz4 --version && lz4c --version && unlz4 --version >/dev/null && lz4cat --version >/dev/null && echo OK

# 冒烟 2：往返
echo lz4-roundtrip > /tmp/lt && lz4 -q -f -9 /tmp/lt /tmp/lt.lz4 && rm /tmp/lt \
  && unlz4 -q -f /tmp/lt.lz4 /tmp/lt && cat /tmp/lt && lz4 -t /tmp/lt.lz4 && echo ROUNDTRIP-OK

# 冒烟 3：管道流（stdin→stdout，cat 别名形态）
cat /tmp/lt | lz4cat | cat
```

### 宿主 ↔ 设备互操作

宿主**没有** lz4 CLI（也没装 python-lz4）；宿主侧先 `apt install lz4`
（发行版 1.10.0 即可——lz4 frame 格式自 1.0 稳定，1.10 解 1.11 的产物
没有兼容问题）：

```sh
# 设备压缩 → 宿主解压
ssh <device> 'lz4 -q -9 -f /etc/hosts /tmp/x.lz4'
scp <device>:/tmp/x.lz4 /tmp/x.lz4
lz4 -dcq /tmp/x.lz4 | cmp - <(ssh <device> 'cat /etc/hosts') && echo DEV2HOST-OK

# 宿主压缩 → 设备解压
lz4 -q -9 -f /etc/hostname /tmp/y.lz4
scp /tmp/y.lz4 <device>:/var/mobile/Documents/y.lz4
ssh <device> 'lz4 -dcq /var/mobile/Documents/y.lz4 | md5' ; md5sum /etc/hostname
```

宿主装不了 lz4 时的替代：设备侧 `lz4 -t`（帧自校验）+ 管道往返
（`lz4 -c f | lz4 -dcq`）即足以证明帧格式完好；跨机器互操作待宿主有
lz4 CLI 后补跑。

## 5. 相关文件

| 文件 | 内容 |
|---|---|
| `tools/lz4/build.sh` | 配方 + 零墙的检查记录（lz4-release、pthread、无 archive 链接） |
| `tools/lz4/make-deb.sh` | lz4 打包（上游 install 布局、双签名、软链） |
| `sources.lock` | `lz4 1.11.1` 行（本次唯一新增锁行，release 资产 + sidecar 双证） |
| `tmp/byte-ab/lz4/report.md` | byte-ab 判定报告（构建机本地，gitignored） |
