# obfs4proxy 0.0.14 移植专项（armv7 iOS 10.3.3）

> 包：`obfs4proxy4_0.0.14-1_iphoneos-arm.deb` · **构建完成；机理设备实测通过
> （回环 E2E 全环）；deb 部署验收待补**（tests/obfs4proxy.sh 上机前 SKIP）
> 构建脚本注释即详细文档：`net/obfs4proxy/build.sh`；E2E 证据：
> `net/obfs4proxy/probe/e2e-20261125.log`。本文记**状态、机理、坑与结论**，
> 细节指向 build.sh / probe。

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | 0.0.14（gitlab tag archive，tag `obfs4proxy-0.0.14`；sources.lock 锁定，sha256 a4b7520e…70903） |
| 包名 | `obfs4proxy4_0.0.14-1_iphoneos-arm.deb` |
| 安装路径 | `/var/mobile/tools/obfs4proxy/bin/obfs4proxy` + `/var/mobile/tools/bin/obfs4proxy` 链接 |
| 验收 | 构建完成（门禁 71/71 未定义符号设备白名单解析；byte-ab **IDENTICAL**）；**机理在设备实测通过**（回环 E2E：设备 pt 驱动 → 设备 obfs4proxy 客户端 → [obfs4 加密流] → 宿主 obfs4proxy 服务端 → 罐头，canned body 字节级验证，见 §4）；deb 上机验收待补 |
| 立项依据 | tor4 在本网络 bootstrap 卡 14%（relay TLS 不通，docs/torsocks.md §3 坑 #6）——网桥是文档化的出路，obfs4 是标准桥传输 |

## 2. 机理与依赖链

```
tor4 (ClientTransportPlugin)                ← 设备角色 = 客户端
  └─ pt 协议（env + stdio）spawn obfs4proxy
       ├─ tor → obfs4proxy：本地 SOCKS5，桥参数走 RFC1929 用户名/密码字段
       └─ obfs4proxy → bridge：obfs4（NTOR + 分帧 + 流量整形，伪装随机 TCP）
             ↓
       [bridge] obfs4proxy 服务端 → TOR_PT_ORPORT
```

- 纯 Go：主依赖 x/crypto（curve25519/hkdf/nacl/secretbox）、x/net/proxy、
  x/sys；goptlib（pt 协议）、edwards25519-extra、siphash 全部纯 Go。
  **TCP only——无 quic-go 面，caddy.md §7 的服务端 QUIC 墙不适用**；E2E 反而
  把 obfs4 **服务端角色**也在宿主实证了（设备在场只跑客户端）。
- godeps 双树 replace（x/sys + x/net → `godeps/{xsys,xnet}-darwin-arm`，
  dnscrypt 2026-11-25 范式）：x/net 用于 x/net/proxy（上游代理 dialer），
  上游 pinned 的 2021 版对 32 位 darwin 面不足，replace 后 MVS 在
  `-mod=mod` 下自动收敛 go.sum。
- 上游 go directive 1.16（≤1.27.2 无需钉）；主包在 `obfs4proxy/` **子目录**
  （ls 实证，非仓库根）。

## 3. 坑列表

| # | 坑 | 要点/修法 |
|---|---|---|
| 1 | gitlab archive 顶层目录名 | archive URL 的名字段可任取，顶层成员 = `<archive-name>`（`obfs4-obfs4proxy-0.0.14`）；提取目录从 tarball 首成员推导，才能与 byte-ab 的净树清理（tar tf \| head -1）对上 |
| 2 | **RFC1929 字段是拼接后解析** | obfs4proxy 把 SOCKS 用户名+密码连成一个 args 串再按 `;` 切 key=value（`common/socks5/args.go parseClientParameters`）；桥参数必须 `uname="cert=<cert>"`、`passwd=";iat-mode=0"`——分号在**密码字段开头**（tor 打包桥参数同款）。漏分号 → 两段粘死 → base64 解码在 byte 73 炸 |
| 3 | **SOCKS CONNECT 目标 = bridge 地址** | pt 语义：tor 对 `Bridge obfs4 <ip>:<port> …` 发的 CONNECT 就是桥地址；obfs4proxy 客户端把它当作桥拨号，真实目的地由**服务端**的 TOR_PT_ORPORT 承接。E2E 首版把罐头填进 CONNECT 目标 → 服务端根本收不到连接（connection reset） |
| 4 | obfs4proxy 默认丢弃全部日志 | `common/log/log.go Init`：不开 `-enableLogging` 时 log.SetOutput(ioutil.Discard)——门禁外的静默失败形态；E2E 驱动 spawn 时统一加 `-enableLogging -unsafeLogging -logLevel DEBUG` 并 dump stateDir/obfs4proxy.log |
| 5 | cert 参数组装 | cert = base64(node-id(20B) ‖ public-key(32B)) 去掉 `==` 后缀（`obfs4ServerCert.String()`）；服务端 SMETHOD 行的 `ARGS:cert=…,iat-mode=n` 与 statefile（obfs4_state.json）双路可取 |
| 6 | termmon 平台分派 | 上游源码树内 obfs4proxy/ 目录的 termmon_linux.go 靠 Go 文件名隐式约束只在 linux 编译；darwin 下 `termMonitorOSInit == nil` → PPID 轮询兜底（源码实证，零补丁） |
| 7 | 退出路径 | `TOR_PT_EXIT_ON_STDIN_CLOSE=1`（obfs4proxy 自读的 pt 扩展）：stdin 关闭 → 优雅退出；设备日志见 "Stdin is closed … terminated"。兜底还有 PPID 轮询 |

## 4. 设备侧用法 / 注意事项

```sh
# tor4 的 torrc 集成（网桥行找 bridge 运营方拿 cert/iat-mode）：
ClientTransportPlugin obfs4 exec /var/mobile/tools/obfs4proxy/bin/obfs4proxy
Bridge obfs4 <ip>:<port> <fp> cert=<cert> iat-mode=0
UseBridges 1
```

- 独立跑必须带 pt 环境变量（否则 `must be run as a managed transport`）；
  最小集：`TOR_PT_MANAGED_TRANSPORT_VER=1`、`TOR_PT_STATE_LOCATION=<可写目录>`、
  `TOR_PT_CLIENT_TRANSPORTS=obfs4`。
- stdout 行格式（客户端）：`VERSION 1` → `CMETHOD obfs4 socks5 127.0.0.1:<随机口>` →
  `CMETHODS DONE`；错误走 `ENV-ERROR` / `VERSION-ERROR` / `CMETHOD-ERROR`。
- 调试三件：`-logLevel DEBUG -enableLogging -unsafeLogging`（日志落
  stateDir/obfs4proxy.log；默认全丢弃，坑 #4）。
- 状态目录会被创建（MkdirAll 0700），里面是 obfs4_state.json——不泄密但按
  pt 惯例按敏感文件对待。
- E2E 复跑：`net/obfs4proxy/probe/e2e-run.sh --host-only`（纯宿主预演）/
  `--device`（真机回环，临时上设备非 deb 部署，收尾自清）。

## 5. 相关文件

| 文件 | 内容 |
|---|---|
| `net/obfs4proxy/build.sh` | 构建（净树推导、godeps replace、主包子目录、门禁） |
| `net/obfs4proxy/make-deb.sh` | 打包（布局、postinst 设备重签、prerm 清链接） |
| `net/obfs4proxy/probe/pt-driver.go` | 最小 pt 驱动（env+stdio spawn、CMETHOD 解析、RFC1929 桥参数、HTTP 断言） |
| `net/obfs4proxy/probe/build.sh` | E2E 交叉编译（宿主 linux 服务端 + armv7 驱动） |
| `net/obfs4proxy/probe/e2e-run.sh` | 回环编排（--host-only / --device） |
| `net/obfs4proxy/probe/e2e-20261125.log` | **设备 E2E 证据**（协议 trace + read-out） |
| `tests/obfs4proxy.sh` | 上机验收（只读；上机前 SKIP） |
