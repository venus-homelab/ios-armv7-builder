#!/usr/bin/env python3
"""Source patches for the torsocks 2.5.0 armv7-iOS port.  Idempotent; run
with the torsocks source tree as cwd.  See ../build.sh for the wall list."""

# ---- WALL #3: upstream darwin bug, init_libc_symbols() vs accept4 ----
# torsocks.c's init_libc_symbols() resolves LIBC_ACCEPT4_NAME_STR /
# tsocks_libc_accept4 unconditionally, but torsocks.h declares both only
# under `#if defined(__linux__)` (iOS 10.3.3 has no accept4).  Every other
# user of these symbols (accept.c:90) is already guarded.  Wrap the two
# references in the same guard -- matches the upstream convention exactly.
p = "src/lib/torsocks.c"
s = open(p).read()

old_dlsym = "\ttsocks_libc_accept4 = dlsym(libc_ptr, LIBC_ACCEPT4_NAME_STR);\n"
new_dlsym = (
    "#if defined(__linux__)\n"
    "\ttsocks_libc_accept4 = dlsym(libc_ptr, LIBC_ACCEPT4_NAME_STR);\n"
    "#endif\n"
)
if old_dlsym in s:
    s = s.replace(old_dlsym, new_dlsym, 1)
    print("WALL #3: accept4 dlsym guarded")
elif new_dlsym in s:
    print("WALL #3: accept4 dlsym guard already present")
else:
    sys.exit("patch-darwin: accept4 dlsym anchor not found -- source drift")

old_chk = (
    "\t\t\t!tsocks_libc_syscall || !tsocks_libc_execve || "
    "! tsocks_libc_accept4) {\n"
)
new_chk = (
    "\t\t\t!tsocks_libc_syscall || !tsocks_libc_execve\n"
    "#if defined(__linux__)\n"
    "\t\t\t|| !tsocks_libc_accept4\n"
    "#endif\n"
    "\t\t) {\n"
)
if old_chk in s:
    s = s.replace(old_chk, new_chk, 1)
    print("WALL #3: accept4 null-check guarded")
elif new_chk in s:
    print("WALL #3: accept4 null-check guard already present")
else:
    sys.exit("patch-darwin: accept4 null-check anchor not found -- source drift")

open(p, "w").write(s)
