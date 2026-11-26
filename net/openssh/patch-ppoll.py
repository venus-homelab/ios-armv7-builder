#!/usr/bin/env python3
# patch-ppoll.py -- run inside the openssh BUILD tree (cwd = build).
#
# iOS 10 has no ppoll(2) (dlsym MISS), and openssh 10.6 calls it
# unconditionally in the packet-timeout waits.  The production musl-era
# binary only survived because packet_timeout_ms defaults to -1 and lazy
# binding never resolved the symbol -- a time bomb, not a port.
# poll(2) with a millisecond timeout is the exact equivalent for these
# single-fd, no-signal-mask call sites.
import glob
import sys

n = 0
files = 0
for f in glob.glob("*.c"):
    t = open(f).read()
    orig = t
    t = t.replace("ppoll(&pfd, 1, timespecp, NULL)",
                  "poll(&pfd, 1, timespecp == NULL ? -1 : (int)(timespecp->tv_sec * 1000 + timespecp->tv_nsec / 1000000))")
    t = t.replace("ppoll(*pfdp, *npfd_activep, ptimeout_get_tsp(&timeout), sigsetp)",
                  "poll(*pfdp, *npfd_activep, (int)(timeout.tv_sec * 1000 + timeout.tv_nsec / 1000000))")
    t = t.replace("ppoll(pfd, npfd, ptimeout_get_tsp(&timeout), &osigset)",
                  "poll(pfd, npfd, (int)(timeout.tv_sec * 1000 + timeout.tv_nsec / 1000000))")
    t = t.replace("ppoll(pfd, npfd, NULL, &osigset)",
                  "poll(pfd, npfd, -1)")
    t = t.replace("ppoll(read_wait, maxfd, &seltime, NULL)",
                  "poll(read_wait, maxfd, (int)(seltime.tv_sec * 1000 + seltime.tv_nsec / 1000000))")
    if t != orig:
        open(f, "w").write(t)
        n += t.count("poll(&pfd, 1, timespecp == NULL")
        files += 1
print("    ppoll -> poll: %d sites in %d files" % (n, files))
if n == 0:
    print("    ppoll patch matched nothing (unexpected)", file=sys.stderr)
    sys.exit(1)
