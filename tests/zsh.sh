#!/bin/bash
# tests/zsh.sh -- device acceptance for the zsh4 package.
# Claims verified 2026-11-22 on the device: version, arithmetic, zle
# (static modules), completion system load (compinit; the iconv static
# libiconv path is exercised inside it -- that is what crashed before the
# static link), compaudit clean on the root-owned install tree.
source "$(dirname "$0")/lib.sh"
Z=/var/mobile/tools/zsh/bin/zsh

expect_ver "zsh: version"    "$Z --version" "zsh 5.9"
expect_out "zsh: arithmetic" "$Z -f -c 'print \$((40+2))'" "42"
expect_out "zsh: zle module (bindkey table)" \
    "TERM=xterm $Z -f -c 'bindkey | head -1'" "set-mark-command"
expect_rc0 "zsh: compaudit clean (root-owned tree)" \
    "TERM=xterm $Z -f -c 'autoload -Uz compaudit && compaudit'"
expect_out "zsh: compinit loads (iconv path alive)" \
    "TERM=xterm $Z -f -c 'autoload -Uz compinit && compinit && echo ci-ok'" "ci-ok"

summary zsh
