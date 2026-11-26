#!/bin/bash
# tests/tailcat.sh -- the first full Go program (20.3MB, device-self-hosted
# toolchain build); --help exercises the flag package end to end.
source "$(dirname "$0")/lib.sh"
T=/var/mobile/tools/tailcat
expect_out "tailcat: help banner" "$T --help 2>&1 | head -1" "COMMAND"
summary tailcat
