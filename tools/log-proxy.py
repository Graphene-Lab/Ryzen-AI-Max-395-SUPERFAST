#!/usr/bin/env python3
"""Recording proxy: dumps each completion request and the engine's own counters.

Sits between a Qwen Code client and the gateway, forwards bytes unchanged and
writes, per request, the JSON body plus a CSV row with the prefix-cache figures
the engine reports: `timings.cache_n` (tokens reused) against `prompt_n`
(tokens evaluated again). A turn that lost the cache pays prompt_n = the whole
history, which at ~350 t/s is the five-minute stall this instrument exists to
explain.

Handles `Content-Length` and `Transfer-Encoding: chunked` bodies, streams the
reply as it arrives, and keeps the tail of the reply to read the final
`timings`/`usage` objects out of the SSE stream.

    python tools/log-proxy.py --listen 127.0.0.1:8751 --upstream 192.168.43.253:8741

Point a client at http://127.0.0.1:8751/v1, then read the CSV it writes.
"""

import argparse
import csv
import json
import os
import re
import socket
import threading
import time

TIMINGS = re.compile(rb'"timings"\s*:\s*\{[^{}]*\}')
USAGE = re.compile(rb'"prompt_tokens_details"\s*:\s*\{[^{}]*\}')
TAIL = 262144


def read_head(sock):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            return None, b""
        buf += chunk
    head, rest = buf.split(b"\r\n\r\n", 1)
    return head, rest


def header(head, name):
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.strip().lower() == name.lower().encode():
            return v.strip().decode("latin1")
    return None


def dechunk(data):
    """Body bytes out of a chunked encoding, best effort."""
    out, i = b"", 0
    while i < len(data):
        end = data.find(b"\r\n", i)
        if end < 0:
            break
        try:
            size = int(data[i:end].split(b";")[0], 16)
        except ValueError:
            break
        if size == 0:
            break
        out += data[end + 2:end + 2 + size]
        i = end + 2 + size + 2
    return out


def read_body(sock, head, rest):
    """Return (raw bytes to forward, decoded body for the dump)."""
    te = (header(head, "transfer-encoding") or "").lower()
    if "chunked" in te:
        raw = rest
        while not raw.endswith(b"0\r\n\r\n"):
            chunk = sock.recv(65536)
            if not chunk:
                break
            raw += chunk
        return raw, dechunk(raw)
    n = header(head, "content-length")
    if not n:
        return b"", b""
    raw = rest
    while len(raw) < int(n):
        chunk = sock.recv(65536)
        if not chunk:
            break
        raw += chunk
    return raw, raw


def numbers(tail):
    """The cache counters out of the reply tail."""
    got = {}
    m = None
    for m in TIMINGS.finditer(tail):
        pass
    if m:
        try:
            got.update(json.loads(b"{" + m.group(0) + b"}")["timings"])
        except ValueError:
            pass
    m = None
    for m in USAGE.finditer(tail):
        pass
    if m:
        try:
            d = json.loads(b"{" + m.group(0) + b"}")["prompt_tokens_details"]
            got["cached_tokens"] = d.get("cached_tokens")
        except ValueError:
            pass
    return got


def handle(client, upstream, cfg, state):
    head, rest = read_head(client)
    if head is None:
        client.close()
        return
    raw, body = read_body(client, head, rest)
    t0 = time.time()
    clean = b"\r\n".join(l for l in head.split(b"\r\n")
                         if not l.lower().startswith(b"connection:")) + b"\r\nConnection: close"

    with state["lock"]:
        state["n"] += 1
        idx = state["n"]
    info = {"id": idx, "bytes": len(body), "t": time.strftime("%H:%M:%S")}
    if body:
        try:
            req = json.loads(body)
            info["messages"] = len(req.get("messages") or [])
            info["tools"] = len(req.get("tools") or [])
            with open(os.path.join(cfg["out"], "%03d.json" % idx), "wb") as f:
                f.write(body)
        except ValueError:
            pass

    up = socket.create_connection(upstream, timeout=30)
    up.sendall(clean + b"\r\n\r\n")
    if raw:
        up.sendall(raw)
    tail, ttft = b"", None
    try:
        while True:
            data = up.recv(65536)
            if not data:
                break
            if ttft is None:
                ttft = time.time() - t0
            client.sendall(data)
            tail = (tail + data)[-TAIL:]
    except OSError:
        pass
    finally:
        up.close()
        client.close()

    info.update(numbers(tail))
    info["ttft"] = round(ttft if ttft is not None else time.time() - t0, 3)
    info["wall"] = round(time.time() - t0, 3)
    with state["lock"], open(cfg["csv"], "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["id", "t", "messages", "tools", "bytes", "ttft", "wall",
                                          "prompt_n", "cache_n", "prompt_ms", "cached_tokens"])
        w.writerow({k: info.get(k) for k in w.fieldnames})
    print(" ".join("%s=%s" % (k, info[k]) for k in
                   ("id", "t", "messages", "tools", "bytes", "ttft", "prompt_n", "cache_n")), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="127.0.0.1:8751")
    ap.add_argument("--upstream", default="192.168.43.253:8741")
    ap.add_argument("--out", default="qwen-payloads")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    cfg = {"out": a.out, "csv": os.path.join(a.out, "requests.csv")}
    with open(cfg["csv"], "w", newline="", encoding="utf-8") as f:
        csv.DictWriter(f, fieldnames=["id", "t", "messages", "tools", "bytes", "ttft", "wall",
                                      "prompt_n", "cache_n", "prompt_ms", "cached_tokens"]).writeheader()
    host, port = a.listen.rsplit(":", 1)
    uhost, uport = a.upstream.rsplit(":", 1)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, int(port)))
    srv.listen(16)
    print("listening on %s -> %s, records in %s" % (a.listen, a.upstream, cfg["csv"]), flush=True)
    state = {"n": 0, "lock": threading.Lock()}
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client, (uhost, int(uport)), cfg, state),
                         daemon=True).start()


if __name__ == "__main__":
    main()
