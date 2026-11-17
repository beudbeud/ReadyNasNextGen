#!/usr/bin/env python3
"""TLS cost of the DIET page refresh, against a real lighttpd (test-api.sh).

  tls-reuse.py HOST PORT USER:PASSWORD N SECONDS

N requests of /cache/status.json on ONE connection, SECONDS apart (keep-alive:
a single TLS handshake must serve them all), then a new connection offering
the session of the first one: it must be resumed (ticket), not a full
handshake. Prints what it saw; exit 0 if both hold.
"""
import base64
import socket
import ssl
import sys
import time

host, port, cred, n, gap = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), float(sys.argv[5])
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
req = ("GET /cache/status.json HTTP/1.1\r\nHost: %s\r\nAuthorization: Basic %s\r\n\r\n"
       % (host, base64.b64encode(cred.encode()).decode())).encode()


def get(s, f):
    s.sendall(req)
    status = f.readline()
    length = 0
    while True:
        line = f.readline()
        if line in (b"\r\n", b""):
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    f.read(length)
    return status


def connect(session=None):
    s = ctx.wrap_socket(socket.create_connection((host, port)), session=session)
    return s, s.makefile("rb")


s, f = connect()
handshakes, ok = 1, 0
for i in range(n):
    if i:
        time.sleep(gap)
    try:
        ok += b" 200 " in get(s, f)
    except OSError:          # closed by the server: a new handshake
        s, f = connect()
        handshakes += 1
        ok += b" 200 " in get(s, f)
session = s.session
s.close()
s2, f2 = connect(session)
get(s2, f2)
resumed = s2.session_reused
print("%d requests %gs apart: %d answered, %d TLS handshake(s); new connection resumed: %s (%s)"
      % (n, gap, ok, handshakes, resumed, s2.version()))
sys.exit(0 if ok == n and handshakes == 1 and resumed else 1)
