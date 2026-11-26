#!/usr/bin/env python3
"""pc-e2e-server.py -- deterministic SOCKS5+HTTP endpoint for
tests/proxychains-e2e.sh.

Listens on 127.0.0.1:<port> (argv[1]); speaks just enough SOCKS5 for
proxychains-ng:

  * greeting 05 01 00 -> reply 05 00 (no auth);
  * CONNECT request: records the ATYP -- a DOMAIN target is the remote-DNS
    proof (the client sent the NAME, not a resolved IP) -- then replies
    success and serves a canned HTTP response for whatever the client
    sends next, regardless of the target host/port.  No network egress.

Every request appends one line to the log file (argv[2]):
    DOMAIN:<hostname>     when the client asked by name
    IP:<addr>             when it asked by address
"""

import socket
import sys
import threading

PORT = int(sys.argv[1])
LOG = sys.argv[2]

CANNED = (
    b"HTTP/1.1 200 OK\r\n"
    b"Content-Type: text/plain\r\n"
    b"Content-Length: 18\r\n"
    b"Connection: close\r\n"
    b"\r\n"
    b"PROXYCHAINS-E2E-OK\n"
)


def log(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")


def handle(conn):
    try:
        # greeting: VER NMETHODS METHODS
        data = conn.recv(32)
        if len(data) < 3 or data[0] != 5:
            return
        conn.sendall(b"\x05\x00")  # no authentication required

        # request: VER CMD RSV ATYP ADDR PORT
        req = b""
        while len(req) < 4:
            chunk = conn.recv(4 - len(req))
            if not chunk:
                return
            req += chunk
        atyp = req[3]
        if atyp == 1:  # IPv4
            addr = conn.recv(4)
            host = socket.inet_ntoa(addr)
            log("IP:%s" % host)
        elif atyp == 3:  # DOMAIN -- the remote-DNS proof
            n = conn.recv(1)[0]
            name = b""
            while len(name) < n:
                chunk = conn.recv(n - len(name))
                if not chunk:
                    return
                name += chunk
            log("DOMAIN:%s" % name.decode())
        elif atyp == 4:  # IPv6
            addr = b""
            while len(addr) < 16:
                chunk = conn.recv(16 - len(addr))
                if not chunk:
                    return
                addr += chunk
            log("IP:%s" % socket.inet_ntop(socket.AF_INET6, addr))
        else:
            return
        conn.recv(2)  # port

        conn.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        conn.recv(4096)  # the client's HTTP request; ignored
        conn.sendall(CANNED)
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", PORT))
srv.listen(8)
srv.settimeout(60)
end = threading.Event()

while not end.is_set():
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        break
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
