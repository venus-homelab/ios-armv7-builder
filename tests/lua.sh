#!/bin/bash
# tests/lua.sh -- device acceptance for the lua54 package.
# Claims verified 2026-11-22 on the device: version banner, arithmetic,
# loops, string library, in-memory bytecode round-trip (string.dump/load --
# the read-only stand-in for a luac file round-trip).
source "$(dirname "$0")/lib.sh"
L=/var/mobile/tools/lua/bin/lua
LC=/var/mobile/tools/lua/bin/luac

expect_ver "lua: version banner"  "$L -v" "Lua 5.4.7"
expect_out "lua: arithmetic"      "$L -e 'print(40+2)'" "42"
expect_out "lua: loop"            "$L -e 'local s=0 for i=1,100 do s=s+i end print(s)'" "5050"
expect_out "lua: string library"  "$L -e 'print(string.upper(\"lua\"))'" "LUA"
expect_out "lua: bytecode round-trip" \
    "$L -e 'local g=load(string.dump(load(\"print(40+2)\"))); g()'" "42"
expect_rc0 "luac: version"        "$LC -v"

summary lua
