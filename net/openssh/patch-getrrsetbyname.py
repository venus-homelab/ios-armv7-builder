#!/usr/bin/env python3
# patch-getrrsetbyname.py -- run inside the openssh BUILD tree (cwd = build).
#
# The SDK's resolv.h #defines the standard resolver names to the res_9_*
# libresolv API, which iOS 10 does not export (dlsym MISS).  The device DOES
# export the plain names (res_query/res_init/dn_expand -- dlsym OK, see
# tools/device-symprobe.sh), so strip the macro mapping inside the internal
# getrrsetbyname implementation and declare what it calls.
import sys

p = "openbsd-compat/getrrsetbyname.c"
t = open(p).read()
marker = '#include "includes.h"'
inject = marker + '''
/* The SDK resolv.h maps these to the res_9_* libresolv API, which iOS 10
   does not export; the plain names are on the device (dlsym OK). */
#undef res_query
#undef res_init
#undef dn_expand
extern int res_query(const char *, int, int, unsigned char *, int);
extern int res_init(void);
extern int dn_expand(const unsigned char *, const unsigned char *,
    const unsigned char *, char *, int);'''
if marker not in t:
    print("    getrrsetbyname: marker not found (unexpected)")
    sys.exit(1)
if "#undef res_query" in t:
    print("    getrrsetbyname: already patched")
    sys.exit(0)
t = t.replace(marker, inject, 1)
open(p, "w").write(t)
print("    getrrsetbyname: res_9 macro mapping stripped")
