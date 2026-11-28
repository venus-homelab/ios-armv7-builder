# 移植候选清单（backlog）

> **本文件只放"还没做的"和"判死的"**（2026-11-25 大哥令：已完成项清除，
> 完成过程见各包 `docs/<pkg>.md` 与 git log）。
> 接入新软件的完整作业流程（build→门禁→打包→文档→测试→CI→发布）见
> **[porting-flow.md](porting-flow.md)**。
>
> 渊源：2026-11-14 从 BigBoss 索引盘点（分析底稿 `~/scratch/bigboss/bigboss.db`，
> 索引 9973 包）。方法论：BigBoss 老 deb 当"iOS 可行性证据 + ABI 说明书"
> （`llvm-otool -L` 看 `LC_LOAD_DYLIB`），移植一律拉**上游新版**。

## 已上线（专项文档索引）

设备 kit 的**实时包清单**由仓库索引生成：[PACKAGES.md](PACKAGES.md)
（`scripts/gen-package-table.sh` 生成，勿手改）。下表保留移植史叙述，
版本/数量以 PACKAGES.md 为准。

| 包 | 版本 | 专项文档 | 备注 |
|---|---|---|---|
| tmux | 3.8 | [tmux.md](tmux.md) | **第一个移植**，基建源头 |
| vim | 9.1.0000 | [vim.md](vim.md) | 终端类模板（六道 WALL） |
| git | 2.51.2 | [git.md](git.md) | 手写 config.mak |
| curl | 8.16.0 | [curl.md](curl.md) | 静态 OpenSSL；byte-ab IDENTICAL（六墙收官） |
| wget | 1.25.0 | [wget.md](wget.md) | — |
| openssh | 10.6p2 | [openssh.md](openssh.md) | 22226 验证口；定制构建落 out/custom/ |
| dropbear | 2026.94 | [dropbear.md](dropbear.md) | 唯一 sshd（22 口） |
| nginx | 1.31.9 | [nginx.md](nginx.md) | 设备侧已停用 |
| mosh | 1.4.0 | [mosh.md](mosh.md) | Termius 验证通过 |
| netstat | 1.0 | [netstat.md](netstat.md) | **自研**，ABI 全实测 |
| nmap | 7.95 | [nmap.md](nmap.md) | **侵入性最强**（八道墙） |
| tcpdump | 4.99.5 | [tcpdump.md](tcpdump.md) | 含 libpcap |
| lsof | 4.99.7 | [lsof.md](lsof.md) | libproc 路线 |
| tor | 0.4.8.14 | [tor.md](tor.md) | 全静态栈 |
| rsync | 3.3.0 | [rsync.md](rsync.md) | 增量同步验证 |
| sqlite | 3.54.1 | [sqlite.md](sqlite.md) | 不用 configure |
| ffmpeg | 9.0.2 | [ffmpeg.md](ffmpeg.md) | 远期最大工程 |
| openssl | 4.0.3 | [openssl.md](openssl.md) | 带汇编；墙 #7 修复后重建字节将变 |
| p7zip | 17.05 | [p7zip.md](p7zip.md) | — |
| jq | 1.7.1 | [jq.md](jq.md) | 含 oniguruma |
| whois | 5.6.6 | [whois.md](whois.md) | byte-A/B 首只金丝雀 |
| less | 668 | [less.md](less.md) | ncurses 走 vim 先例 |
| make | 4.4.1 | [make.md](make.md) | 设备端重建 |
| class-dump | 3.5.2 | [class-dump.md](class-dump.md) | 真实 SDK 破局 |
| uuidgen | 1.47.2 | [uuidgen.md](uuidgen.md) | 替代 BigBoss uuid |
| python3 | 3.13.18 | [python.md](python.md) · [python3.md](python3.md) | 含 ssl/sqlite3 |
| python314 | 3.14.10 | 同上 | 与 3.13 并存 |
| tailcat | 0.7.0 | [tailcat-porting.md](tailcat-porting.md) · [tailcat.md](tailcat.md) | 首个完整 Go 程序 |
| go | 1.27.2 | [go.md](go.md) | **TESTING ONLY**；复活版工具链 |
| tailscale | 1.104.7 | [tailscale.md](tailscale.md) | 全链路验证，userspace-netstack |
| pgrep/pkill | 1.0 | [pgrep.md](pgrep.md) | OpenBSD 血统，sysctl 路线 |
| ping | 1.0 | [ping.md](ping.md) | 自写；setuid root |
| ifconfig + route | network_cmds-457 | [ifconfig.md](ifconfig.md) | Apple 正版；xnu-3789 内核头 |
| arp/ndp | network_cmds-457 | [ifconfig.md](ifconfig.md) | 并入 ifconfig4 |
| traceroute | 1.0 | [traceroute.md](traceroute.md) | Apple 正版；setuid 4755 |
| dig/nslookup/host | 1.0 | [dns.md](dns.md) | 自研 stub 解析器 |
| tree/watch/realpath/hexdump | 1.0 | [smalltools.md](smalltools.md) | 小件四连 |
| pgrep -f | 1.1 | [pgrep.md](pgrep.md) | 4 元 mib bug 翻案 |
| git-lfs | 3.8.1 | [git-lfs.md](git-lfs.md) | Go 模板金丝雀；byte-ab IDENTICAL |
| fzf | 0.75.0 | [fzf.md](fzf.md) | Go 模板金丝雀；tcell 零墙 |
| tig | 2.6.1 | [tig.md](tig.md) | C+ncurses；kqueue 同族探针先例 |
| privoxy | 4.1.0 | [privoxy.md](privoxy.md) | HTTP→SOCKS5 接管；forward-socks5 e2e |
| zstd | 1.5.7 | [zstd.md](zstd.md) | tar.zst 工作流；跨机互操作验证 |
| lz4 | 1.11.1 | [lz4.md](lz4.md) | 零墙首跑 IDENTICAL |
| entr | 5.9 | [entr.md](entr.md) | kqueue 探针 10 项上机实录 |
| caddy | 2.11.9 | [caddy.md](caddy.md) | Go 模板最干净一只；接替 nginx 位 |
| ca-certificates | 20261121 | [ca-certificates.md](ca-certificates.md) | 系统信任锚 |
| dnscrypt-proxy | 2.1.21 | [dnscrypt-proxy.md](dnscrypt-proxy.md) | 加密 DNS；byte-ab IDENTICAL 首跑 |
| iperf3 | 3.22.1 | [iperf3.md](iperf3.md) | — |
| lua | 5.4.7 | [lua.md](lua.md) | liblua.a + luac；全仓最易移植 |
| ncdu | 1.20 | [ncdu.md](ncdu.md) | 磁盘用量 TUI（与 socat 同批上线） |
| obfs4proxy | 0.0.14 | [obfs4proxy.md](obfs4proxy.md) | tor 网桥；loopback E2E 绿 |
| patch | 2.7.1 | [patch.md](patch.md) | 设备端补丁应用 |
| proxychains | 4.18 | [proxychains.md](proxychains.md) | — |
| quickjs | 2026-06-04 | [quickjs.md](quickjs.md) | Phase 1 |
| socat | 1.8.0.3 | [socat.md](socat.md) | 中继管道 |
| torsocks | 2.5.0 | [torsocks.md](torsocks.md) | LD_PRELOAD 可行性已实证 |
| zsh | 5.9 | [zsh.md](zsh.md) | — |


## 待办

### 基建 / 工程
- ~~caddy/quic-go 服务端墙~~（2026-11-25 **告破**）：非平台墙——QUIC 监听
  绑 v6 通配导致按 `::` 查证书失败；Caddyfile `bind <ip>` 一行解决，
  HTTP/3 全通（caddy.md §7）。**无遗留工作**。
- ~~换新 GitHub 账号收尾~~（2026-11-27 **全部完成**）：Pages 开通 + 设备端
  apt 全链路验收（源切 venus-homelab、key 导入、update 无 GPG 警告、
  ncdu4 下载 md5 与池逐字节一致）；single-build 首跑五轮修复后绿
  （sysroot MANIFEST 重算、CI 预建 out/、libSystem/kernel tbd 收编 +
  设备 dyld 实证 _kevent64、8 个 make-deb 的 LDID 走 IOS_STUBDIR、
  幽灵 gate step 删除），gate workflow 连绿，artifact 正常产出。
  唯一遗留：CI 的 GPG_PRIVATE_KEY secret 待 token 补
  "Actions secrets" 权限后写入（当前发布走本地 make-repo，不受影响）。

**当前无排队项。**

## 新软件候选（未排期；★=评审推荐度）

（2026-11-28：w 已按大哥指令当日移植部署完成，移除候选条目，
过程见 docs/w.md 与 git log；当前无排队项。）

## 判死 / 排除

- **node 22.23.4**（2026-11-26 清盘）：SDK 模式 18 补丁全流水线，九轮清墙后
  停机；墙账底稿随独立构建项目 ~/node-armv7-builder 删除（未推过远端）。
  本 kit 的 node4 包 2026-11-24 移出；node4/npm4 deb 留档
  `~/backups/node-armv7-builder-deb-20261126/`。
- **syslogcmdline**：实为 `syslogon`/`syslogoff` 两个开关包装，launchctl
  两行可替代，不值得移植（2026-11-14 验明）。
- **BigBoss `uuid` 1.6.0-2p（ossp-uuid）**：设备存量包，CLI `/usr/bin/uuid`
  在 iOS 10.3.3 上 dyld 解析 libgcc_s re-export 失败，Abort trap 6
  （2026-11-15 三次复现）。不修不依赖，由自研 `uuidgen` 包替代。
- **msmtp / vsftpd**：用户 2026-11-15 裁掉（不做）。
- **nano / dialog、adv-cmds 家族**：用户裁掉（nano/dialog 不需要；adv-cmds
  设备基础 userland 已有）。
- 全部 GUI/游戏/中文商业包（触动精灵/天下游/Filza…）、Theos 与
  on-device toolchain（与跨编译哲学相反）、mSpy（间谍件）。
