#!/usr/bin/env python3
"""Apply the iOS 10 / armv7 fixes to a CPython source tree.

These are the changes that made CPython 3.13.18 work on an iPad 4
(armv7, iOS 10.3.3) and are equally required for 3.14.x.
Written 2026-11-16 after the python3 port; extracted from the tweaks that
were applied ad hoc during that port so they can be re-applied to any
CPython version in one step.

Usage:
    python3 patch-cpython-ios-armv7.py /path/to/cpython-src

Each fix is idempotent (already-patched files are left alone) and reports
whether it applied.
"""
import os
import re
import sys

CHANGES = []


def record(name, path, ok, note=""):
    CHANGES.append((name, path, ok, note))


def read(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        return fh.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(text)


def patch_text(root, relpath, old, new, name, marker=None):
    """Replace `old` with `new` in relpath; idempotent via `marker`."""
    path = os.path.join(root, relpath)
    if not os.path.isfile(path):
        record(name, relpath, False, "file not found")
        return False
    src = read(path)
    if marker and marker in src:
        record(name, relpath, True, "already applied")
        return True
    if old not in src:
        record(name, relpath, False, "anchor text not found (version drift?)")
        return False
    write(path, src.replace(old, new, 1))
    record(name, relpath, True, "applied")
    return True


# --------------------------------------------------------------------------
# 1. 8-byte atomics are broken on this device (Apple armv7 ABI gives 64-bit
#    types 4-byte natural alignment; the device's compiler-rt 8-byte helpers
#    are broken too).  Split EVERY 8-byte load/store one-liner in
#    Include/cpython/pyatomic_gcc.h into two 4-byte atomics.
#
#    2026-11-25 scope fix: the first net-tree rebuild split only
#    ullong_relaxed load/store (this script's old docstring claimed "all
#    five variants" but the code carried two) and the device still SIGBUSed
#    at the first real socket syscall -- on _Py_atomic_load_int64_relaxed
#    (socketmodule.c socket_getdefaulttimeout), which clang lowered to the
#    GENERIC libatomic call ___atomic_load(8, src, dst, model).  The manual
#    2026-11-16 trees split exactly the wider set below; replicate it
#    (function-name anchored, order-preserving) and tolerate the long long
#    variants 3.14 added.  8-byte RMW ops (fetch_add / compare_exchange /
#    exchange) cannot be split without losing atomicity -- they are covered
#    by tools/sysroot/compat/atomic-compat.c (correct generic libatomic
#    helpers, statically pulled only when a binary actually references
#    them).
# --------------------------------------------------------------------------
ATOMIC_VARIANTS = [
    # (function suffix, return type, is_load, order macro)
    ("int64",            "int64_t",            True,  "SEQ_CST"),
    ("uint64",           "uint64_t",           True,  "SEQ_CST"),
    ("int64_relaxed",    "int64_t",            True,  "RELAXED"),
    ("uint64_relaxed",   "uint64_t",           True,  "RELAXED"),
    ("ullong_relaxed",   "unsigned long long", True,  "RELAXED"),
    ("llong_relaxed",    "long long",          True,  "RELAXED"),
    ("uint64_acquire",   "uint64_t",           True,  "ACQUIRE"),
    ("int64",            "void",               False, "SEQ_CST"),
    ("uint64",           "void",               False, "SEQ_CST"),
    ("int64_relaxed",    "void",               False, "RELAXED"),
    ("uint64_relaxed",   "void",               False, "RELAXED"),
    ("ullong_relaxed",   "void",               False, "RELAXED"),
    ("llong_relaxed",    "void",               False, "RELAXED"),
    ("uint64_release",   "void",               False, "RELEASE"),
]


def _split_body(ret, order, is_load):
    note = ("iOS 10.3.3 armv7: the 8-byte __atomic_* path reaches compiler-rt\n"
            "       helpers that are broken on this device (unaligned ldrexd /\n"
            "       broken 8-byte helpers -- device-probed 2026-11-16, re-probed\n"
            "       2026-11-25 when net-tree rebuilds SIGBUSed at the first real\n"
            "       socket syscall).  Operate on the two 32-bit halves with\n"
            "       reliable 4-byte atomics.  Callers are GIL-protected or\n"
            "       torn-tolerant (2026-11-16 policy; 8-byte RMW ops are\n"
            "       handled by tools/sysroot/compat/atomic-compat.c).")
    if is_load:
        return ("{\n"
                "#if defined(__APPLE__) && defined(__arm__) && !defined(__aarch64__)\n"
                "    /* " + note + " */\n"
                "    const volatile uint32_t *p32 = (const volatile uint32_t *)obj;\n"
                "    uint32_t lo = __atomic_load_n(&p32[0], __ATOMIC_" + order + ");\n"
                "    __sync_synchronize();\n"
                "    uint32_t hi = __atomic_load_n(&p32[1], __ATOMIC_" + order + ");\n"
                "    return (" + ret + ")(((uint64_t)hi << 32) | lo);\n"
                "#else\n"
                "    return __atomic_load_n(obj, __ATOMIC_" + order + ");\n"
                "#endif\n"
                "}")
    return ("{\n"
            "#if defined(__APPLE__) && defined(__arm__) && !defined(__aarch64__)\n"
            "    /* " + note + " */\n"
            "    volatile uint32_t *p32 = (volatile uint32_t *)obj;\n"
            "    __atomic_store_n(&p32[0], (uint32_t)(value & 0xffffffffu), __ATOMIC_" + order + ");\n"
            "    __sync_synchronize();\n"
            "    __atomic_store_n(&p32[1], (uint32_t)((uint64_t)value >> 32), __ATOMIC_" + order + ");\n"
            "#else\n"
            "    __atomic_store_n(obj, value, __ATOMIC_" + order + ");\n"
            "#endif\n"
            "}")


def split_8byte_atomics(root):
    path = os.path.join(root, "Include", "cpython", "pyatomic_gcc.h")
    if not os.path.isfile(path):
        record("8-byte atomic split", "Include/cpython/pyatomic_gcc.h",
               False, "file not found")
        return
    src = read(path)
    applied = 0
    for suffix, ret, is_load, order in ATOMIC_VARIANTS:
        op = "load" if is_load else "store"
        func = "_Py_atomic_%s_%s" % (op, suffix)
        name = "8-byte atomic %s split (%s)" % (op, suffix)
        pat = re.compile(
            r"(static inline\s+" + re.escape(ret) + r"\s*\n"
            + re.escape(func) + r"\([^)]*\)\s*\n)\{[^{}]*\}")
        fpos = src.find(func + "(")
        seg = src[fpos:src.find("\nstatic inline", fpos)] if fpos >= 0 else ""
        if "p32" in seg:
            record(name, "Include/cpython/pyatomic_gcc.h", True, "already applied")
            continue
        m = pat.search(src)
        if m:
            src = src[:m.start()] + m.group(1) + _split_body(ret, order, is_load) + src[m.end():]
            record(name, "Include/cpython/pyatomic_gcc.h", True, "applied")
            applied += 1
            continue
        if fpos < 0:
            # the function itself does not exist in this version (3.13 has no
            # llong_relaxed variants) -- nothing to split, not a drift
            record(name, "Include/cpython/pyatomic_gcc.h", True,
                   "skipped (function absent in this version)")
            continue
        record(name, "Include/cpython/pyatomic_gcc.h", False,
               "anchor text not found (version drift?)")
    if applied:
        write(path, src)
    print("atomic split: %d applied this run" % applied)



# --------------------------------------------------------------------------
# 2. iOS redirects sys.stdout/stderr to os_log, which breaks a CLI python
#    (`print()` produces no output while os.write(1, ...) works).  3.13:
#    this pylifecycle.c anchor.  3.14: see INITCONFIG_* below.
# --------------------------------------------------------------------------
APPLESTREAM_OLD = '''#  if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#    define USE_APPLE_SYSTEM_LOG 1
#  else
#    define USE_APPLE_SYSTEM_LOG 0
#  endif'''

APPLESTREAM_NEW = '''// ios-armv7-builder (2026-11-16): upstream enables os_log on iOS, which
// replaces sys.stdout/sys.stderr with a SystemLog object -- a command line
// python3 then writes nothing to the terminal.  Disabled by default; pass
// -DPYTHON_IOS_USE_APPLE_SYSTEM_LOG=1 to get the upstream behaviour back.
#  ifndef PYTHON_IOS_USE_APPLE_SYSTEM_LOG
#    define PYTHON_IOS_USE_APPLE_SYSTEM_LOG 0
#  endif
#  if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE && PYTHON_IOS_USE_APPLE_SYSTEM_LOG
#    define USE_APPLE_SYSTEM_LOG 1
#  else
#    define USE_APPLE_SYSTEM_LOG 0
#  endif'''

# 2b. 3.14 moved the same switch into Python/initconfig.c
#     (USE_SYSTEM_LOGGER_DEFAULT); the 3.13 pylifecycle.c anchor above does
#     not exist there.  Same semantics as the 3.13 fix, matching the manual
#     edit that produced the shipped python314 deb (2026-11-16).
INITCONFIG_OLD = '''/* Enable system log by default on non-macOS Apple platforms */
#  if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#define USE_SYSTEM_LOGGER_DEFAULT 1;'''

INITCONFIG_NEW = '''/* Enable system log by default on non-macOS Apple platforms.
 *
 * ios-armv7-builder (2026-11-16): default OFF here.  With it ON, iOS replaces
 * sys.stdout/sys.stderr with a SystemLog object that writes through os_log,
 * so a command-line python3 prints nothing to the terminal (os.write(1, ...)
 * still works, which makes the symptom confusing).  Override at build time
 * with -DCPYTHON_IOS_USE_SYSTEM_LOGGER=1, or at runtime with
 * -X use_system_logger=1. */
#  ifndef CPYTHON_IOS_USE_SYSTEM_LOGGER
#    define CPYTHON_IOS_USE_SYSTEM_LOGGER 0
#  endif
#  if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE && CPYTHON_IOS_USE_SYSTEM_LOGGER
#define USE_SYSTEM_LOGGER_DEFAULT 1;'''

# --------------------------------------------------------------------------
# 3. Alignment of 64-bit fields that are accessed with atomics.
#    clang ignores __attribute__((aligned(8))) on a *member* for the purposes
#    of atomic code generation, but the offsets still need to be consistent
#    between compilation units, so keep the annotations (they also make the
#    intent explicit).
# --------------------------------------------------------------------------
ALIGN_FIELDS = [
    # Patterns match up to the terminating `;`; the replacement moves the
    # semicolon AFTER a real __attribute__((aligned(8))) --
    #     int64_t interp_count __attribute__((aligned(8)));
    # which is the form the shipped (device-verified) trees carry.  The old
    # `$`-anchored rewrite produced `field; __attribute__` (dangling
    # specifier, C syntax error) and, on comment-suffixed lines, appended
    # the attribute INSIDE the // comment (silent no-op); the lookahead
    # stays on one line (`.`, not `\s*`, which crosses the newline).
    ("Include/internal/pycore_interp_structs.h",
     r'^(\s*)int64_t interp_count;(?!.*__attribute__)'),
    ("Include/internal/pycore_interp_structs.h",
     r'^(\s*)uint64_t _code_object_generation;(?!.*__attribute__)'),
    ("Include/internal/pycore_interp_structs.h",
     r'^(\s*)uint64_t next_stackref;(?!.*__attribute__)'),
    ("Include/internal/pycore_interp_structs.h",
     r'^(\s*)uint64_t next_unique_id;(?!.*__attribute__)'),
    ("Include/internal/pycore_typeobject.h",
     r'^(\s*)int64_t interp_count;(?!.*__attribute__)'),
    ("Include/internal/pycore_interp.h",
     r'^(\s*)uint64_t next_unique_id;(?!.*__attribute__)'),
    # pycore_lock.h's `unsigned long long thread;` is deliberately NOT in
    # this list: the manual 2026-11-16 edit (and therefore the shipped,
    # device-verified debs) left it un-annotated -- its attribute landed
    # inside the trailing // comment, a no-op.  Reproduce the verified
    # state; adding aligned(8) here would change struct layout on a hunch.
]


def upstream_version(root):
    m = re.search(r'#define PY_VERSION\s+"([^"]+)"',
                  read(os.path.join(root, "Include", "patchlevel.h")))
    return m.group(1) if m else ""


def patch_configure_host_cases(root):
    """3.13's cross-compile host tables lack a *-apple-darwin* branch:
    configure dies with 'cross build not supported for armv7-apple-darwin'
    (the manual 2026-11-16 edit added two cases to configure AND
    configure.ac; reproduced here verbatim, minus the build-python version
    check bypass -- our host build-python matches PACKAGE_VERSION exactly).
    3.14+ handles generic darwin upstream (3.14.10 configures unpatched,
    MACHDEP=darwin), so non-3.13 trees are left untouched."""
    ver = upstream_version(root)
    if not ver.startswith("3.13"):
        record("configure darwin host case", "configure{,.ac}", True,
               f"skipped ({ver or 'unknown version'}: upstream handles apple-darwin)")
        return
    for rel in ("configure", "configure.ac"):
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            record("configure darwin host case", rel, False, "file not found")
            continue
        src = read(path)
        if "*-apple-darwin*)" in src:
            record("configure darwin host case", rel, True, "already applied")
            continue
        # ac_sys_system case: right after the *-apple-ios* branch
        m1 = "\t*-apple-ios*)\n\t\tac_sys_system=iOS\n\t\t;;\n"
        a1 = m1 + "\t*-apple-darwin*)\n\t\tac_sys_system=Darwin\n\t\t;;\n"
        # host_ident case: right before the vxworks branch (its body text
        # is unique -- the ac_sys_system vxworks branch stores VxWorks)
        m2 = "\t*-*-vxworks*)\n\t\t_host_ident=$host_cpu\n"
        a2 = "\t*-apple-darwin*)\n\t\t_host_ident=$host_cpu\n\t\t;;\n" + m2
        if m1 not in src or m2 not in src:
            record("configure darwin host case", rel, False,
                   "anchor text not found (version drift?)")
            continue
        write(path, src.replace(m1, a1, 1).replace(m2, a2, 1))
        record("configure darwin host case", rel, True, "applied")


def main(root):
    # 1
    split_8byte_atomics(root)

    # 2 -- SystemLog default OFF; anchor moved between 3.13 and 3.14, so try
    # both locations and fail only if neither exists (future version drift).
    n_rec = len(CHANGES)
    if not patch_text(root, "Python/pylifecycle.c", APPLESTREAM_OLD, APPLESTREAM_NEW,
                      "disable Apple SystemLog stdout",
                      marker="PYTHON_IOS_USE_APPLE_SYSTEM_LOG"):
        if not patch_text(root, "Python/initconfig.c", INITCONFIG_OLD, INITCONFIG_NEW,
                          "disable Apple SystemLog stdout (3.14 initconfig)",
                          marker="CPYTHON_IOS_USE_SYSTEM_LOGGER"):
            record("disable Apple SystemLog stdout", "pylifecycle.c/initconfig.c",
                   False, "neither 3.13 nor 3.14 anchor found")
        else:
            del CHANGES[n_rec]   # drop the 3.13-anchor miss; initconfig hit recorded

    # 3
    for rel, pattern in ALIGN_FIELDS:
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            # 3.13 and 3.14 keep these fields in different headers
            # (pycore_interp_structs.h is 3.14-only; pycore_interp.h holds
            # the 3.13 copies) -- a missing file means the field moved and
            # the other version's entry covers it.  Not an error.
            record("align field", rel, True, "skipped (file absent in this version)")
            continue
        src = read(path)
        new, n = re.subn(pattern,
                         lambda m: f"{m.group(1)}{m.group(0).strip().rstrip(';').rstrip()} "
                                   f"__attribute__((aligned(8)));",
                         src, flags=re.M)
        if n and new != src:
            write(path, new)
            record("align field", f"{rel} ({n})", True, "applied")
        else:
            record("align field", rel, True, "already applied / no match")

    # 4 -- configure cross-compile host table (3.13 only; see docstring)
    patch_configure_host_cases(root)

    print("=" * 62)
    ok = True
    for name, path, applied, note in CHANGES:
        flag = "OK " if applied else "FAIL"
        if not applied:
            ok = False
        print(f"[{flag}] {name:32s} {path:46s} {note}")
    print("=" * 62)
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
