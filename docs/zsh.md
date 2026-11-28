# zsh 5.9 移植专项（armv7 iOS 10.3.3）

> 包：`zsh4_5.9-1_iphoneos-arm.deb` · **设备实测通过**（版本/算术/zle/compaudit/compinit）
> 构建脚本注释即详细文档：`lang/zsh/build.sh`；本文记状态、坑与用法。

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | 5.9（官方发行包，sources.lock 锁定） |
| 包名 | `zsh4_5.9-1_iphoneos-arm.deb` |
| 安装路径 | `/var/mobile/tools/zsh/bin/zsh` + `/var/mobile/tools/bin/zsh` 入口链接；functions 树在 `/var/mobile/tools/zsh/share/zsh/5.9/functions` |
| CI | single-build 发布路径；门禁 211/211（裸环境可复验） |
| 验收 | 设备实测：`--version`、算术、`bindkey`（静态 zle）、`compaudit` clean、`compinit` ok |

## 2. 构建形态

- `--disable-dynamic`：全部模块（zle/complist/zpty…）**静态编入**，单二进制；
  动态模块要签名 bundle + dlopen 路径，手机场景不值。
- `--enable-multibyte`：Darwin libc 的 wchar。
- curses：`tools/ncdu/devhdr` 头 + 已提交设备 dylib（less/vim 同配方）。
- **静态 GNU libiconv 1.17**：设备没有 libiconv.2.dylib（iOS 10.3.3 移除），
  zsh 内部（utils.c 补全路径）调 iconv() —— 不接库就会 flat-namespace
  崩（`Symbol not found: _iconv_open`）。静态编入后零运行时依赖。

## 3. 坑列表

| 坑 | 要点/修法 |
|---|---|
| configure 探测谎言（§8 恒真链接） | 7 个设备没有的函数被探测"找到"：`open_memstream`/`getutent`/`faccessx`/`srand_deterministic`/`canonicalize_file_name`/`setproctitle`+`prctl`/`setresuid`+`setresgid`。**逐个设备 dlsym 后 `ac_cv_*=no` 预置**；不预置就是编译错或设备崩 |
| iconv 三层坑 | SDK 的 libiconv.2.tbd 是**空头支票**（设备无此 dylib）→ 静态编 GNU libiconv；其静态库 **GNU ar 无 Darwin TOC**（ld64 拒收"no table of contents"）→ `tools/darwin-ar` 重打；归档导出 `libiconv_*` 前缀名，必须用 **libiconv 自己的 iconv.h**（改名宏对齐） |
| Makefile 后改会被冲掉 | `Makemod` 在构建中**再生成** Src/Makefile：post-make 的 sed 注入白白蒸发。LIBS 注入必须在 **configure 期**（env LIBS），config.status 才世代继承 |
| `___mb_cur_max_l` 设备缺失 | SDK `stdlib.h` 的 `MB_CUR_MAX_L` 宏指过去；macOS 有、iOS 没有。libiconv 的 localcharset 拖进来 → `libios-compat.a` 加优雅降级桩（返回 C locale 的 1） |
| compaudit 拦自己 | fpath 目录 **group-writable（775）即"不安全"**，compinit 随后想 `read -q` 询问（要 tty）→ make-deb 统一 755/644 + root:root |
| uselocale / `____mb_cur_max_l` | 前者设备实有（dlsym 入册）；后者即上一行的桩 |

## 4. 设备侧用法

```
dpkg -i zsh4_5.9-1_iphoneos-arm.deb
export PATH=/var/mobile/tools/bin:$PATH   # 或直接 /var/mobile/tools/zsh/bin/zsh
compinit                                   # 补全（deb 的树 root 属主，audit 干净）
```

- `TERM` 需设置（设备 terminfo 在 `/usr/share/terminfo`）。
- 非 tty 下 compaudit 触发"不安全"询问会自动放弃——安装树是 root 属主 755，正常不会触发。

## 5. 相关文件

| 文件 | 内容 |
|---|---|
| `lang/zsh/build.sh` | 配置/预置/libiconv 静态化/LIBS 注入（全部推理在注释） |
| `lang/zsh/make-deb.sh` | install.bin/install.fns staging、模式规范化、双签名断言 |
| `tools/sysroot/compat/ios-compat.c` | `___mb_cur_max_l` 桩（新增节） |
| `tests/zsh.sh` | 设备验收（只读五用例） |
