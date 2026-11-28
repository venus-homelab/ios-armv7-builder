# Lua 5.4.7 移植专项（armv7 iOS 10.3.3）

> 包：`lua54_5.4.7-1_iphoneos-arm.deb` · **设备实测通过**（版本/算术/字符串库/字节码往返/luac）
> 构建脚本注释即详细文档：`lang/lua/build.sh`；本文记状态与唯一两坑。

## 1. 状态

| 项 | 值 |
|---|---|
| 版本 | 5.4.7（官方 tarball，sources.lock 锁定） |
| 包名 | `lua54_5.4.7-1_iphoneos-arm.deb` |
| 安装路径 | `/var/mobile/tools/lua/bin/{lua,luac}` + `/var/mobile/tools/bin/` 链接；`include/`（C API 头）与 `lib/liblua.a` 一并随包（给嵌入者） |
| CI | single-build 发布路径；门禁 lua 108/108、luac 62/62（裸环境可复验） |
| 验收 | 设备实测：banner、`print(40+2)`、循环、`string.upper`、`string.dump/load` 往返、`luac -v` |

## 2. 构建形态

- 无 configure、纯 C89、零外部依赖——本仓库最容易的移植。
- `PLAT=generic`：默认 `guess` 目标探测**宿主**，选中 linux-noreadline，
  其 `-Wl,-E` 到 ld64 变 `unknown option: -E`。
- 无 readline/POSIX 扩展（解释器完整，`io.popen` 走 libc popen 仍可用）。
- `liblua.a` 用 `tools/darwin-ar` 打（Darwin TOC）。

## 3. 坑列表

| 坑 | 要点/修法 |
|---|---|
| `guess` 目标选宿主配方 | `PLAT=generic` 显式指定，绕开宿主探测 |
| GNU ar 归档 ld64 拒收 | 与 zsh 的 libiconv 同坑：`darwin-ar rcu` 直接当 `AR=` 传入 |

## 4. 设备侧用法

```
dpkg -i lua54_5.4.7-1_iphoneos-arm.deb
lua -e 'print(_VERSION)'
```

嵌入（C API）：头在 `/var/mobile/tools/lua/include`，静态库在
`/var/mobile/tools/lua/lib/liblua.a`（Darwin 格式，ld64 直链）。

## 5. 相关文件

| 文件 | 内容 |
|---|---|
| `lang/lua/build.sh` | generic PLAT、darwin-ar、双产物（lua+luac） |
| `lang/lua/make-deb.sh` | bin/include/lib staging、双签名断言 |
| `tests/lua.sh` | 设备验收（六用例，只读） |
