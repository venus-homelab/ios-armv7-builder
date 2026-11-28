# fzf 0.75.0 —— Go 模板第二金丝雀(fzf4)

> 2026-11-24 移植上线。junegunn/fzf 上游 release tarball,纯 Go,
> tcell/v2 2.9.0 TUI 层在 darwin/arm 上零改动直编。

## 构建配方

- `tools/fzf/build.sh`:`fetch-src.sh --lock fzf` 取源 → go.mod 删 `toolchain` 行
  (go directive 1.23.0 ≤ 1.27.2 不动)→ GOTOOLCHAIN=local /
  GOOS=darwin GOARCH=arm GOARM=7 / CGO_ENABLED=0 / `-trimpath -buildvcs=false -s -w`
  构建 → `tools/go-env.sh` 尚未抽出前,环境铁律见
  [go-app-template.md](go-app-template.md)。
- 依赖:上游 go.sum 全量命中(git-lfs 类缺 sum 的结构性问题这包没踩到);
  无需 godeps replace(fzf 不直接依赖 x/sys darwin/arm 缺口面)。
- 门禁:`check-undefined.sh` **83/83**;make-deb 载荷
  `/var/mobile/tools/fzf/bin/{fzf,fzf-tmux,fzf-preview.sh}` + man 页 + shell 集成,
  `/usr/bin` 符号链接 wrapper(ncdu 同款),postinst 设备重签。

## 可复现性

`tools/byte-ab.sh tools/fzf` → **IDENTICAL**(B = 不同绝对路径 + 全量重建工具链 +
冷 module cache)。构建宿主路径零泄漏(修后 `grep /home/hesper` 0 命中)。

## 设备验收(iPad4 A1458 / iOS 10.3.3,2026-11-24)

- `dpkg -i` 后 `fzf --version` → `0.75.0 (v0.75.0)` ✓(jitless go1.27.2)
- 功能冒烟:`printf 'alpha\nbeta\ngamma\n' | fzf --filter=ga` → `gamma` ✓
  (filter 模式无 TTY 可跑;交互 TTY/tmux 场景待大哥实际使用反馈)
- `ldid -e` 有输出 ✓(postinst 重签生效)

## 墙

darwin/arm 语义墙**零**。唯一注意点:构建重试上限内一次过。
