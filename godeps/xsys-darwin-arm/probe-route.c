#include <stdlib.h>
// probe-route.c — 设备端验证 PF_ROUTE socket / sysctl 路由表权限
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#define PF_ROUTE 17
#define AF_ROUTE 17
#define NET_RT_DUMP 1
#define NET_RT_FLAGS 2
#define RTF_UP 0x1
#include <unistd.h>

int main(void) {
	printf("uid=%d euid=%d\n", getuid(), geteuid());

	int s = socket(PF_ROUTE, SOCK_RAW, 0);
	printf("socket(PF_ROUTE,SOCK_RAW,0) = %d errno=%d (%s)\n", s, errno, strerror(errno));
	if (s >= 0) close(s);

	s = socket(PF_ROUTE, SOCK_RAW, AF_INET);
	printf("socket(PF_ROUTE,SOCK_RAW,AF_INET) = %d errno=%d (%s)\n", s, errno, strerror(errno));
	if (s >= 0) close(s);

	int mib[6] = {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0};
	size_t len = 0;
	if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0) {
		printf("sysctl(NET_RT_DUMP) size probe: errno=%d (%s)\n", errno, strerror(errno));
	} else {
		printf("sysctl(NET_RT_DUMP) ok, table size=%zu\n", len);
		char *buf = malloc(len);
		if (buf && sysctl(mib, 6, buf, &len, NULL, 0) == 0) {
			printf("sysctl(NET_RT_DUMP) read ok (%zu bytes)\n", len);
		} else {
			printf("sysctl(NET_RT_DUMP) read: errno=%d (%s)\n", errno, strerror(errno));
		}
		free(buf);
	}

	int mib2[6] = {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_UP};
	len = 0;
	int r = sysctl(mib2, 6, NULL, &len, NULL, 0);
	printf("sysctl(NET_RT_FLAGS,RTF_UP) = %d errno=%d size=%zu\n", r, errno, len);
	return 0;
}