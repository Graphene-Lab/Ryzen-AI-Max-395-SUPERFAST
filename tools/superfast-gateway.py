#!/usr/bin/env python3
"""superfast-gateway — the API-key gate in front of the local LLM service.

The engine and the orchestrator listen on loopback. If you want to reach them
from another computer, run this gateway on the host: it listens on the LAN,
requires a bearer key, and forwards everything else untouched (including
streaming responses).

    python3 superfast-gateway.py --listen 0.0.0.0:8741 --upstream 127.0.0.1:8731 \
        --key-file ~/.config/superfast/api.key

Clients then use http://<host>:8741 and send:
    Authorization: Bearer <key>
or  X-API-Key: <key>

## The automatic profile switch

With `superfast-switch mode auto`, this gateway also reads the `model` field
of each request, maps it to a profile (`superfast-switch profile-for`) and
switches when — and only when — the engine is idle. An agent sends a turn
every few seconds, so switching mid-session would cost a full reload and drop
the prompt cache: while the engine is busy the gateway answers 409 with the
profile that is loaded, the one that was asked for, and a retry hint, and it
touches nothing.

## The answer retry

A few times per run the engine answers a well-formed HTTP request with a body
that is empty or does not describe the requested model. That body reaches the
client, and Qwen Code reports "400 status code (no body)". The request was
valid; the response was the bad half. When the gateway detects an empty answer
on an OpenAI completion route it re-sends the *same* query (up to RESEND_MAX
tries, RESEND_WAIT seconds apart) before ever sending an answer to the client:
a retry that the engine already proved works.

The engine also refuses its own generation. llama.cpp's PEG parser rejects a
tool call the model formatted badly and ends the request with "The model
produced output that does not match the expected peg-native format" — a 500 for
a non-streaming request, the same error inside the SSE stream for a streaming
one, after the text has already been delivered. Qwen Code cannot recover from
that without the user, so an unattended run stops there. The gateway repairs it
too: while nothing of the answer has reached the client the request is re-sent,
and once text has been delivered the stream is closed with a normal finish
instead of the error, so the run continues.

It is off by default, so removing the flag reverts to the plain relay.
"""
import argparse
import fcntl
import hmac
import json
import os
import re
import socket
import subprocess
import threading
import time

CONF = os.path.expanduser("~/.config/superfast")
MAX_BODY = 16 * 1024 * 1024
SWITCH_TIMEOUT = 900

# A profile that is starting is not a failure: ornith reads its weights in about
# 25 s and the ple-disk flash takes minutes with its drafter, so a request that
# arrives in that window waits here instead of being told 409. The bound keeps a
# truly stuck engine from holding a client for ever; after it the client gets the
# same refusal it would have had at once.
LOAD_WAIT = 600
LOAD_POLL = 3

# The engine answers a well-formed request with an empty body (no HTTP status
# left in it, no "choices" describing a model) a few times per run. The request
# was valid; the response was the bad half, and the client turns it into a
# "400 status code (no body)". This is not a failure the client can see the
# reason for, and re-sending the identical query is what the engine already
# proved works on the next try: retry it before ever returning an answer, so
# the client never sees the empty response. --allow-empty-retry turns it on;
# off by default, so removing the flag reverts to the plain relay.
RESEND_MAX = 5
RESEND_WAIT = 1

# A streamed answer is read event by event so that a rejected tool call can be
# repaired before it reaches the client. FORMAT_RETRY_MAX counts attempts, not
# retries: the first attempt is the request itself. The note is what the model
# and the user see in place of a tool call the engine dropped after the text had
# already been delivered.
FORMAT_RETRY_MAX = 3
FORMAT_NOTE = ("\n\n[gateway] the engine dropped the model's tool call because "
               "it could not be parsed; the turn ends here.")
# Generous on purpose: a local model can stay silent for minutes while it
# prefills a long prompt, and dropping the connection early is worse than
# waiting. The idle bound only catches an engine that never answers at all.
CONNECT_TIMEOUT = 60
IDLE_TIMEOUT = 3600
# llama.cpp separates SSE events with a bare blank line; a proxy in between may
# use CRLF, so the boundary is matched either way.
EVENT_END = re.compile(rb"\r?\n\r?\n")
SWITCH = "superfast-switch"
MODE_FILE = os.path.join(CONF, "mode")
SWITCH_LOG = os.path.join(CONF, "switch.log")

_models = {}
_models_lock = threading.Lock()

STATE_MESSAGE = {
    "in_use": "the engine is serving; retry, or switch between conversations",
    "switching": "another request is already switching the profile",
    "unavailable": "the engine is not answering; 'superfast-switch recover' is the repair",
}


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
    """True when the request carries the key.

    The header value is compared exactly (as bytes, in constant time) instead
    of searching for the key anywhere in the header block: a substring match
    would accept any value that merely *contains* the key.
    """
    if not key:
        return True
    for line in head.split(b"\r\n"):
        name, sep, value = line.partition(b":")
        if not sep:
            continue
        if name.strip().lower() not in (b"authorization", b"x-api-key"):
            continue
        value = value.strip()
        if value[:7].lower() == b"bearer ":
            value = value[7:].strip()
        if hmac.compare_digest(value, key):
            return True
    return False


def read_head(client):
    """The header block, and the first bytes of the body that came with it.

    A client sends head and body in the same write, so the first recv almost
    always carries both. Splitting here is what keeps the body from being read
    twice — and from blocking a read that waits for bytes already consumed.
    """
    buf = b""
    while b"\r\n\r\n" not in buf and len(buf) < 65536:
        chunk = client.recv(4096)
        if not chunk:
            break
        buf += chunk
    head, sep, rest = buf.partition(b"\r\n\r\n")
    return head + sep, rest


def parse_head(head: bytes):
    headers = {}
    for line in head.split(b"\r\n")[1:]:
        name, sep, value = line.partition(b":")
        if sep:
            headers[name.strip().lower().decode("latin-1")] = value.strip().decode("latin-1")
    return headers


def read_body(client, headers, already):
    """The whole body (starting with the bytes read with the head), or None.

    Chunked uploads and very large bodies are left in the socket for the
    relay: inspecting them would mean buffering, and the field we want is at
    the front of every JSON body anyway.
    """
    if "chunked" in headers.get("transfer-encoding", "").lower():
        return None
    try:
        n = int(headers.get("content-length", "0"))
    except ValueError:
        return None
    if n <= 0 or n > MAX_BODY:
        return None
    body = already
    while len(body) < n:
        chunk = client.recv(n - len(body))
        if not chunk:
            return None
        body += chunk
    return body[:n]


def respond(client, code, reason, payload):
    data = json.dumps(payload).encode()
    try:
        client.sendall(b"HTTP/1.1 %d %s\r\n" % (code, reason.encode())
                       + b"content-type: application/json\r\n"
                       + b"content-length: %d\r\n" % len(data)
                       + b"connection: close\r\n\r\n" + data)
    except Exception:
        pass


def mode():
    try:
        with open(MODE_FILE) as f:
            return "auto" if f.read().strip() == "auto" else "pinned"
    except OSError:
        return "pinned"


def cli(args, timeout):
    return subprocess.run([SWITCH] + args, capture_output=True, text=True,
                          timeout=timeout)


def profile_for(model):
    with _models_lock:
        if model in _models:
            return _models[model]
    try:
        r = cli(["profile-for", model], 10)
        prof = r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        # A missing CLI is not an error the client should see: without it the
        # gateway is the plain relay it was before.
        return ""
    with _models_lock:
        # Only a hit is cached: caching a miss would keep the gateway blind to
        # an id added to the settings after it started.
        if prof:
            _models[model] = prof
    return prof


def engine_state():
    try:
        out = cli(["state"], 20).stdout
    except Exception:
        return {}
    state = {}
    for token in out.split():
        name, _, value = token.partition("=")
        state[name] = value
    return state


def log(line):
    try:
        os.makedirs(os.path.dirname(SWITCH_LOG), exist_ok=True)
        with open(SWITCH_LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), line))
    except OSError:
        pass


def refuse(active, requested, state, retry_after):
    return {
        "error": {
            "message": "%s is not the loaded profile (it is %s: %s)"
                       % (requested, active, STATE_MESSAGE[state]),
            "type": "profile_" + state,
            "code": "profile_" + state,
        },
        "active": active,
        "requested": requested,
        "state": state,
        "retry_after": retry_after,
    }


def switch_to(active, target):
    """Switch under a lock. Returns None when the request may go on."""
    lock = os.path.join(CONF, "gateway-switch.lock")
    try:
        os.makedirs(CONF, exist_ok=True)
        fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
    except OSError:
        return None
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return refuse(active, target, "switching", 30)
        # Re-read: another request may have switched while this one waited,
        # and the engine may have started serving in the meantime.
        state = engine_state()
        current = state.get("active", active)
        if current == target:
            return None
        if state.get("busy") != "0" or state.get("queued", "0") != "0":
            return refuse(current, target, "in_use", 40)
        started = time.time()
        env = dict(os.environ, SUPERFAST_AUTO="1")
        try:
            r = subprocess.run([SWITCH, "use", target], env=env, capture_output=True,
                               text=True, timeout=SWITCH_TIMEOUT)
            ok = r.returncode == 0
            detail = (r.stderr or r.stdout).strip().splitlines()
            detail = detail[-1] if detail else "no output"
        except Exception as e:
            ok, detail = False, str(e)
        log("switch %s -> %s %s in %.0fs (%s)" % (current, target, "ok" if ok else "failed",
                                                  time.time() - started, detail))
        if ok:
            return None
        return {
            "error": {
                "message": "could not switch to %s: %s" % (target, detail),
                "type": "switch_failed",
                "code": "switch_failed",
            },
            "active": current,
            "requested": target,
            "state": "failed",
        }
    finally:
        os.close(fd)


def is_loading(profile):
    """True while that profile's unit is up but its engine does not answer yet."""
    try:
        r = cli(["loading", profile], 20)
    except Exception:
        return False
    return r.returncode == 0 and r.stdout.strip() == "1"


def wait_for_load(target):
    """Wait while `target` is starting, then return the state read afterwards."""
    started = time.time()
    while time.time() - started < LOAD_WAIT:
        time.sleep(LOAD_POLL)
        state = engine_state()
        if state.get("responds") == "1" and state.get("active") == target:
            log("waited %.0fs for %s to load" % (time.time() - started, target))
            return state
        if not is_loading(target):
            break
    state = engine_state()
    log("gave up waiting for %s after %.0fs (active=%s responds=%s)"
        % (target, time.time() - started, state.get("active"), state.get("responds")))
    return state


def decide(body):
    """None to forward the request, or the payload to answer with."""
    try:
        model = json.loads(body).get("model")
    except Exception:
        return None
    if not isinstance(model, str) or not model:
        return None
    target = profile_for(model)
    if not target:
        return None
    state = engine_state()
    active = state.get("active", "none")
    if target == active and state.get("responds") == "1":
        return None
    if state.get("responds") != "1" or target == active:
        # A profile that is starting is not a failure: the request waits for the
        # load and then goes through, which is what a client that does not retry
        # needs. An engine that is down gets the refusal at once, because there
        # is nothing to wait for.
        if not is_loading(target):
            return refuse(active, target, "unavailable", 60)
        state = wait_for_load(target)
        active = state.get("active", active)
        if state.get("responds") != "1" or target != active:
            return refuse(active, target, "unavailable", 30)
        return None
    if state.get("busy") != "0" or state.get("queued", "0") != "0":
        return refuse(active, target, "in_use", 40)
    return switch_to(active, target)


def send_answer_retry(upstream, head, body):
    """Return the first non-empty answer to the same query, or None.

    The request was valid; the reply was the bad half. Re-send it against the
    upstream up to RESEND_MAX times, RESEND_WAIT seconds apart, reading each
    reply whole, and return the raw response (head + body) of the first answer
    that is not empty. Return None when every attempt comes back empty, when a
    reply cannot be read whole (a streaming/chunked body), or on a connect
    error, so the caller falls through to the ordinary relay and the client
    still gets an answer instead of a new failure.
    """
    for attempt in range(1, RESEND_MAX + 1):
        up = None
        try:
            up = socket.create_connection(upstream, timeout=30)
            up.sendall(head.replace(b"Connection: keep-alive", b"Connection: close") + body)
            up.settimeout(None)
            head2, rest2 = read_head(up)
            whole = read_body(up, parse_head(head2), rest2) if head2 else None
            if whole is None:
                return None  # streaming/chunked reply: not ours to judge whole
            if whole.strip() and not is_empty_body(whole, head):
                log("answer retry succeeded on attempt %d" % attempt)
                return head2 + whole
        except Exception:
            return None
        finally:
            if up is not None:
                try:
                    up.shutdown(socket.SHUT_RDWR)
                except Exception:
                    pass
        time.sleep(RESEND_WAIT)
    log("empty-response retry exhausted after %d attempts" % RESEND_MAX)
    return None


def is_format_failure(answer) -> bool:
    """True when an answer reports the engine's model-output format failure.

    llama.cpp refuses a generation its PEG tool-call parser cannot read and
    words it "The model produced output that does not match the expected
    <format> format". The name varies (peg-native, peg-simple, Content-only), so
    the match is on the wording. The same text arrives in a 500 body, in a
    non-streaming completion body, or inside an SSE event.
    """
    raw = answer if isinstance(answer, (bytes, bytearray)) else json.dumps(answer).encode()
    low = raw.lower()
    return b"does not match the expected" in low and b"format" in low


def is_empty_body(body: bytes, head: bytes = b"") -> bool:
    """True when the upstream answer carries no usable completion.

    Zero bytes is the "400 status code (no body)" the client reports; a JSON
    object that names no choices is the same empty answer with a 200 around it.
    On a completion route an error object that reports a model-output format
    failure is unusable too: the engine refused its own generation. Any other
    error object is a real answer, not an empty one.
    """
    if not body.strip():
        return True
    try:
        data = json.loads(body)
    except Exception:
        return False
    if not isinstance(data, dict):
        return False
    if "error" in data:
        return is_format_failure(data) and is_completion(head)
    return data.get("choices") in (None, [])


class BodyReader:
    """One response body, de-chunked when the upstream chunked it.

    The gateway re-frames a stream for the client, so it has to read the
    upstream framing itself. `read()` returns the next piece and b"" at the end.
    """

    def __init__(self, sock, chunked):
        self.sock = sock
        self.chunked = chunked
        self.buf = b""

    def _fill(self):
        try:
            data = self.sock.recv(65536)
        except Exception:
            data = b""
        if not data:
            return False
        self.buf += data
        return True

    def _line(self):
        while b"\r\n" not in self.buf:
            if not self._fill():
                return None
        line, _, self.buf = self.buf.partition(b"\r\n")
        return line

    def read(self):
        if not self.chunked:
            if not self.buf and not self._fill():
                return b""
            piece, self.buf = self.buf, b""
            return piece
        line = self._line()
        if line is None:
            return b""
        try:
            size = int(line.split(b";")[0].strip() or b"0", 16)
        except ValueError:
            return b""
        if size == 0:
            self._line()  # the CRLF that follows the last-chunk line
            return b""
        while len(self.buf) < size + 2 and self._fill():
            pass
        piece, self.buf = self.buf[:size], self.buf[size + 2:]
        return piece


def send_chunk(client, data):
    """One HTTP chunk: the body the gateway writes is framed by the gateway."""
    if data:
        client.sendall(b"%x\r\n" % len(data) + data + b"\r\n")


def end_chunks(client):
    client.sendall(b"0\r\n\r\n")


def sse_head(head2: bytes) -> bytes:
    """The upstream 200 head, re-framed: the gateway chunk-encodes the body."""
    lines = [line for line in head2.split(b"\r\n") if line]
    keep = [lines[0]] if lines else [b"HTTP/1.1 200 OK"]
    for line in lines[1:]:
        name = line.split(b":", 1)[0].strip().lower()
        if name in (b"transfer-encoding", b"content-length", b"connection"):
            continue
        keep.append(line)
    keep.append(b"transfer-encoding: chunked")
    keep.append(b"connection: close")
    return b"\r\n".join(keep) + b"\r\n\r\n"


def classify_event(event: bytes):
    """('error' | 'final' | 'content' | '', payload) for one SSE event."""
    payload = b""
    for line in event.split(b"\n"):
        line = line.strip()
        if line.startswith(b"data:"):
            payload = line[5:].strip()
    if payload == b"[DONE]":
        return "final", {}
    if not payload:
        return "", {}
    try:
        data = json.loads(payload)
    except Exception:
        return "", {}
    if not isinstance(data, dict):
        return "", {}
    if data.get("error"):
        return "error", data
    for choice in data.get("choices") or []:
        delta = choice.get("delta") or {}
        if (delta.get("content") or delta.get("reasoning_content")
                or delta.get("tool_calls")):
            return "content", data
    return "", data


def flush_out(client, head2, events, sent, finish=True):
    """Send the held answer, then close the chunked body."""
    if not sent:
        client.sendall(head2)
    for event in events:
        send_chunk(client, event)
    if finish:
        end_chunks(client)


def close_turn(client, head2, held, meta, sent):
    """End a stream whose answer was rejected after text reached the client.

    The attempt cannot be re-sent: its text is already in the client's message
    and a second answer would be appended to the first. The rejected event is
    replaced by a normal finish, so the client keeps the text it has and the run
    goes on instead of stopping on an error it cannot repair.
    """
    flush_out(client, head2, held, sent, finish=False)
    base = {
        "id": meta.get("id") or "chatcmpl-gateway",
        "object": "chat.completion.chunk",
        "created": meta.get("created") or int(time.time()),
        "model": meta.get("model") or "",
    }
    note = dict(base, choices=[{"index": 0, "delta": {"content": FORMAT_NOTE},
                                "finish_reason": None}])
    final = dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}])
    send_chunk(client, b"data: " + json.dumps(note).encode() + b"\n\n")
    send_chunk(client, b"data: " + json.dumps(final).encode() + b"\n\n")
    send_chunk(client, b"data: [DONE]\n\n")
    end_chunks(client)


def run_stream(reader, client, head2: bytes, attempt: int) -> bool:
    """Relay one streamed attempt; True when the client has been answered.

    False means the attempt was rejected before any text was forwarded, so the
    caller can send the same request again without the client ever noticing.
    """
    out = sse_head(head2)
    held = []
    sent = False
    text = False
    meta = {}
    buf = b""
    while True:
        piece = reader.read()
        if not piece:
            flush_out(client, out, held, sent)
            return True
        buf += piece
        while True:
            end = EVENT_END.search(buf)
            if end is None:
                break
            event, buf = buf[:end.end()], buf[end.end():]
            kind, data = classify_event(event)
            if data and not meta.get("id"):
                meta = data
            if kind == "error":
                if is_format_failure(event):
                    if not text and attempt < FORMAT_RETRY_MAX:
                        log("answer retry %d: the engine rejected the model's "
                            "output before any text was sent" % attempt)
                        return False
                    if not text:
                        # Nothing reached the client, and the budget is spent:
                        # hand it the real error rather than nothing at all.
                        flush_out(client, out, held + [event], sent)
                        return True
                    log("answer retry %d: the engine rejected the model's output "
                        "after text was sent, closing the turn" % attempt)
                    close_turn(client, out, held, meta, sent)
                    return True
                flush_out(client, out, held + [event], sent)
                return True
            if kind == "content":
                text = True
            if not text and kind != "final":
                held.append(event)
                continue
            if not sent:
                client.sendall(out)
                for held_event in held:
                    send_chunk(client, held_event)
                held = []
                sent = True
            send_chunk(client, event)
            if kind == "final":
                end_chunks(client)
                return True


def read_until_close(sock) -> bytes:
    """The rest of a short (non-streamed) answer, bounded by MAX_BODY."""
    out = b""
    try:
        while len(out) < MAX_BODY:
            data = sock.recv(65536)
            if not data:
                break
            out += data
    except Exception:
        pass
    return out


def stream_answer(upstream, head, body, client) -> bool:
    """Answer a streamed completion, repairing the engine's own rejections.

    Returns True when the client has been answered; False tells the caller to
    fall back to the plain relay (the upstream connection never opened).
    """
    for attempt in range(1, FORMAT_RETRY_MAX + 1):
        up = None
        head2 = b""
        try:
            up = socket.create_connection(upstream, timeout=CONNECT_TIMEOUT)
            up.settimeout(IDLE_TIMEOUT)
            up.sendall(head.replace(b"Connection: keep-alive", b"Connection: close") + body)
            head2, rest = read_head(up)
            if not head2:
                return False
            parts = head2.split(b" ", 2)
            status = parts[1] if len(parts) > 1 else b""
            if status != b"200":
                whole = rest + read_until_close(up)
                if is_format_failure(whole) and attempt < FORMAT_RETRY_MAX:
                    log("answer retry %d: the engine answered %s with a rejected "
                        "answer" % (attempt, status.decode("latin-1", "replace")))
                    continue
                client.sendall(head2 + whole)
                return True
            reader = BodyReader(
                up, "chunked" in parse_head(head2).get("transfer-encoding", ""))
            reader.buf = rest
            if run_stream(reader, client, head2, attempt):
                return True
        except Exception as e:
            # Once the upstream answered, the client may hold part of it: a
            # second relay would generate the answer again, so only a request
            # that never got a response falls back to the plain relay.
            log("answer retry aborted: %s" % e)
            return bool(head2)
        finally:
            if up is not None:
                try:
                    up.shutdown(socket.SHUT_RDWR)
                except Exception:
                    pass
    return False


def wants_stream(body: bytes) -> bool:
    """True when the client asked for a streamed completion (SSE)."""
    try:
        return json.loads(body).get("stream") is True
    except Exception:
        return False


def is_completion(head: bytes) -> bool:
    """True when the request line targets an OpenAI completion route.

    Only completion answers carry `choices`; a `/v1/models` (or any other)
    answer has none, so judging it by `is_empty_body` would retry it five times
    for nothing. The request line is the first line of the header block.
    """
    return b"/completions" in head.split(b"\r\n", 1)[0]


def handle(client, upstream, key, auto, allow_empty_retry):
    try:
        client.settimeout(30)
        head, rest = read_head(client)
        if not head:
            return
        if not authorized(head, key):
            return respond(client, 401, "Unauthorized",
                           {"error": {"message": "missing or invalid API key",
                                      "type": "auth_error"}})
        headers = parse_head(head)
        auto_mode = auto and mode() == "auto"
        inspect = auto_mode or allow_empty_retry
        # A client that waits for "100 Continue" has not sent its body yet;
        # without this the read below would block until it gives up.
        if inspect and headers.get("expect", "").lower() == "100-continue":
            client.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
        whole = read_body(client, headers, rest) if inspect else None
        body = whole if whole is not None else rest
        if auto_mode and whole is not None:
            answer = decide(whole)
            if answer:
                code = 409 if answer.get("state") != "failed" else 502
                return respond(client, code,
                               "Conflict" if code == 409 else "Bad Gateway", answer)
        if allow_empty_retry and whole is not None and is_completion(head):
            # A valid request can still draw an answer the engine itself refuses
            # — an empty body, or a tool call its PEG parser rejected. Repair it
            # before the client ever sees it.
            if wants_stream(whole):
                if stream_answer(upstream, head, whole, client):
                    return
            else:
                # A whole (non-streamed) answer is judged whole and re-sent.
                retry = send_answer_retry(upstream, head, whole)
                if retry is not None:
                    client.sendall(retry)
                    return
        up = socket.create_connection(upstream, timeout=30)
        up.settimeout(None)
        client.settimeout(None)
        up.sendall(head.replace(b"Connection: keep-alive", b"Connection: close") + body)
        t = threading.Thread(target=relay, args=(up, client), daemon=True)
        t.start()
        relay(client, up)
    except Exception as e:
        log("request failed: %r" % e)
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
    global SWITCH, MODE_FILE, SWITCH_LOG
    ap = argparse.ArgumentParser(description="API-key gate for SUPERFAST endpoints")
    ap.add_argument("--listen", default="0.0.0.0:8741")
    ap.add_argument("--upstream", default="127.0.0.1:8731")
    ap.add_argument("--key-file", required=True)
    ap.add_argument("--mode-file", default=MODE_FILE)
    ap.add_argument("--switch-cmd", default="")
    ap.add_argument("--switch-log", default=SWITCH_LOG)
    ap.add_argument("--no-switch", action="store_true",
                    help="forward everything; never switch the profile")
    ap.add_argument("--allow-empty-retry", action="store_true",
                    help="on an unusable OpenAI completion answer (empty, or a "
                         "tool call the engine's parser rejected), resend the "
                         "same query before sending anything to the client")
    a = ap.parse_args()
    MODE_FILE = a.mode_file
    SWITCH_LOG = a.switch_log
    if a.switch_cmd:
        SWITCH = a.switch_cmd
    else:
        local = os.path.expanduser("~/.local/bin/superfast-switch")
        SWITCH = local if os.access(local, os.X_OK) else "superfast-switch"
    auto = not a.no_switch
    allow_empty_retry = a.allow_empty_retry
    try:
        key = open(a.key_file, "rb").read().strip()
    except FileNotFoundError:
        key = b""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(parse_addr(a.listen))
    srv.listen(64)
    print("gateway %s -> %s (auth: %s, mode: %s, answer-retry: %s)"
          % (a.listen, a.upstream, "on" if key else "OFF",
             "auto" if auto else "pinned",
             "on" if allow_empty_retry else "off"), flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle,
                         args=(c, parse_addr(a.upstream), key, auto, allow_empty_retry),
                         daemon=True).start()


if __name__ == "__main__":
    main()
