#!/bin/bash
# tests/vim.sh -- device acceptance for the vim package (README: huge,
# +multibyte, scripted edit writes correctly).
source "$(dirname "$0")/lib.sh"
V=/var/mobile/tools/bin/vim
expect_ver "vim: version features" "$V --version 2>&1 | grep -c Huge" "1"
expect_out "vim: scripted edit writes" \
    "cd /tmp && printf 'hello\n' > .vim-probe && $V -es .vim-probe -c '%s/hello/edited' -c 'wq' >/dev/null 2>&1; cat .vim-probe && rm -f .vim-probe" \
    "edited"
summary vim
