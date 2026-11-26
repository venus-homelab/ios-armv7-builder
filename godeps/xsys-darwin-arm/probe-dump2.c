#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/socket.h>

int main(void) {
	int mib[6] = {4, 17, 0, 0, 7, 0}; /* AF_UNSPEC, exactly like tailscale netmon */ // CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP2, 0
	size_t len = 0;
	int r = sysctl(mib, 6, NULL, &len, NULL, 0);
	printf("sysctl(NET_RT_DUMP2) = %d errno=%d (%s) size=%zu\n", r, errno, strerror(errno), len);
	int mib3[6] = {4, 17, 0, 2, 1, 0}; // NET_RT_DUMP
	len = 0;
	r = sysctl(mib3, 6, NULL, &len, NULL, 0);
	printf("sysctl(NET_RT_DUMP)  = %d errno=%d (%s) size=%zu\n", r, errno, strerror(errno), len);
	return 0;
}
