# go-app 模板 —— darwin/armv7 Go 程序的标准做法

> 适用:任何要用复活版 Go 1.27.2(darwin/arm 32-bit)交叉编译上设备的纯 Go 程序。
> 模板要素的实底:`net/tailscale/build.sh`(最全)、`net/tailcat/build.sh`(第一只);
> 工具链与移植墙的正本:`docs/go.md`、`docs/tailscale.md`、`docs/tailcat-porting.md`。

## 一、工具链(宿主侧,不入库)

- **自举,不依赖手工树**:`lang/go/build.sh` 按需构建出
  `out/go-host-1.27.2-linux-amd64.tgz`(fetch → lang/go/patches/ → make.bash →
  sanity),`tools/go-env.sh` 把它解到 `$root/tmp/go-revived` 并给出 `GOPORT`。
  `~/scratch/go-port` 是历史路径,仅存档。
- darwin/arm 复活补丁正本 = `lang/go/patches/`;宿主工具链不是设备包,不入库。
  方法与墙的正本:`docs/go.md`。
- `GOTOOLCHAIN=local` 由 go-env.sh 统一钉死——上游 go.mod 的
  `go 1.27.2`/`toolchain` 行会把工具链请求劫持到网络下载。

## 二、源与依赖

1. **源走 lock**:`sources.lock` 一行(pkg/version/url/sha256),build.sh 一律
   `$root/tools/fetch-src.sh --lock <pkg>`,缓存 `tmp/src-cache/`(gitignored)。
2. **依赖适配树走 godeps/**:`godeps/{xsys,xnet,uroot}-darwin-arm` 三棵树是仓库里
   仅有的非上游 Go 依赖(x/sys v0.48.0 / x/net v0.60.0 / u-root v0.16 的 darwin/arm32
   适配,见 `godeps/README.md`)。接入方式 = 构建时改写 go.mod 的 `replace` 行,
   **一律写相对 go.mod 的路径**(os.path.relpath 计算;绝对路径会被 Go 烧进二进制
   build info 且 -trimpath 不清洗——byte-A/B 墙 #5,见 byte-ab-report.md)。
   tailscale/tailcat/fzf/git-lfs 四处 build.sh 是现成写法。
3. 其余依赖走 go.sum + module proxy,`GOMODCACHE=$root/tmp/gomodcache`
   (不落 ~/go,不落 /tmp——宿主 /tmp 是小 tmpfs,AGENTS.md 规则 0)。
   **GOFLAGS=-mod=mod 是第三方 Go 包的默认**:replace 树的 requires 高于上游
   go.sum 锁的版本时(MVS 结构性),readonly 会以 "missing go.sum entry" 失败;
   update 是 go.mod+replace 的确定性函数,byte-ab 无感(git-lfs 先例)。

## 三、环境铁律(缺一不可)

```sh
# 一行顶五包的重复块(2026-11-25 自 tailscale/tailcat/fzf/git-lfs/caddy 抽取):
source "$root/tools/go-env.sh"
# 它提供:GOPORT(复活工具链,按需自举)、GOTOOLCHAIN=local、CGO_ENABLED=0、
# GOOS/GOARCH/GOARM、GOSUMDB/GOPROXY、TMPDIR/GOMODCACHE(大工作集禁入 /tmp)。
```

构建 flags:**`-trimpath` 必须显式写在 go build 行上**(`-buildvcs=false` 同理)
——载荷可复现的最低要求。模板写着不等于包做了:tailscale/tailcat 两个旗舰
就是没执行这一条,直到 byte-ab 抓出墙 #9(pclntab 烧进 1733 处宿主绝对路径,
2026-11-25)。新 Go 包 build 行照抄 fzf/git-lfs/caddy。

## 四、门禁链(build→deb→设备)

1. `go build`(或 `go install`)产出后,`file` 断言 `Mach-O armv7 executable`;
2. `$root/tools/check-undefined.sh <bin>` —— dynamic_lookup 白名单门,不许绕;
3. make-deb:载荷 `/var/mobile/tools/<pkg>/`,wrapper 或软链,`Depends` 按需带
   `ca-certificates4 | ca-certificates`,`-Zgzip`、`--root-owner-group`,
   changelog 日期一律 `$(date -R -u -d "@${SOURCE_DATE_EPOCH:-0}")`;
4. make-deb 内 `ldid -S` 签名($HOME/ios-tool/bin/ldid);
5. 设备冒烟:`dpkg -i`(ssh 别名通常登的是 mobile 用户;root 直连走 key,
   `ssh root@<device>`,具体值见 DEVICE.md)→ 全路径跑 `--version` → 记 jitless 耗时。

## 五、可复现性自测

`bash tools/byte-ab.sh <cat/pkg>`(原地 vs 不同绝对路径净克隆,deb 逐字节对比)。
Go 侧已知墙:`-trimpath` 漏给某个包、`-buildvcs` 塞入 git 状态、cgo 打开。
见 [byte-ab-report.md](byte-ab-report.md)。

## 六、金丝雀状态

| 程序 | 状态 | 备注 |
|---|---|---|
| tailcat 0.7.0 | ✅ 上线(模板前身) | 首个完整 Go 程序 |
| tailscale 1.104.7 | ✅ 上线 | 全链路验证,userspace-netstack |
| git-lfs 3.8.1 | ✅ 上线(2026-11-24,设备验收过) | 模板第一金丝雀;byte-ab IDENTICAL;墙 #5 发现地;[git-lfs.md](git-lfs.md) |
| fzf 0.75.0 | ✅ 上线(2026-11-24,设备验收过) | 模板第二金丝雀;byte-ab IDENTICAL;tcell 直编零墙;[fzf.md](fzf.md) |
| caddy 2.11.9 | ✅ 上线(2026-11-25 设备验收:H1/H2-TLS ✓;QUIC 服务端全通(2026-11-25 深夜破案:曾立案的"服务端墙"实为 v6 通配监听的证书查找问题,Caddyfile `bind <ip>` 一行解决,见 caddy.md §7)) | 最大依赖树样本(~700 模块/1.8G modcache):**零语义墙**——go directive 1.26.0 全线 ≤1.27.2 零钳制、quic-go v0.63.0 无 darwin/arm build constraint;门禁 115/115;byte-ab IDENTICAL;[caddy.md](caddy.md) |

**欠账清账**(2026-11-25):①tools/go-env.sh 共享片段已抽取,五包 build.sh 均
source(2d106ae);②tailscale/tailcat 的 byte-ab 复验做完——**抓出墙 #9**
(两包 build 行缺 `-trimpath`),修复后双包 IDENTICAL,DEBREV 铁律双 bump
(tailscale4 -5、tailcat4 -3,设备已装)。两 Go 金丝雀已有设备测试
(tests/*.sh),不进任何 CI 矩阵(矩阵已删,2026-11-25)。
余项:caddy 2.11.9 构建零语义墙,设备验收(含 QUIC 运行时)待补。
