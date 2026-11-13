#!/usr/bin/env python3
"""slowpost.py <megabytes> <KB per second> [host] [address]
An upload like the Nextcloud app's on a slow line: HTTP/1.1, one TCP connection, the body
sent at a fixed rate. Used to make the edge mark this machine's address as "uploading on a
slow line" (lua/npm_upload_window.lua, mark()). Prints status and seconds."""
import socket, ssl, sys, time
mb, rate = float(sys.argv[1]), float(sys.argv[2]) * 1024
host = sys.argv[3] if len(sys.argv) > 3 else "h3test.example.org"
addr = sys.argv[4] if len(sys.argv) > 4 else "172.31.250.10"
total = int(mb * 1024 * 1024)
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
ctx.set_alpn_protocols(["http/1.1"])
s = ctx.wrap_socket(socket.create_connection((addr, 443), timeout=120), server_hostname=host)
s.sendall(("POST /upload HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\n"
           "Content-Type: application/octet-stream\r\nConnection: close\r\n\r\n" % (host, total)).encode())
piece = bytes(16384); sent = 0; t0 = time.monotonic()
while sent < total:
    n = min(len(piece), total - sent)
    s.sendall(piece[:n]); sent += n
    ahead = sent / rate - (time.monotonic() - t0)
    if ahead > 0:
        time.sleep(ahead)
answer = b""
while b"\r\n" not in answer:
    got = s.recv(4096)
    if not got:
        break
    answer += got
print(answer.split(b"\r\n")[0].decode(errors="replace"), round(time.monotonic() - t0, 1))
