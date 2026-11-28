# git-lfs 3.8.1 —— Go 模板第一金丝雀(git-lfs4)

> 2026-11-24 移植上线。git-lfs 上游 release 源码 tarball,纯 Go,
> gokrb5/spnego/x/net http2 全部直编,零上游语义改动。

## 构建配方

- `tools/git-lfs/build.sh`:`fetch-src.sh --lock git-lfs` 取源 → go.mod 接
  godeps replace(xsys/xnet,相对路径写法,见下墙②)→ **GOFLAGS=-mod=mod** →
  标准环境铁律 + `-trimpath -buildvcs=false -s -w` → `cmd/git-lfs`。
- 门禁:`check-undefined.sh` **111/111**;make-deb 载荷
  `/var/mobile/tools/git-lfs/bin/git-lfs`,`/usr/bin` 符号链接 wrapper,
  postinst 设备重签。**Depends 含 git4**(运行时 exec git)。

## 可复现性

`tools/byte-ab.sh tools/git-lfs` → **IDENTICAL**。

## 墙(2 面,均为模板接线墙,非 darwin/arm 语义墙)

1. **go.sum 缺项(MVS 结构性)**:godeps replace 树的 requires(x/crypto
   v0.57.0 等来自 xnet-darwin-arm v0.60.0)高于上游 go.sum 锁的旧版本 →
   `-mod=readonly` 以 "missing go.sum entry" 失败。处置:`GOFLAGS=-mod=mod`
   (tailcat/build.sh 同源先例);update 是 go.mod+replace 的确定性函数,
   byte-ab 无感。**已成第三方 Go 包默认约定**(go-app-template.md §三)。
2. **replace 绝对路径烧进 BuildInfo**:go.mod 里 `replace x/sys => /abs/...`
   被原样嵌进二进制 build info,`-trimpath` 不清洗 BuildInfo。处置:replace
   一律写**相对 go.mod 的路径** `../../../godeps/<tree>`(build.sh 用
   os.path.relpath 计算,不硬编码层数)。tailscale/tailcat 已回灌同修。

## 设备验收(iPad4 A1458 / iOS 10.3.3,2026-11-24)

- `dpkg -i` 后 `git-lfs version` → `git-lfs/3.8.1 (GitHub; darwin arm; go 1.27.2)` ✓
- `git-lfs env`(PATH 含 /var/mobile/tools/bin 时)→ 找到 git 2.51.2,输出
  LocalWorkingDir 等 ✓。注意:设备默认 PATH 不含 tools/bin(env.sh 场景之外),
  裸跑 `git-lfs env` 会报 "executable file not found in $PATH"——是 PATH 事实,
  不是包 bug。
- 真实 LFS 拉取(pull 指针文件→对象)待大哥实际仓库场景验证。
