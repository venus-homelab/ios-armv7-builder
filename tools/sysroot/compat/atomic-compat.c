/*
 * atomic-compat.c -- correct implementations of the GENERIC libatomic
 * entrypoints that clang emits for 8-byte atomics on armv7-apple-ios10.3.
 *
 * WHY (2026-11-25, net-tree python3/314 SIGBUS wall):
 *   This clang lowers every 8-byte __atomic_* builtin on armv7-apple to the
 *   GENERIC size-first-argument libcall (___atomic_load(size, src, dst, model)
 *   etc. -- probed with -S).  At runtime those resolve against the device's
 *   compiler-rt helpers, which are broken on iOS 10.3.3 (8-byte loads return
 *   garbage / misbehave; documented since the 2026-11-16 python3 port and
 *   re-confirmed when clean-tree rebuilds crashed SIGBUS at the first real
 *   socket syscall).
 *
 *   CPython's pyatomic split (patch-cpython-ios-armv7.py) removes the
 *   load/store helper calls from CPython's own code, but 8-byte
 *   compare_exchange / exchange / is_lock_free still reach the helpers from
 *   CPython core (qsbr GC), mimalloc and OpenSSL.  Those cannot be split
 *   without losing atomicity, so this file provides CORRECT implementations
 *   that the linker statically pulls in whenever a generic call exists
 *   (archive members are only pulled when referenced -- zero footprint for
 *   binaries that never emit them).
 *
 * ABI (register map probed from this clang's -S output, thumb armv7):
 *   void  __atomic_load            (size, src,      dst,      model)
 *   void  __atomic_store           (size, dst,      src,      model)
 *   int   __atomic_compare_exchange(size, dst, expected, desired, succ, fail)
 *         -- *expected updated with the old value; returns success
 *   void  __atomic_exchange        (size, dst,      value,    oldbuf, model)
 *   int   __atomic_is_lock_free    (size, ptr) -- nonzero for served sizes
 *
 * NOTE on naming: clang refuses to let C code define the __atomic_* names
 * ("cannot redeclare builtin"), so the definitions use compat_* identifiers
 * with __asm__ symbol labels that produce the exact Mach-O symbols
 * (___atomic_load etc.) the libcalls search for.
 *
 * Implementation: a single 4-byte spinlock (4-byte atomics are inline and
 * reliable on this device -- probed 2026-11-16; the legacy __sync_* builtins
 * here inline the same way and are unrelated to the __atomic_* libcall
 * machinery) + memcpy under the lock.  Contention is negligible: hot 8-byte
 * load/store paths are split in pyatomic_gcc.h and never reach here; only
 * rare RMW/lock-free queries do.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

static volatile uint32_t atomic_compat_lock;

static void compat_lock_acquire(void)
{
    while (__sync_lock_test_and_set(&atomic_compat_lock, 1u)) {
        /* spin */
    }
}

static void compat_lock_release(void)
{
    __sync_lock_release(&atomic_compat_lock);
}

/* Cap: callers only emit these libcalls for sizes they actually use; serve
 * anything up to 64 bytes via the lock.  Larger sizes are never emitted by
 * any consumer in this repo -- trap loudly instead of corrupting memory. */
#define ATOMIC_COMPAT_MAX 64

void compat_atomic_load(size_t size, const void *src, void *dst, int model)
    __asm__("___atomic_load");
void compat_atomic_load(size_t size, const void *src, void *dst, int model)
{
    (void)model;
    if (size > ATOMIC_COMPAT_MAX) {
        __builtin_trap();
    }
    compat_lock_acquire();
    memcpy(dst, src, size);
    compat_lock_release();
}

void compat_atomic_store(size_t size, void *dst, const void *src, int model)
    __asm__("___atomic_store");
void compat_atomic_store(size_t size, void *dst, const void *src, int model)
{
    (void)model;
    if (size > ATOMIC_COMPAT_MAX) {
        __builtin_trap();
    }
    compat_lock_acquire();
    memcpy(dst, src, size);
    compat_lock_release();
}

int compat_atomic_compare_exchange(size_t size, void *dst, void *expected,
                                   const void *desired, int success,
                                   int failure) __asm__("___atomic_compare_exchange");
int compat_atomic_compare_exchange(size_t size, void *dst, void *expected,
                                   const void *desired, int success,
                                   int failure)
{
    (void)success;
    (void)failure;
    if (size > ATOMIC_COMPAT_MAX) {
        __builtin_trap();
    }
    unsigned char old[ATOMIC_COMPAT_MAX];
    compat_lock_acquire();
    memcpy(old, dst, size);
    if (memcmp(old, expected, size) == 0) {
        memcpy(dst, desired, size);
        compat_lock_release();
        return 1;
    }
    memcpy(expected, old, size);
    compat_lock_release();
    return 0;
}

void compat_atomic_exchange(size_t size, void *dst, const void *value,
                            void *oldbuf, int model)
    __asm__("___atomic_exchange");
void compat_atomic_exchange(size_t size, void *dst, const void *value,
                            void *oldbuf, int model)
{
    (void)model;
    if (size > ATOMIC_COMPAT_MAX) {
        __builtin_trap();
    }
    compat_lock_acquire();
    memcpy(oldbuf, dst, size);
    memcpy(dst, value, size);
    compat_lock_release();
}

int compat_atomic_is_lock_free(size_t size, const void *ptr)
    __asm__("___atomic_is_lock_free");
int compat_atomic_is_lock_free(size_t size, const void *ptr)
{
    (void)ptr;
    return size <= ATOMIC_COMPAT_MAX ? 1 : 0;
}
