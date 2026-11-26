#!/bin/sh
# Device-side feasibility matrix -- runs ON the iPad as mobile.
# scp'd to /var/tmp/torsocks-probe/ together with the unsigned cross-built
# probe-host and libprobe.dylib.  Every signing state is produced ON DEVICE
# with the on-device ldid (host signatures are untrusted on this target).
# Read-only with respect to device state; writes only to its own dir.
D=/var/tmp/torsocks-probe
cd "$D" || exit 2

# --- prepare signing variants (on-device ldid) -------------------------
cp -f probe-host probe-host.signed
ldid -S probe-host.signed
cp -f probe-host probe-host.ent
ldid -Sent.xml probe-host.ent
cp -f libprobe.dylib libprobe.signed.dylib
ldid -S libprobe.signed.dylib

echo "### ldid -e proof (signature exists on-device)"
ldid -e probe-host.signed | head -3

echo "### (0) baseline: ad-hoc-signed host alone, no injection"
./probe-host.signed
echo "rc=$?"

echo "### (a) UNSIGNED host + UNSIGNED lib + DYLD_INSERT"
DYLD_INSERT_LIBRARIES="$D/libprobe.dylib" ./probe-host
echo "rc=$?"

echo "### (b) ad-hoc-signed host + signed lib + DYLD_INSERT"
DYLD_INSERT_LIBRARIES="$D/libprobe.signed.dylib" ./probe-host.signed
echo "rc=$?"

echo "### (c) entitlements-signed host (get-task-allow) + signed lib"
DYLD_INSERT_LIBRARIES="$D/libprobe.signed.dylib" ./probe-host.ent
echo "rc=$?"

echo "### (c2) signed host + ENTITLEMENTS-signed lib"
cp -f libprobe.dylib libprobe.ent.dylib
ldid -Sent.xml libprobe.ent.dylib
DYLD_INSERT_LIBRARIES="$D/libprobe.ent.dylib" ./probe-host.signed
echo "rc=$?"

echo "### (d) signed host + signed lib + DYLD_INSERT + DYLD_FORCE_FLAT_NAMESPACE=1"
echo "###     (= torsocks wrapper's own Darwin mechanism)"
DYLD_INSERT_LIBRARIES="$D/libprobe.signed.dylib" DYLD_FORCE_FLAT_NAMESPACE=1 ./probe-host.signed
echo "rc=$?"

echo "### (e) known-good cross-check: insert the device's libproxychains4.dylib"
DYLD_INSERT_LIBRARIES=/var/mobile/tools/proxychains/lib/libproxychains4.dylib ./probe-host.signed
echo "rc=$?"

echo "### device sh -> bash? (wrapper OSTYPE check needs it)"
ls -l /bin/sh
