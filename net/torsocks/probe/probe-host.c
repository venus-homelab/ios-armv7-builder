/*
 * torsocks feasibility probe -- minimal host program.
 *
 * Ordinary two-level-namespace armv7 Mach-O: calls socket()/connect()
 * to 127.0.0.1:1 (closed port, read-only, no device state touched).
 * If the inserted probe dylib's connect() runs, we see its marker line
 * BEFORE the result line.
 */
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define W(s) write(2, s, sizeof(s) - 1)

int main(void)
{
	int s, r;
	struct sockaddr_in sa;
	char msg[80];

	W("[probe-host] main running\n");
	s = socket(AF_INET, SOCK_STREAM, 0);
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons(1);		/* closed port on localhost */
	sa.sin_addr.s_addr = inet_addr("127.0.0.1");
	r = connect(s, (struct sockaddr *)&sa, sizeof(sa));
	snprintf(msg, sizeof(msg), "[probe-host] socket=%d connect rc=%d\n",
		 s, r);
	write(2, msg, strlen(msg));
	close(s);
	return 0;
}
