import socket, threading, sys

# Minimal SOCKS5 server for the torsocks real-library E2E on the device.
# Speaks the two phases torsocks actually drives:
#   phase 1  SOCKS5 RESOLVE (tor extension, CMD 0xF0)  -> BND.ADDR =
#            93.184.216.34 (a plausible example.com address)
#   phase 2  SOCKS5 CONNECT to that IP:80             -> success, then
#            relay one canned HTTP response.
# Logs every request (CMD/ATYP/target) to stderr = on-console evidence.

CANNED = (b"HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n"
          b"\r\ntorsocks-E2E-OK\r\n")

def read_req(c):
    d = c.recv(512)
    if not d or d[0] != 5:
        raise ValueError("req %r" % d)
    cmd, atyp = d[1], d[3]
    if atyp == 3:
        n = d[4]
        host = d[5:5 + n].decode()
        rest = d[5 + n:]
    elif atyp == 1:
        host = ".".join(str(b) for b in d[4:8])
        rest = d[8:]
    else:
        host = "atyp%d" % atyp
        rest = d[20:]
    return cmd, host, int.from_bytes(rest[:2], "big"), atyp

def client(c):
    try:
        d = c.recv(64)
        if not d or d[0] != 5:
            raise ValueError("greeting %r" % d)
        methods = d[2:2 + d[1]]
        if 0 in methods:
            c.sendall(b"\x05\x00")
        elif 2 in methods:
            c.sendall(b"\x05\x02")
            _ = c.recv(128)
        else:
            raise ValueError("methods %r" % methods)
        cmd, host, port, atyp = read_req(c)
        sys.stderr.write("E2E-REQ cmd=0x%02x atyp=%d target=%s:%d\n"
                         % (cmd, atyp, host, port))
        sys.stderr.flush()
        if cmd == 0xF0:                      # RESOLVE: hand out a real-ish IP
            c.sendall(b"\x05\x00\x00\x01" + bytes([93, 184, 216, 34])
                      + b"\x00\x50")
        else:                                # CONNECT: success + canned page
            c.sendall(b"\x05\x00\x00\x01" + bytes([93, 184, 216, 34])
                      + b"\x00\x50")
            data = c.recv(4096)
            sys.stderr.write("E2E-DATA %r\n" % data[:80])
            sys.stderr.flush()
            c.sendall(CANNED)
    except Exception as e:
        sys.stderr.write("E2E-ERR %s\n" % e)
        sys.stderr.flush()
    finally:
        c.close()

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 9108))
s.listen(8)
sys.stderr.write("E2E-SRV listening 9108\n")
sys.stderr.flush()
while True:
    c, _ = s.accept()
    threading.Thread(target=client, args=(c,)).start()
