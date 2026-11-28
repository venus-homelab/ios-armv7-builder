# Privoxy 4.1.0 移植专项（armv7 iOS 10.3.3）

> 包：`privoxy4_4.1.0-1_iphoneos-arm.deb` · 构建完成，check-undefined 门禁
> 117/117 全绿，byte-ab 确定性自测 IDENTICAL；**设备验收待补**（由主 agent
> 按本文 §5 执行）。
> 构建脚本注释即详细文档：`net/privoxy/build.sh`、`net/privoxy/make-deb.sh`
> 本文记录**状态、依赖链、坑与设备验收步骤**。

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | 4.1.0（上游 stable，SourceForge ijbswa，2026-01-05 release） |
| 包名 | `privoxy4_4.1.0-1_iphoneos-arm.deb`（DEBREV=1，363 KB） |
| 安装路径 | `/var/mobile/tools/privoxy/bin/privoxy` + `etc/`（config、\*.action、\*.filter、templates/）+ `var/log/`（postinst 建），`/usr/bin/privoxy` 软链（postinst 建、prerm 清） |
| 动态依赖 | **仅 `/usr/lib/libSystem.B.dylib`**（llvm-otool -L 实测一条；PCRE2/zlib 全静态） |
| 门禁 | check-undefined 117/117 全绿；byte-ab IDENTICAL（无 -no_uuid/-g0 压制旗标） |
| 用途 | 设备本地 HTTP 入口（127.0.0.1:8118）→ 上游 SOCKS5（forward-socks5），补 proxychains 的 `__RESTRICT` 盲区 |
| 编译期裁剪 | https-inspection OFF（无 TLS 后端）、pcre JIT OFF、`--enable-compression` OFF |

## 2. 依赖链

| 依赖 | 形态 | 说明 |
|---|---|---|
| PCRE2 | **静态内嵌** | 上游 4.x 硬要求（configure 无 pcre2 直接 `AC_MSG_ERROR`）。tarball **不捆绑** pcre2：私建静态 pcre2（libpcre2-8 + libpcre2-posix），源取自 sources.lock 已有的 **nmap 7.95 捆绑 libpcre**（nginx/build.sh 先例），无新下载、不裸 clone |
| zlib | **静态内嵌** | FEATURE_ZLIB（响应解压后过滤）；curl/build.sh 的 zlib 1.3.1 配方，私有树防跨包踩踏 |
| TLS 后端 | 无 | https-inspection 需 mbedTLS/OpenSSL/wolfSSL 之一，本轮全部不引（见 §6 展望） |
| libSystem | 设备自有 | 唯一动态依赖 |

## 3. 坑列表（现象 → 根因 → 处置）

### 3.1 tarball 不带生成的 configure，也不带 config.h.in

- **现象**：解包后只有 `configure.in`；直接跑 configure 不存在。
- **根因**：上游发布流程只放 `configure.in`；且 configure.in 开头有一段
  `if test ! -f config.h.in; then read answer "Shall I run autoheader (y/n)?"`
  ——**非 tty 构建会挂死在读 stdin 上**。
- **处置**：build.sh 里先 `autoheader` 再 `autoconf`（宿主 autoconf 2.72，
  仅告警无错误；automake 不需要，GNUmakefile.in 是手写的）。生成物无时间戳，
  byte-ab 不受影响。

### 3.2 `-lpcre2-posix` 是硬链接项，缺档案 = ld64 硬错

- **现象**（预判，未发生）：configure 检出 pcre2 后无条件把
  `-lpcre2-8 -lpcre2-posix` 写进 LIBS。
- **根因**：`-undefined dynamic_lookup` 只救**符号**，不救**库文件**——
  `-lpcre2-posix` 找不到档案时 ld64 直接 "library not found"。privoxy 代码
  其实不调 posix 包装层（grep 全源码无引用），但链接行必须给。
- **处置**：私建 pcre2 时把 `pcre2posix.o` 单独打成 `libpcre2-posix.a`
  （单成员档案，成员数断言 ==1）。归档成员只在被引用时拉入，不增运行时负担。

### 3.3 pcre2 对象命名随 libtool 代次漂移

- **现象**：nginx 时代的重打包 glob（`.libs/pcre2*.o`）在本轮 pcre2 上匹配 0 个对象。
- **根因**：对象落在 `src/` 且前缀是 `libpcre2_8_la-*.o` / `libpcre2_posix_la-pcre2posix.o`
  （另一代 libtool 布局；nginx 私树是 `src/libpcre2_8_la-*.o`，nmap 树是 `.libs/pcre2*.o`）。
- **处置**：重打包改为 `find` 发现 + LC_ALL=C sort 去重，匹配 `*pcre2*.o`
  排除 `*posix*`；空结果即硬失败（不许静默出空档案）。

### 3.4 zlib 探针恒真，但真门禁是我们自己递的弹药

- **现象**：`AC_CHECK_LIB(z, zlibVersion)` 在 dynamic_lookup 下恒 yes
  （toolchain.md §8），HAVE_ZLIB/FEATURE_ZLIB 的真假全看我们喂不喂头和库。
- **处置**：CPPFLAGS 给 `$ZLIBABI/include`（zlib.h/zconf.h）、LDFLAGS 给
  `-L$ZLIBABI/lib`（静态 libz.a）；config.h 断言 `FEATURE_ZLIB` 真的落了
  （capability 自述不可信，断言才是门禁）。zlib 私有树 `tmp/src/privoxy-zlib-1.3.1`
  ——**不能**直接解包到 `tmp/src/`，会原地覆盖 curl 的同名缓存树（tar 逐文件覆盖，
  旧 libz.a 残留 = 假绿）。

### 3.5 gethostbyname_r：链接探针说有，设备没有

- **现象**（预判）：`AC_CHECK_FUNCS` 里 `gethostbyname_r` 在
  dynamic_lookup 下必报 yes；`_gethostbyname_r` 不在任何设备 tbd/verified 清单。
- **处置**：种子 `ac_cv_func_gethostbyname_r=no`（种子=结论，tig 教训）；
  jbsockets.c 走普通 `gethostbyname` fallback（设备白名单有）。其余 FUNCS
  探测目标（strptime/timegm/strlcpy/strlcat/arc4random/nanosleep 等）已逐个
  对照设备清单，全部在册，不需要种子——门禁 117/117 实证。

### 3.6 user/group configure 参数在交叉编译下无意义

- **根因**：`--with-user/--with-group` 拿**构建宿主**的 /etc/passwd 验证，
  只喂给 `make install` 的 init 脚本；我们手工 staging，根本不 make install。
- **处置**：两个参数都不传（configure 走 else 分支仅空值+提示，无硬错误）。

### 3.7 config 路径全是运行期指令，但默认是 CWD 相对

- **根因**：二进制默认找 `./config`（CWD 相对）；confdir/logdir/templdir 是
  config 文件指令而非编译期常量（`--sysconfdir` 等只影响 make install 布局）。
  上游模板的活跃行是 `confdir .` / `logdir .`——从任意 CWD 启动即断。
- **处置**：make-deb.sh 对上游 `config` 做 sed（confdir/logdir 指到载荷绝对
  路径，grep 断言 sed 命中），末尾追加 forward 段；启动一律带**显式 config
  路径**参数。templates 按 confdir/templates 解析，放在 etc/templates/。

## 4. 构建配方（要点）

```sh
bash net/privoxy/build.sh      # → out/privoxy-4.1.0-armv7（未签名），门禁内嵌
bash net/privoxy/make-deb.sh   # → out/privoxy4_4.1.0-1_iphoneos-arm.deb（host ldid 预签）
bash tools/byte-ab.sh net/privoxy \
     --fresh tmp/privoxy-pcre2-abi --fresh tmp/src/privoxy-pcre2 \
     --fresh tmp/privoxy-zlib-abi  --fresh tmp/src/privoxy-zlib-1.3.1
                               # 期望 IDENTICAL（子构建缓存 --fresh 全清）
```

- configure：`--host=armv7-apple-darwin --prefix=/var/mobile/tools/privoxy
  --disable-pcre-jit-compilation`，`CFLAGS=-O2`（无 -g → 无 stabs 可绝对化），
  `CPPFLAGS=-I<pcre2-abi>/include -I<zlib-abi>/include`，
  `LDFLAGS=-L<pcre2-abi>/lib -L<zlib-abi>/lib`。
- https-inspection 关闭方式：**不加任何 `--with-{mbedtls,openssl,wolfssl}`**
  （上游默认 no、检测块整体跳过），build.sh 用 config.h grep 断言
  FEATURE_HTTPS_INSPECTION 未定义。没有单独的 `--disable-https-inspection`
  开关——默认即关。
- pcre2 私树：`--disable-shared --enable-static`（该版无 `--disable-cpp`
  选项，告警无害；未启 JIT 编译），时间戳冻结防 aclocal 重跑（nginx 墙）。
- 打包规约同 fzf/git-lfs/tig 金丝雀：staging 在 `$root/tmp`、
  SOURCE_DATE_EPOCH 顶部 export、changelog `date -R -u -d "@…"`、
  host `ldid -S` + `ldid -e` 断言、postinst 设备重签、
  `-Zgzip --root-owner-group`。
- 构建时长（本机实测，含 pcre2/zlib 子构建）：build ≈ 19 s，byte-ab 全程 ≈ 95 s。

## 5. 设备验收步骤（主 agent 执行）

```sh
# 0. 传包上机 + 安装（root；dpkg = 新 inode + postinst 重签，天然免疫 cp 覆盖坑）
dpkg -i privoxy4_4.1.0-1_iphoneos-arm.deb

# 1. 部署三件套断言
ls -l /var/mobile/tools/privoxy/bin/privoxy      # 755 mobile:mobile
ldid -e /var/mobile/tools/privoxy/bin/privoxy | head -1   # 有输出 = 已签名
otool -L /var/mobile/tools/privoxy/bin/privoxy   # 期望仅 /usr/lib/libSystem.B.dylib
ls -l /usr/bin/privoxy                            # 软链 → /var/mobile/tools/privoxy/bin/privoxy

# 2. 冒烟（mobile 用户；前台起，日志打 stderr；无崩溃报告的 SIGKILL=先查签名）
/usr/bin/privoxy --no-daemon /var/mobile/tools/privoxy/etc/config
#   期望:无 FATAL,进程常驻;另开会话验证监听
netstat -an | grep 8118

# 3. 最小可用性(设备本地回环;直连出口)
curl -x http://127.0.0.1:8118 -sv -o /dev/null http://example.com/
#   期望:HTTP/1.1 200(经 privoxy 过滤链直连)
#   CGI 页活着(过滤引擎/模板路径正确):
curl -s -x http://127.0.0.1:8118 http://config.privoxy.org/ | head -5

# 4. 响应解压过滤路径(FEATURE_ZLIB)
curl --compressed -s -x http://127.0.0.1:8118 -o /dev/null -w '%{http_code}\n' \
     http://example.com/          # 期望 200,body 正常解压

# 5. forward-socks5 → 设备 tor(127.0.0.1:9050,remote DNS)
#   编辑 /var/mobile/tools/privoxy/etc/config:注释掉 `forward / .`,
#   启用 `forward-socks5 / 127.0.0.1:9050 .`,然后热重载:
kill -HUP $(cat /var/mobile/tools/privoxy/var/log/... 2>/dev/null) 2>/dev/null || \
  (pkill privoxy; /usr/bin/privoxy --no-daemon /var/mobile/tools/privoxy/etc/config &)
#   再验:
curl -s -x http://127.0.0.1:8118 http://config.privoxy.org/show-status | grep -i forward
curl -x http://127.0.0.1:8118 -sv -o /dev/null http://example.com/
#   期望:200 且 tor 日志可见该请求;SOCKS5 侧记录的是域名(ATYP=DOMAIN)即 remote DNS 实锤
#   (对照 tests/proxychains-e2e.sh 的链路断言形态)
#   无 tor 场景:任意 SOCKS5 出口都行,host 侧可用 tests/pc-e2e-server.py 罐头

# 6. host 侧走设备代理(不改 listen-address,ssh 隧道)
#   host: ssh -N -L 8118:127.0.0.1:8118 <device> &
curl -x http://127.0.0.1:8118 -sv -o /dev/null http://example.com/
#   期望:200 —— 与设备本地结果一致(证明代理行为与入口位置无关)

# 7. 依赖与卸载路径
dpkg -l privoxy4                                  # ii 状态;Depends: firmware (>= 10.3)
dpkg -r privoxy4 && ls /usr/bin/privoxy           # 软链应消失(prerm)
```

## 6. 展望（本轮明确不做）

- **https-inspection**：上游要 TLS 后端（mbedTLS/OpenSSL/wolfSSL 三选一）。
  日后可按 docs/openssl.md 的消费者链接约定把 openssl4 静态库递给
  `--with-openssl` 重新构建（configure 检测块 + FEATURE_HTTPS_INSPECTION 会
  把 ssl_common.o/openssl.o 拉进 OBJS），届时需要过 ca 证书目录配置与
  `ssl_common` 的文件布局验证。控制字段变化（Depends 不变、Description 变）
  → **升 DEBREV** 重发。
- `--enable-compression`（响应重压缩给客户端）：本地代理收益小，留给实测有
  需求时再开（同样 DEBREV 铁律）。

## 7. 相关文件

| 文件 | 作用 |
|---|---|
| `net/privoxy/build.sh` | 构建（autoheader/autoconf 生成、私有 pcre2+zlib、config.h 断言、门禁） |
| `net/privoxy/make-deb.sh` | 打包（载荷布局、config sed + forward 段、postinst 重签） |
| `net/nginx/build.sh` / `net/nmap/build.sh` | pcre2 静态构建与落位先例（本包复用其配方） |
| `net/curl/build.sh` | zlib 静态构建先例 |
| `docs/tig.md` | configure 型移植四课（假 pkg-config、种子=结论、-g 缓存墙、按实测拍板） |
| `sources.lock` | `privoxy 4.1.0` 行（sha256 取自下载字节）+ 复用 `nmap 7.95`/`zlib 1.3.1` 行 |
