# caddy 2.11.9 —— Go 模板最大依赖树样本（caddy4）

> 2026-11-25 移植。caddyserver/caddy 最新 stable release v2.11.9（2026-11-05
> 发布，release 页实钉），纯 Go（CGO_ENABLED=0），大哥 2026-11-23 点名，
> 长期接替设备侧已停用的 nginx（见 [nginx.md](nginx.md)）。
> 构建脚本注释即详细文档：`tools/caddy/build.sh`。本文记录**状态、配方、
> 实测更正、坑与设备验收步骤**。

## 1. 状态

| 项 | 值 |
|---|---|
| 上游版本 | caddy **v2.11.9**（2.x 线最新 stable，非 prerelease） |
| 包名 / 版本 | `caddy4_2.11.9-1_iphoneos-arm.deb` |
| 载荷 | `/var/mobile/tools/caddy/bin/caddy` + `/usr/bin/caddy` 符号链接 + **空** `etc/` + `share/doc/caddy4/` |
| 二进制 | Mach-O armv7，53.5 MB（-s -w 后）；deb 19.1 MB（gzip） |
| 门禁 | `check-undefined.sh` **115/115** 纯 libSystem 面，零面外符号 |
| byte-ab | **IDENTICAL**（见下 §5） |
| 设备验收 | **基础服务 ✅（2026-11-25，本日实测）；QUIC 服务端 ✗（见 §7 墙）** |

### 1.1 设备验收实录（2026-11-25）

| 项 | 结果 |
|---|---|
| 安装 / 版本 / 可执行 | `caddy4 2.11.9-1` 上机，`v2.11.9` ✓，mobile 可执行 ✓ |
| H1/H2 over TLS（真实服务） | `caddy run`（tls internal，file_server :8443）→ 宿主 curl 取回正文 ✓ —— **Go crypto/tls 在 darwin/arm 的 TCP 路径完好** |
| QUIC/HTTP3（服务端角色） | ✗ 宿主 quic-go v0.63.0 客户端 → 设备：`CRYPTO_ERROR 0x150 (remote): tls: internal error`（TCP 的 TLS 完好，唯 QUIC 的 TLS-in-QUIC 死） |
| QUIC/HTTP3（客户端角色） | ✅ **设备上跑的 quic-go 客户端**（同 v0.63.0，复活工具链编译）→ 宿主 QUIC 服务端：`HTTP/3.0 200 全往返成功` —— 64 位原子/UDP 系统调用/pacing/定时器在 armv7 全部可用 |
| 结论 | **quic-go-on-armv7 的墙精确定位在服务端角色的 TLS-in-QUIC 握手**（客户端角色完好）；排障过程中的三次假信号（见 §7） |

## 2. 构建配方

`tools/caddy/build.sh`：标准 go-app 模板（[go-app-template.md](go-app-template.md)）：

1. `fetch-src.sh --lock caddy` 取源（sources.lock 行：tag archive + 实算
   sha256）；**release 页实钉先例**：以 `api.github.com .../releases/latest`
   的 `tag_name` 为准，不猜。
2. go.mod **追加**两条 replace（上游无 replace 行）：`x/sys →
   godeps/xsys-darwin-arm`、`x/net → godeps/xnet-darwin-arm`。caddy pins
   **恰好等于**适配树的版本（x/sys v0.48.0、x/net v0.60.0），MVS 零移动。
3. `GOFLAGS=-mod=mod`（模板默认，本包 replace 无 bump 需求，纯保险）。
4. 主包 `./cmd/caddy`，`-trimpath -buildvcs=false -s -w`，版本戳
   `-X github.com/caddyserver/caddy/v2.CustomVersion=v2.11.9`——caddy 的
   `Version()` 在「作为依赖构建」时才从 build info Deps 找版本（XCADDY
   姿势），直编只会报 unknown；`CustomVersion` 是上游注释点名的官方
   替代（caddy.go ~L950），语义同 fzf 的 `-X main.version`。
5. 环境铁律全套：`GOTOOLCHAIN=local`、`CGO_ENABLED=0`、`GOARM=7`、
   `GOMODCACHE=$root/tmp/gomodcache`、`TMPDIR=$root/tmp`。**本包模块树
   ~1.8 GB**——规则 0（大工作集禁入 /tmp）在本包直接兑现为 1.8G vs
   1.5G tmpfs 配额。

## 3. 预判 vs 实测（任务交代的三个未知面）

| 预判 | 实测 |
|---|---|
| go directive 可能 >1.27.2，需钳制 | **否**。caddy go.mod = `go 1.26.0`；依赖图全体（`go list -m -f '{{.GoVersion}}' all`，约 700 模块）最深 **1.26.0**，全线 ≤ 复活工具链 1.27.2 → **零钳制**，toolchain 行上游本就没有。build.sh 的钳制正则保留作未来 bump 的报警器（≥1.28 才触发）。 |
| quic-go 对 32-bit darwin 有 build constraint 排除 | **否**。quic-go v0.63.0 的 darwin 文件只挂 `//go:build darwin` 级别约束，**不排除 darwin/arm**；编译一路绿（1m40s，暖 GOCACHE）。 |
| 依赖面（gVisor 等） | 实际大头是 OTel 全家 + smallstep/certificates + gRPC + cloudflare/circl；全部直编零改。circl 的 arm 汇编面在 darwin/arm 32-bit 下走纯 Go fallback，无编译问题。 |

**结论：caddy 2.11.9 对本模板是零语义墙移植**——比 fzf/git-lfs 还干净
（那两个至少还有 go.sum MVS 缺项墙）。

## 4. 坑列表（2 面，均为打包层）

1. **heredoc 文案陷阱（两面同源，同一文件先后踩中）**：
   a. 未加引号的 heredoc 里反引号 = 命令替换——changelog 里的
      `` `caddy file-server` `` 被宿主执行（报 `caddy: command not found`），
      词被静默吃掉、deb 文档缺字；修法：与 git-lfs 同款反引号写 `\``。
   b. 加引号的 heredoc（`<<'EOF'`）里 `$VAR` 不展开——README 标题的
      `$VER` 原样入包。修法：README 段改非引号 heredoc + 反引号逐个转义。
   **教训**：两种引法各有一个反向坑，deb 打完必须 `dpkg-deb -x/-e`
   回读验收全部文案（已做；这也是 byte-ab 入账前重打一次的原因）。
2. **`caddy version` 直编报 unknown 的形态坑**：caddy 不读 `-X main.*`，
   只认 build info Deps 里的自己（XCADDY）或 `CustomVersion`。不戳
   CustomVersion 的 caddy4 在设备上会显示 `unknown`——不是构建坏了。

## 5. 可复现性

`tools/byte-ab.sh tools/caddy` → **IDENTICAL**（B 侧净克隆、模块缓存冷态
重下 1.8G，deb 逐字节一致）。BuildInfo 复核：replace 以相对路径
`../../../godeps/<tree>` 记录、`-trimpath=true`、CGO_ENABLED=0、
GOARM=7、二进制 strings 零 `/home/hesper` 命中——byte-ab 墙 #5（Go
replace 绝对路径）在最大依赖树上同样成立。

## 6. 设备验收步骤（给主 agent）

```sh
# root 侧安装（要点名用了 root）
sudo dpkg -i /path/to/caddy4_2.11.9-1_iphoneos-arm.deb

# ① 版本：应输出 v2.11.9（CustomVersion 戳；输出 unknown = 戳丢了，回查 make-deb）
caddy version          # 期望: v2.11.9

# ② 静态服务零配置冒烟（mobile 侧）：
mkdir -p ~/caddy-test && echo "hello-caddy-armv7" > ~/caddy-test/hello.txt
caddy file-server --listen :8080 --root ~/caddy-test &

# ③ host 侧拉取比对（<device-ip> 换设备地址）：
curl -s http://<device-ip>:8080/hello.txt | md5sum
md5sum ~/caddy-test/hello.txt    # 两侧 md5 一致 = 文件服务 + TCP/HTTP 栈 ✓

# ④ 收尾
kill %1 && rm -rf ~/caddy-test
```

- 路径提示：设备默认 PATH 不含 `/var/mobile/tools/bin` 时用全路径
  `/var/mobile/tools/caddy/bin/caddy` 或 `/usr/bin/caddy`（postinst 已建
  符号链接）。
- SIGKILL 无崩溃报告 = 签名问题（部署三件套），先 `ldid -e` 验签再怀疑
  应用层。
- **HTTPS/ACME 不实测**（无公网 80/443，ACME challenge 无法完成）：
  局域网内要 HTTPS 用 `tls internal`（caddy 自签本地 CA）或纯 HTTP。
  设备侧证书链路有兜底事实：二进制已内嵌 Mozilla 根证书
  （`x509roots/fallback`，编译期固定），出站 TLS 验证不依赖设备 CA 池。
- **HTTP/3（QUIC）为未测面**：quic-go v0.63.0 编译通过且无 build
  constraint 排除 darwin/arm，但 64-bit 原子对齐等 32-bit 运行时语义只有
  真实 QUIC 握手才能证明；`caddy file-server --listen :8080` 纯 HTTP 不
  触及该路径。若日后启用 h3 站点，先在设备上小流量验证，QUIC 运行时
  panic（如 `unaligned 64-bit atomic`）记录为设备语义墙回填本文。

## 7. 相关文件

| 文件 | 作用 |
|---|---|
| `tools/caddy/build.sh` | 构建（fetch-src --lock caddy；godeps replace；CustomVersion 戳；check-undefined 门禁） |
| `tools/caddy/make-deb.sh` | 打包 caddy4（空 etc/ + README 指路；postinst 设备重签） |
| `sources.lock` | `caddy 2.11.9` 行（tag archive + sha256，只追加） |
| `godeps/xsys-darwin-arm`, `godeps/xnet-darwin-arm` | 既有适配树，caddy pins 与其版本精确一致，零改动复用 |
| `out/caddy4_2.11.9-1_iphoneos-arm.deb` | 发布载荷 |

## 7. QUIC "服务端墙"（2026-11-25 立案，**同日告破——是配置问题，不是平台墙**）

**根因（dbg 二分 + [QUIC-DBG] 插桩定位）**：QUIC 监听默认绑 v6 通配（udp6
`::`），IP 直连（无 SNI）时 certmagic 按**监听本地地址**找证书——`::` 名下
没有证书（证书是给 192.168.31.70 签的）→ `no certificate available for
'::'` → alert internal_error → `CRYPTO_ERROR 0x150`。TCP 路径绑的是 v4
具体地址所以一直正常。

**修法（配置级，一行）**：Caddyfile 站点加 `bind 192.168.31.70`（或用
域名站点），QUIC 监听落到具体 v4 地址 → 证书查找命中 → **HTTP/3 全通**
（aioquic 客户端从设备拿到 `:status 200` + 正文；池内未改动的 caddy4
二进制复测通过）。大哥确认：**路由器本就没开 IPv6**——v6 通配监听在这
张网里天然是死腿，v4 bind 才是与网络实况一致的正确姿势。曾怀疑的 quic-go 平台墙、证书链、MinVersion/密码套件、
certmagic 缺 h3 ALPN、qlog Tracer——全部被最小服务器逐旋钮二分排除。

**教训**：`pkill -f` 自杀三次之后终于长记性；"最小复现 + 逐旋钮二分 +
权威解析器源码对照"是这一类"泛化 internal_error"的唯一正路。

**现象**:caddy 的 h3 监听活着(udp6 :8443)、QUIC v1 Initial 能回(45B),
但 TLS-in-QUIC 握手在服务端死:客户端收到 `CRYPTO_ERROR 0x150 tls: internal
error`。同二进制同栈,客户端角色在设备上完整跑通 HTTP/3 往返(§1.1)。

**已排除**:网络层(宿主 tcpdump 见双向包)、crypto/tls 本体(TCP 路径
完好)、客户端角色(设备本地跑通)。怀疑面:quic-go 服务端 TLS transport
hooks 在 darwin/arm 的 syscall/控制消息路径(quic-go 官方不支持
darwin/386 类 32 位组合,darwin/arm 未在其支持矩阵)。

**排障路上的三个假信号**(下次别再踩):
1. `pkill -f "caddy run"` 匹配到 ssh 自己的远端命令行,把会话杀了——pkill
   一律 `-x` 精确进程名,模式串绝不能出现在自己的命令行里;
2. **设备 tcpdump -i en0 抓不到 Wi-Fi 流量**(iOS 固件 offload)——宿主侧
   `tcpdump -i wlp3s0` 才是权威视角,双向包一目了然;
3. 首个 `tls: internal error` 差点被当成"Go TLS 平台墙"——真实原因是
   Caddyfile 站点地址写 `:8443`(无主机名),caddy 不知道该给谁签证书
   (`no certificate available for 'IP'`)。**用带 IP 的站点地址 +
   `tls internal` 即签出 IP SAN 证书**。读 DEBUG 日志再下结论。
