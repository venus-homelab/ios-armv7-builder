# python3 移植补丁与流程（iOS 10 / armv7）

两条流水线共用 `../build.sh`，靠 `PYTHON_VERSION` + `BUILD_PYTHON` 切换版本。
**2026-11-25 起补丁由 build.sh 自动应用**：取源走 sources.lock（按版本号
精确选行，lock 里有两行 `python3`，`fetch-src --lock` 只认第一行的坑见
build.sh 注释），解包后跑 `patch-cpython-ios-armv7.py`（幂等，树内
`.ios-armv7-patched` marker 防重复）：

```sh
# 3.14.10（默认；宿主 /usr/bin/python3.14 正好同 minor）
IOS_LD64=... ./lang/python3/build.sh

# 3.13.18（宿主 build-python 需自编 3.13，见 docs/python3.md；
#   构建机现成：~/scratch/python3/hostbuild/python）
IOS_LD64=... PYTHON_VERSION=3.13.18 \
  BUILD_PYTHON=~/scratch/python3/hostbuild/python ./lang/python3/build.sh
```

## 源码补丁（patch-cpython-ios-armv7.py 一键应用）

1. **8 字节原子拆半**（`Include/cpython/pyatomic_gcc.h`）
   Apple armv7 ABI 给 `unsigned long long` 4 字节对齐，8 字节
   `__atomic_*` 静默失败（写进去读回垃圾）→ 递归锁自我死锁。
2. **关闭 Apple SystemLog**（按版本选锚点：3.13 `Python/pylifecycle.c`，
   3.14 `Python/initconfig.c` 的 `USE_SYSTEM_LOGGER_DEFAULT`；两处都没有
   才报错——版本再漂移时兜得住）
   iOS 默认把 `sys.stdout/stderr` 换成 os_log 对象，CLI 下 `print` 无输出。
3. **64 位字段对齐标注**（属性在分号前：
   `int64_t interp_count __attribute__((aligned(8)));`，与出厂手工树一致）。
   3.13/3.14 字段所在头不同（pycore_interp_structs.h 是 3.14 新增），文件
   缺失记 skip 不记错。**pycore_lock.h 的 `thread` 字段刻意不在清单里**：
   出厂（设备验证过）的形态就是注解落在 `//` 注释内 = 无效果，照抄验证态。
   ⚠️ 2026-11-25 攻墙时发现旧版脚本的两个隐藏 bug（从未在真实构建上跑过）：
   属性被追加到分号后（非法 C，make 死在 Parser/pegen）+ 负向前瞻 `\s*`
   跨行导致每次重跑重复注解——已修。
4. **configure host case 补丁（仅 3.13）**：3.13.18 的交叉编译 host 表缺
   `*-apple-darwin*` 分支（MACHDEP case + host_ident case 各一处），缺了报
   "cross build not supported"。3.14+ 上游已自带 darwin 归类
   （3.14.10 净配置 MACHDEP=darwin），脚本按 patchlevel 版本门控，不动 3.14。
   build-python 版本校验不放开：3.13 用精确同版本的宿主 3.13 即天然满足。

## zlib 链接闭包（2026-11-25 攻墙，见 build.sh ZLIB_* 注释块与 docs/python3.md）

configure 的 zlib 探测走 pkg-config（交叉下命中**宿主机** zlib.pc，给裸
`-lz`），而 cc-wrapper 的 ld64 无 -syslibroot，净树的 `-lz` 死在
"library not found for -lz"。修法：`ZLIB_LIBS=静态库全路径` +
`ZLIB_CFLAGS=-I同源 include` 喂给 configure（pkg.m4 见用户自设变量直接
短路），`-L` 进 LDFLAGS 双保险。旧树能过是时代红利：3.13 上线时
cc-wrapper 还在默默丢 `-lz`，cf88176 起改为转发，净树重跑即撞墙。

## 已知的通用坑（详见 docs/python3.md）

- `#ifdef HAVE_X` 语义下 `#define X 0` 无效，须用 autoconf undef 形态
- Makefile 有 `pyconfig.h: config.status` 依赖，压制必须在 configure 参数级
- `AC_CHECK_LIB([rt], ...)` 嵌套回退要连 `ac_cv_lib_rt_*` 一起压
- libmpdec 的 UNIVERSAL 架构表无 arm32，需 make 行覆盖 `-DCONFIG_32=1 -DANSI=1`
- 扩展 `.so` 在构建树里是符号链接，打包须 `tar -h` / `cp -L`，且设备上要 `ldid -S`
- cc-wrapper 对 `-bundle` 不能加 `-e _main`
