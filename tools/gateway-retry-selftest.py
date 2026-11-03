#!/usr/bin/env python3
"""Self-test for the gateway's answer retry.

Starts a fake engine that answers like llama-server (chunked SSE, and the
peg-native format failure as an SSE event or as a 500 body), puts the real
gateway in front of it, and checks what a client sees. Run from the repo root:

    python tools/gateway-retry-selftest.py
"""
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GATEWAY = os.path.join(HERE, "superfast-gateway.py")
PEG = (b'data: {"error":{"code":500,"message":"The model produced output that '
       b'does not match the expected peg-native format","type":"server_error"}}\n\n')
DONE = b"data: [DONE]\n\n"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def chunk(content=None, reasoning=None, finish=None, cid="chatcmpl-test"):
    delta = {}
    if content is not None:
        delta["content"] = content
    if reasoning is not None:
        delta["reasoning_content"] = reasoning
    body = {"id": cid, "object": "chat.completion.chunk", "created": 1,
            "model": "fake", "choices": [{"index": 0, "delta": delta,
                                          "finish_reason": finish}]}
    return b"data: " + json.dumps(body).encode() + b"\n\n"


class Engine:
    """One answer per connection, in the order the scenarios are declared."""

    def __init__(self, scenarios):
        self.scenarios = list(scenarios)
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.lock = threading.Lock()
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.answer, args=(conn,), daemon=True).start()

    def answer(self, conn):
        conn.settimeout(30)
        buf = b""
        while b"\r\n\r\n" not in buf:
            data = conn.recv(65536)
            if not data:
                conn.close()
                return
            buf += data
        head, _, rest = buf.partition(b"\r\n\r\n")
        length = 0
        for line in head.split(b"\r\n"):
            name, _, value = line.partition(b":")
            if name.strip().lower() == b"content-length":
                length = int(value.strip())
        while len(rest) < length:
            data = conn.recv(65536)
            if not data:
                break
            rest += data
        with self.lock:
            scenario = self.scenarios.pop(0) if self.scenarios else []
        self.write(conn, scenario)

    def write(self, conn, scenario):
        kind = scenario[0] if scenario else "sse"
        if kind == "json":
            status, data = scenario[1], scenario[2]
            try:
                conn.sendall(b"HTTP/1.1 %d X\r\ncontent-type: application/json\r\n"
                             b"content-length: %d\r\nconnection: close\r\n\r\n"
                             % (status, len(data)) + data)
            except Exception:
                pass
            conn.close()
            return
        events = scenario[1:]
        try:
            conn.sendall(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n"
                         b"transfer-encoding: chunked\r\nconnection: close\r\n\r\n")
            for event in events:
                conn.sendall(b"%x\r\n" % len(event) + event + b"\r\n")
                time.sleep(0.01)
            conn.sendall(b"0\r\n\r\n")
        except Exception:
            pass
        conn.close()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def start_gateway(upstream_port):
    port = free_port()
    tmp = tempfile.mkdtemp(prefix="gw-test-")
    key = os.path.join(tmp, "api.key")
    open(key, "wb").close()
    log = open(os.path.join(tmp, "gateway.log"), "wb")
    proc = subprocess.Popen(
        [sys.executable, GATEWAY, "--listen", "127.0.0.1:%d" % port,
         "--upstream", "127.0.0.1:%d" % upstream_port, "--key-file", key,
         "--no-switch", "--allow-empty-retry",
         "--mode-file", os.path.join(tmp, "mode"),
         "--switch-log", os.path.join(tmp, "switch.log")],
        stdout=log, stderr=subprocess.STDOUT)
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return proc, port, log
        except OSError:
            time.sleep(0.05)
    proc.kill()
    raise SystemExit("gateway did not start")


def ask(port, stream=True):
    body = json.dumps({"model": "fake", "stream": stream,
                       "messages": [{"role": "user", "content": "hi"}]}).encode()
    conn = socket.create_connection(("127.0.0.1", port), timeout=60)
    conn.settimeout(60)
    conn.sendall(b"POST /v1/chat/completions HTTP/1.1\r\nhost: x\r\n"
                 b"content-type: application/json\r\n"
                 b"content-length: %d\r\nconnection: close\r\n\r\n" % len(body) + body)
    raw = b""
    while True:
        data = conn.recv(65536)
        if not data:
            break
        raw += data
    conn.close()
    head, _, payload = raw.partition(b"\r\n\r\n")
    return head, dechunk(payload)


def dechunk(body):
    out = b""
    while body:
        line, sep, body = body.partition(b"\r\n")
        try:
            size = int(line.strip() or b"0", 16)
        except ValueError:
            return out + line + (sep + body if sep else b"")
        if size == 0:
            return out
        out += body[:size]
        body = body[size + 2:]
    return out


def events(body):
    return [e.strip() for e in body.split(b"\n\n") if e.strip()]


def payloads(body):
    out = []
    for event in events(body):
        if event.startswith(b"data:") and event[5:].strip() != b"[DONE]":
            out.append(json.loads(event[5:].strip()))
    return out


def text_of(body):
    return "".join((p.get("choices") or [{}])[0].get("delta", {}).get("content") or ""
                   for p in payloads(body))


def run_case(name, scenarios, stream, check):
    engine = Engine(scenarios)
    proc, port, log = start_gateway(engine.port)
    try:
        head, body = ask(port, stream)
        check(head, body)
        print("PASS  " + name)
        return True
    except AssertionError as e:
        log.flush()
        tail = io.open(log.name, "rb").read().decode("utf-8", "replace")
        print("FAIL  %s: %s" % (name, e))
        print("      head=%r body=%r" % (head[:120], body[:600]))
        print("      gateway log:\n" + tail[-1500:])
        return False
    finally:
        proc.kill()
        proc.wait()
        engine.close()


def main():
    ok = True

    def normal(head, body):
        assert b"200" in head.split(b"\r\n")[0], head[:80]
        assert text_of(body) == "hello", text_of(body)
        assert events(body)[-1] == b"data: [DONE]", events(body)[-1]

    ok &= run_case("streaming answer passes through",
                   [["sse", chunk("hello"), chunk(finish="stop"), DONE]], True, normal)

    def after_content(head, body):
        assert text_of(body).startswith("partial text"), text_of(body)
        assert "[gateway]" in text_of(body), text_of(body)
        assert not [p for p in payloads(body) if p.get("error")], "error reached the client"
        final = payloads(body)[-1]
        assert final["choices"][0]["finish_reason"] == "stop", final
        assert events(body)[-1] == b"data: [DONE]", events(body)[-1]

    ok &= run_case("rejection after the text closes the turn",
                   [["sse", chunk("partial text"), PEG]], True, after_content)

    def retried(head, body):
        assert text_of(body) == "second answer", text_of(body)
        assert not [p for p in payloads(body) if p.get("error")], "error reached the client"
        assert events(body)[-1] == b"data: [DONE]", events(body)[-1]

    ok &= run_case("rejection before any text is retried",
                   [["sse", PEG],
                    ["sse", chunk("second answer"), chunk(finish="stop"), DONE]],
                   True, retried)

    def exhausted(head, body):
        # Three attempts, all rejected before any text: the client gets the real
        # error instead of a fourth attempt, so nothing is hidden from it.
        assert [p for p in payloads(body) if p.get("error")], "the error was lost"
        assert "[gateway]" not in text_of(body), text_of(body)

    ok &= run_case("a rejection that repeats is not hidden",
                   [["sse", PEG], ["sse", PEG], ["sse", PEG]], True, exhausted)

    def json_retry(head, body):
        data = json.loads(body)
        assert data["choices"][0]["message"]["content"] == "whole answer", data
        assert b"500" not in head.split(b"\r\n")[0], head[:80]

    ok &= run_case("non-streaming rejection is retried",
                   [["json", 500, b'{"error":{"code":500,"message":"The model '
                                    b'produced output that does not match the '
                                    b'expected peg-native format","type":'
                                    b'"server_error"}}'],
                    ["json", 200, b'{"choices":[{"message":{"role":"assistant",'
                                    b'"content":"whole answer"}}]}']],
                   False, json_retry)

    print("SELFTEST " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
