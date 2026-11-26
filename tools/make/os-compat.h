/* make/os-compat.h -- force-included SDK compat for GNU make on armv7 iOS.
 *
 * The iOS SDK's string.h has no mempcpy (GNU extension; make's src/ uses it
 * in five+ files).  A static inline keeps it out of the binary's symbol
 * table entirely -- nothing new is expected from the device at runtime.
 * Keep this header self-contained (no gnulib includes: make's lib/ subset
 * does not import the string module, so there is no conflicting
 * declaration).
 */
#ifndef MAKE_OS_COMPAT_H
#define MAKE_OS_COMPAT_H

#include <string.h>

#ifndef mempcpy
static inline void *mempcpy(void *d, const void *s, size_t n)
{
    return (char *)memcpy(d, s, n) + n;
}
#endif

#endif /* MAKE_OS_COMPAT_H */
