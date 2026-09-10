#!/usr/bin/env python3
"""superfast-gateway — a tiny API-key gate in front of the local LLM service.

The engine and the orchestrator listen on loopback. If you want to reach them
from another computer, run this gateway on the host: it listens on the LAN,
requires a bearer key, and forwards everything else untouched (including
streaming responses).

    python3 superfast-gateway.py --listen 0.0.0.0:8741 --upstream 127.0.0.1:8731 \
        --key-file ~/.config/superfast/api.key

Clients then use http://<host>:8741 and send:
    Authorization: Bearer <key>
or  X-API-Key: <key>
"""
import argparse
import socket
import sys
import threading


def relay(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass


def authorized(head: bytes, key: bytes) -> bool:
    if not key:
        return True
    for line in head.split(b"\r\n"):
        low = line.lower()
        if low.startswith(b"authorization:") and key in line:
            return True
        if low.startswith(b"x-api-key:") and key in line:
            return True
    return False


def handle(client, upstream, key):
    try:
        client.settimeout(30)
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 65536:
            chunk = client.recv(4096)
            if not chunk:
                return
            head += chunk
        if not authorized(head, key):
            body = b'{"error":{"message":"missing or invalid API key","type":"auth_error"}}'
            client.sendall(b"HTTP/1.1 401 Unauthorized\r\n"
                           b"content-type: application/json\r\n"
                           b"content-length: %d\r\nconnection: close\r\n\r\n" % len(body) + body)
            return
        up = socket.create_connection(upstream, timeout=30)
        up.settimeout(None)
        client.settimeout(None)
        up.sendall(head.replace(b"Connection: keep-alive", b"Connection: close"))
        t = threading.Thread(target=relay, args=(up, client), daemon=True)
        t.start()
        relay(client, up)
    except Exception as e:
        try:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\n\r\n")
        except Exception:
            pass
    finally:
        try:
            client.close()
        except Exception:
            pass


def parse_addr(s):
    host, _, port = s.rpartition(":")
    return (host or "0.0.0.0", int(port))


def main():
    ap = argparse.ArgumentParser(description="API-key gate for SUPERFAST endpoints")
    ap.add_argument("--listen", default="0.0.0.0:8741")
    ap.add_argument("--upstream", default="127.0.0.1:8731")
    ap.add_argument("--key-file", required=True)
    a = ap.parse_args()
    try:
        key = open(a.key_file, "rb").read().strip()
    except FileNotFoundError:
        key = b""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(parse_addr(a.listen))
    srv.listen(64)
    print("gateway %s -> %s (auth: %s)" % (a.listen, a.upstream, "on" if key else "OFF"), flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c, parse_addr(a.upstream), key), daemon=True).start()


if __name__ == "__main__":
    main()
