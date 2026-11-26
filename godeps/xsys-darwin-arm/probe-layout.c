// probe-layout.c — 设备端实测 armv7 iOS 内核结构布局
// 编译: ./cc-wrapper.sh -o probe-layout probe-layout.c
// 用途: 为 x/sys darwin/arm ztypes 提供 ABI 依据

#include <stdio.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <sys/vm.h>
#include <sys/ucred.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>
#include <sys/time.h>

#define O(s, f) printf("  %-28s off=%3zu size=%3zu\n", #f, offsetof(s, f), sizeof(((s*)0)->f))
#define S(s) printf("%-22s size=%3zu align=%2zu\n", #s, sizeof(struct s), _Alignof(struct s))

int main(void) {
	printf("=== armv7 iOS struct layout probe ===\n");

	S(timeval);   O(struct timeval, tv_sec); O(struct timeval, tv_usec);
	S(itimerval); O(struct itimerval, it_interval);

	S(vmspace);
	O(struct vmspace, dummy); O(struct vmspace, dummy2);
	O(struct vmspace, dummy3); O(struct vmspace, dummy4);

	S(_pcred);
	O(struct _pcred, pc_lock); O(struct _pcred, pc_ucred);
	O(struct _pcred, p_ruid);  O(struct _pcred, p_refcnt);

	S(_ucred);
	O(struct _ucred, cr_ref); O(struct _ucred, cr_uid);
	O(struct _ucred, cr_ngroups); O(struct _ucred, cr_groups);

	S(extern_proc);
	O(struct extern_proc, p_un);
	O(struct extern_proc, p_vmspace);
	O(struct extern_proc, p_sigacts);
	O(struct extern_proc, p_flag);
	O(struct extern_proc, p_stat);
	O(struct extern_proc, p_pid);
	O(struct extern_proc, p_oppid);
	O(struct extern_proc, p_dupfd);
	O(struct extern_proc, user_stack);
	O(struct extern_proc, exit_thread);
	O(struct extern_proc, p_debugger);
	O(struct extern_proc, sigwait);
	O(struct extern_proc, p_estcpu);
	O(struct extern_proc, p_cpticks);
	O(struct extern_proc, p_pctcpu);
	O(struct extern_proc, p_wchan);
	O(struct extern_proc, p_wmesg);
	O(struct extern_proc, p_swtime);
	O(struct extern_proc, p_slptime);
	O(struct extern_proc, p_realtimer);
	O(struct extern_proc, p_rtime);
	O(struct extern_proc, p_uticks);
	O(struct extern_proc, p_sticks);
	O(struct extern_proc, p_iticks);
	O(struct extern_proc, p_traceflag);
	O(struct extern_proc, p_tracep);
	O(struct extern_proc, p_siglist);
	O(struct extern_proc, p_textvp);
	O(struct extern_proc, p_holdcnt);
	O(struct extern_proc, p_sigmask);
	O(struct extern_proc, p_sigignore);
	O(struct extern_proc, p_sigcatch);
	O(struct extern_proc, p_priority);
	O(struct extern_proc, p_usrpri);
	O(struct extern_proc, p_nice);
	O(struct extern_proc, p_comm);
	O(struct extern_proc, p_pgrp);
	O(struct extern_proc, p_addr);
	O(struct extern_proc, p_xstat);
	O(struct extern_proc, p_acflag);
	O(struct extern_proc, p_ru);

	S(kinfo_proc);
	O(struct kinfo_proc, kp_proc);
	O(struct kinfo_proc, kp_eproc);
	// eproc 是匿名内嵌类型,用成员指针测
	printf("  (kp_eproc fields below, offsets relative to kinfo_proc)\n");
	printf("  %-28s off=%3zu\n", "e_paddr", offsetof(struct kinfo_proc, kp_eproc) + 0);
	printf("  %-28s off=%3zu\n", "e_sess", offsetof(struct kinfo_proc, kp_eproc) + 4);

	S(tcp_connection_info);
	O(struct tcp_connection_info, tcpi_state);
	O(struct tcp_connection_info, tcpi_options);
	O(struct tcp_connection_info, tcpi_rttvar);
	O(struct tcp_connection_info, tcpi_txpackets);
	O(struct tcp_connection_info, tcpi_txbytes);
	O(struct tcp_connection_info, tcpi_rxoutoforderbytes);
	O(struct tcp_connection_info, tcpi_txretransmitpackets);

	S(sa_endpoints);
	O(struct sa_endpoints, sae_srcif);
	O(struct sa_endpoints, sae_srcaddr);
	O(struct sa_endpoints, sae_srcaddrlen);
	O(struct sa_endpoints, sae_dstaddr);
	O(struct sa_endpoints, sae_dstaddrlen);

	// ip_mreqn
	S(ip_mreqn);
	O(struct ip_mreqn, imr_multiaddr);
	O(struct ip_mreqn, imr_address);
	O(struct ip_mreqn, imr_ifindex);

	printf("=== sizes for constants ===\n");
	printf("sizeof(void*)=%zu sizeof(long)=%zu sizeof(dev_t)=%zu\n",
		sizeof(void*), sizeof(long), sizeof(dev_t));
	printf("sizeof(struct sockaddr_vm check): ");
#ifdef AF_SYS_CONTROL
	printf("AF_SYS_CONTROL=%d\n", AF_SYS_CONTROL);
#else
	printf("no AF_SYS_CONTROL\n");
#endif
	return 0;
}