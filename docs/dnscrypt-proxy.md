# dnscrypt-proxy 2.1.21 —— 本地加密 DNS 代理（dnscrypt-proxy4）

> 包：`dnscrypt-proxy4_2.1.21-1` · 已上线（2026-11-25，设备全链验收过）
> 构建脚本注释即详细文档：`net/dnscrypt-proxy/build.sh`
> 本文记录**状态、用法、坑与结论**；细节指向 build.sh，不重复。

## 1. 状态

| 项 | 值 |
|---|---|
| 上游版本 | dnscrypt-proxy **2.1.21**（2026-11-22 release） |
| 包名 / 版本 | `dnscrypt-proxy4_2.1.21-1_iphoneos-arm.deb` |
| 载荷 | `/var/mobile/tools/dnscrypt-proxy/bin/dnscrypt-proxy` + `etc/dnscrypt-proxy.toml`（静态 alidns DoH stamp）；无 daemon、无自启 |
| 门禁 | `check-undefined.sh` **96/96** |
| 设备验收 | ✅ 2026-11-25：daemon（mobile，:15353）→ alidns DoH → `example.com rcode=0 answers=2`；这也是 python3 墙 17（socket SIGBUS）修复后的**首个真网络 UDP 实战负载** |
| byte-ab | 待跑（首建当轮） |

## 2. 依赖链

Go 1.27.2 darwin/arm（复活工具链，`tools/go-env.sh`）。godeps 替换：
`x/sys`、`x/net`（DoH 的 HTTP/2 面）。走模块代理的纯 Go 依赖：
`x/crypto`、`x/text`、`quic-go v0.65`（DoQ **客户端**角色——2026-11-25 的
2×2 矩阵证明 quic-go 在 armv7 的客户端角色可用、服务端角色有墙，
见 `docs/caddy.md` §7）、`codeberg.org/miekg/dns` fork。

## 3. 坑列表

| 坑 | 要点/修法 |
|---|---|
| **双 go.mod** | 仓库根有自己的 go.mod（`go 1.27.4`），子目录构建也会读它——GOTOOLCHAIN=local 大声拒跑。两处都钉 1.27.2（tailscale 先例） |
| **主包位置** | 主包就在仓库根的 `dnscrypt-proxy/` 子目录（当前目录），不是嵌套的 `./dnscrypt-proxy`——target 写错报 "directory not found"，与"文件不存在"难分辨 |
| **syscall.IPV6_TCLASS 缺失** | 32 位 arm 复活版 syscall 无此常量（arm64 有）；darwin 值 `0x3d`（netinet6/in6.h）。build.sh 内幂等源补丁：const 追加到**文件尾**（gc 要求 import 先于其他声明，插 import 前会炸） |
| **DoH stamp 手搓** | 权威布局（vendor/go-dnsstamps）：`proto(1B=0x02) + props(**8B LE u64**) + addr LP + hash LP(空=标准 CA 校验) + provider LP + path LP`——props 单字节、漏空 hash LP 都报 "Invalid stamp"。逐字节对照 fuzzing_test.go 样例定案 |
| **raw.githubusercontent 被墙** | 发行配置不用 GitHub resolvers 列表（设备拉不到）——静态 alidns stamp 离线可用；alidns 223.5.5.5 国内可达 |

## 4. 设备侧用法

```sh
# 配置监听 127.0.0.1:15353（发行配置；绑 53 需 root，改 listen_addresses）
/var/mobile/tools/dnscrypt-proxy/bin/dnscrypt-proxy \
    -config /var/mobile/tools/dnscrypt-proxy/etc/dnscrypt-proxy.toml
# 验证（设备上任意可用 HTTP 客户端或 python3.14 UDP 查询）：
PYTHONHOME=/var/mobile/tools/python314 /var/mobile/tools/bin/python3.14 \
    -c "import socket,struct; s=socket.socket(2,2); \
q=struct.pack('>HHHHHH',0x1234,0x0100,1,0,0,0)+b'\x07example\x03com\x00'+struct.pack('>HH',1,1); \
s.settimeout(8); s.sendto(q,('127.0.0.1',15353)); d,_=s.recvfrom(2048); \
print('rcode',struct.unpack('>H',d[2:4])[0]&0xF,'answers',struct.unpack('>H',d[6:8])[0])"
```

无 LaunchDaemon（nginx 惯例：服务默认关，启动是显式动作）。

## 5. 相关文件

| 文件 | 作用 |
|---|---|
| `net/dnscrypt-proxy/build.sh` | 构建（fetch-src --lock dnscrypt-proxy；godeps replace；IPV6_TCLASS 补丁；check-undefined 门禁） |
| `net/dnscrypt-proxy/make-deb.sh` | 打包 dnscrypt-proxy4（bin + 静态 stamp 配置；postinst 设备重签） |
| `sources.lock` | `dnscrypt-proxy 2.1.21` 行（codeload tag archive + sha256） |
| `tests/dnscrypt-proxy.sh` | 只读回归（版本/配置/-check） |
