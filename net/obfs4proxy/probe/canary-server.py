#!/usr/bin/env python3
# Minimal canned HTTP target for the obfs4proxy loopback E2E (host side).
# Sits in the TOR_PT_ORPORT slot: the host obfs4proxy server relays the
# de-obfuscated tunnel traffic here.  Logs every accepted connection and
# the first request bytes to stderr = the on-console evidence that the
# traffic crossed the whole loop.
#
# Usage: canary-server.py <bind> <port>
import socket
import sys
import threading

CANNED = (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
          b"Content-Length: 18\r\nConnection: close\r\n\r\n"
          b"obfs4proxy-E2E-OK\r\n")


def client(c, addr):
    try:
        data = c.recv(4096)
        sys.stderr.write("CANARY-REQ from %s: %r\n" % (addr[0], data[:80]))
        sys.stderr.flush()
        c.sendall(CANNED)
    except Exception as e:
        sys.stderr.write("CANARY-ERR %s\n" % e)
        sys.stderr.flush()
    finally:
        c.close()


def main():
    bind, port = sys.argv[1], int(sys.argv[2])
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((bind, port))
    s.listen(8)
    sys.stderr.write("CANARY listening %s:%d\n" % (bind, port))
    sys.stderr.flush()
    while True:
        c, addr = s.accept()
        threading.Thread(target=client, args=(c, addr), daemon=True).start()


if __name__ == "__main__":
    main()
