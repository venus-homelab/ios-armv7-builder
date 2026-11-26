/*
 * probe-kqueue.c -- on-device kqueue semantics probe for the entr4 port
 * (armv7 / iOS 10.3.3, iPad4).  Single file, no dependencies beyond
 * libSystem; cross-built with tools/cc-wrapper.sh and gated by
 * tools/check-undefined.sh BEFORE the formal entr build (porting rule:
 * probe first, build after).
 *
 * What it verifies against the LIVE kernel (each check printed PASS/FAIL,
 * exit 0 only when every check passes):
 *
 *   1. struct sizes/alignment: kevent == 20 B (no ext, the musl-era 52 B
 *      stride bug must NOT recur -- docs/musl-sysroot.md #14), kevent64_s
 *      == 48 B, timespec == 8 B.
 *   2. kqueue() creates a queue.
 *   3. ONE changelist with TWO EVFILT_VNODE registrations lands (stride
 *      proof: element #2 is only right when the 20 B layout is right).
 *   4. A real write() to file A delivers NOTE_WRITE with the registered
 *      udata pointer round-tripped intact and ident == fd.
 *   5. Same for file B (second changelist element).
 *   6. rename() delivers NOTE_RENAME; unlink() delivers NOTE_DELETE.
 *   7. EVFILT_READ + NOTE_LOWAT on a pipe delivers with data >= 1 (entr's
 *      stdin trigger path).
 *   8. kevent64() on the same file delivers NOTE_WRITE (the 64-bit ABI is
 *      available and consistent, even though entr itself uses plain
 *      kevent).
 *   9. The timespec timeout path is accepted by the kernel: a quiet queue
 *      returns 0 events instead of blocking (timespec size/alignment).
 *
 * Usage (on device):
 *   cd /var/mobile/tools/entr   # or any writable dir
 *   ./probe-kqueue              # creates probe-a/probe-b in cwd
 */

#include <sys/event.h>
#include <sys/stat.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Darwin's event.h has no NOTE_TRUNCATE (a FreeBSD extension); upstream
 * entr handles this exact situation in missing/compat.h by defining it to 0
 * -- mirror that here so the probe tests the same fflags mask the real
 * entr build will register. */
#if !defined(NOTE_TRUNCATE)
#define NOTE_TRUNCATE 0
#endif

#define NOTE_ALL NOTE_DELETE | NOTE_WRITE | NOTE_RENAME | NOTE_TRUNCATE | NOTE_ATTRIB

static int nfail;
static int npass_n;
static void report(int ok, const char *what, const char *detail) {
	printf("%s %d: %s%s%s\n", ok ? "PASS" : "FAIL", ++npass_n, what,
	       detail && *detail ? " (" : "", detail && *detail ? detail : "");
	if (!ok)
		nfail++;
}

int main(int argc, char *argv[]) {
	if (argc > 1 && chdir(argv[1]) == -1) { perror("chdir"); return 2; }

	/* 1. layout asserts (compile-time) + runtime echo */
	_Static_assert(sizeof(struct kevent) == 20, "kevent must be 20B on armv7");
	_Static_assert(sizeof(struct kevent64_s) == 48, "kevent64_s must be 48B");
	_Static_assert(sizeof(struct timespec) == 8, "timespec must be 2x4B on armv7");
	report(1, "struct sizes", "kevent=20B kevent64_s=48B timespec=8B (static)");

	unlink("probe-a"); unlink("probe-a2"); unlink("probe-b");
	int fdA = open("probe-a", O_RDWR | O_CREAT | O_CLOEXEC, 0644);
	int fdB = open("probe-b", O_RDWR | O_CREAT | O_CLOEXEC, 0644);
	if (fdA == -1 || fdB == -1) { perror("open probe files"); return 2; }
	int kq = kqueue();
	report(kq != -1, "kqueue()", kq != -1 ? "" : "kqueue() == -1");

	/* 3. one changelist, two vnode registrations -- element stride proof */
	struct kevent ch[2];
	EV_SET(&ch[0], fdA, EVFILT_VNODE, EV_ADD | EV_CLEAR, NOTE_ALL, 0,
	       (void *)0x00A110CA);
	EV_SET(&ch[1], fdB, EVFILT_VNODE, EV_ADD | EV_CLEAR, NOTE_ALL, 0,
	       (void *)0x00B220CB);
	int rc = kevent(kq, ch, 2, NULL, 0, NULL);
	report(rc == 0, "changelist x2 EVFILT_VNODE", rc == 0 ? "" : "kernel rejected 2-element changelist");

	struct kevent out[8];
	struct timespec t1s = { 1, 0 };
	struct timespec t1ms = { 0, 1000000 };
	int nev;

	/* 4./5. real write on A then B; expect NOTE_WRITE + udata roundtrip */
	for (int round = 0; round < 2; round++) {
		int fd = round == 0 ? fdA : fdB;
		const char *nm = round == 0 ? "probe-a" : "probe-b";
		void *tag = round == 0 ? (void *)0x00A110CA : (void *)0x00B220CB;
		if (write(fd, "x", 1) != 1) { perror("write trigger"); return 2; }
		nev = kevent(kq, NULL, 0, out, 8, &t1s);
		int ok = nev >= 1 && out[0].filter == EVFILT_VNODE &&
			 (out[0].fflags & NOTE_WRITE) && out[0].ident == (uintptr_t)fd &&
			 out[0].udata == tag;
		char d[128];
		snprintf(d, sizeof(d), "%s write -> nev=%d fflags=0x%x ident_ok=%d udata_ok=%d",
			 nm, nev, nev >= 1 ? (unsigned)out[0].fflags : 0u,
			 nev >= 1 ? out[0].ident == (uintptr_t)fd : 0,
			 nev >= 1 ? out[0].udata == tag : 0);
		report(ok, "NOTE_WRITE delivery", ok ? d : d);
	}

	/* 6. rename then unlink deliver RENAME / DELETE on the same udata */
	rename("probe-a", "probe-a2");
	nev = kevent(kq, NULL, 0, out, 8, &t1s);
	int okr = nev >= 1 && (out[0].fflags & NOTE_RENAME) && out[0].udata == (void *)0x00A110CA;
	report(okr, "NOTE_RENAME delivery", "");
	unlink("probe-a2");
	nev = kevent(kq, NULL, 0, out, 8, &t1s);
	int okd = nev >= 1 && (out[0].fflags & NOTE_DELETE) && out[0].udata == (void *)0x00A110CA;
	report(okd, "NOTE_DELETE delivery", "");

	/* 7. pipe + EVFILT_READ + NOTE_LOWAT (entr's stdin trigger) */
	int pp[2];
	if (pipe(pp) == -1) { perror("pipe"); return 2; }
	EV_SET(&ch[0], pp[0], EVFILT_READ, EV_ADD, NOTE_LOWAT, 1, NULL);
	rc = kevent(kq, ch, 1, NULL, 0, NULL);
	write(pp[1], "y", 1);
	nev = kevent(kq, NULL, 0, out, 8, &t1s);
	int okp = rc == 0 && nev >= 1 && out[0].filter == EVFILT_READ && out[0].data >= 1;
	report(okp, "EVFILT_READ NOTE_LOWAT on pipe", "");

	/* 8. kevent64() equivalence on fdB */
	struct kevent64_s ch64;
	EV_SET64(&ch64, fdB, EVFILT_VNODE, EV_ADD | EV_CLEAR, NOTE_WRITE, 0, 0, 0, 0);
	rc = kevent64(kq, &ch64, 1, NULL, 0, 0, NULL);
	write(fdB, "z", 1);
	struct kevent64_s out64[4];
	nev = kevent64(kq, NULL, 0, out64, 4, 0, &t1s);
	int ok64 = rc == 0 && nev >= 1 && (out64[0].fflags & NOTE_WRITE) &&
		   out64[0].ident == (uint64_t)fdB;
	report(ok64, "kevent64() NOTE_WRITE", "");

	/* 9. quiet queue + 1ms timeout returns 0 (timespec path accepted) */
	nev = kevent(kq, NULL, 0, out, 8, &t1ms);
	report(nev == 0, "kevent timeout (timespec) path", "");

	close(fdA); close(fdB); close(pp[0]); close(pp[1]); close(kq);
	unlink("probe-a"); unlink("probe-a2"); unlink("probe-b");

	printf("== %s (%d pass, %d fail)\n", nfail == 0 ? "PROBE ALL PASS" : "PROBE FAILED",
	       npass_n - nfail, nfail);
	return nfail == 0 ? 0 : 1;
}
