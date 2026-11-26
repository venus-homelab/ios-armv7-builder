/*
 * torsocks feasibility probe -- injected dylib.
 *
 * Answers on-device (iPad4 / iOS 10.3.3, mobile user):
 *   1. does DYLD_INSERT_LIBRARIES load this library into a self-built
 *      armv7 binary at all, under which signing state?
 *   2. with DYLD_FORCE_FLAT_NAMESPACE=1 (the mechanism torsocks's own
 *      wrapper uses on Darwin), does a plain exported `connect`
 *      definition in the inserted library actually REPLACE libSystem's
 *      for a two-level-namespace host binary?
 *
 * Prints markers with raw write(2) so stdio buffering cannot hide them.
 */
#include <unistd.h>
#include <dlfcn.h>
#include <sys/socket.h>

#define W(s) write(2, s, sizeof(s) - 1)

__attribute__((constructor)) static void probe_lib_init(void)
{
	W("[probe-lib] constructor: dylib IS loaded\n");
}

typedef int (*connect_fn)(int, const struct sockaddr *, socklen_t);

int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen)
{
	static connect_fn real_connect;

	W("[probe-lib] connect() INTERPOSED by inserted dylib\n");
	if (!real_connect) {
		*(void **)&real_connect = dlsym(RTLD_NEXT, "connect");
		if (!real_connect) {
			W("[probe-lib] dlsym(RTLD_NEXT, connect) FAILED\n");
			return -1;
		}
	}
	return real_connect(sockfd, addr, addrlen);
}
