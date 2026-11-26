#!/bin/bash
# tests/git.sh -- device acceptance for the git package (README: init/add/
# commit/log/fsck green; https clone via the shipped gitconfig).
source "$(dirname "$0")/lib.sh"
G=/var/mobile/tools/bin/git
expect_ver "git: version" "$G --version" "git version 2.51.2"
expect_out "git: init/add/commit roundtrip" \
    "export HOME=/var/mobile; cd /tmp && rm -rf .gitprobe && $G init -q -b main .gitprobe && cd .gitprobe && echo x > f && $G add f && $G -c user.email=t@t -c user.name=t commit -qm probe && $G log --oneline | head -1 && rm -rf /tmp/.gitprobe" \
    "probe"
summary git
