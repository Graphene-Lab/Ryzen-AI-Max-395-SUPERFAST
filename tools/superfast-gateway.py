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

## The empty-response retry

A few times per run the engine answers a well-formed HTTP request with a body
that is empty or does not describe the requested model. That body reaches the
client, and Qwen Code reports "400 status code (no body)". The request was
valid; the response was the bad half. When the gateway detects an empty answer
on an OpenAI completion route it re-sends the *same* query (up to RESEND_MAX
tries, RESEND_WAIT seconds apart) before ever sending an answer to the client:
a retry that the engine already proved works. It is off by default, so removing
the flag reverts to the plain relay.
"""
import argparse
import fcntl
import hmac
import json
import os
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


def send_empty_retry(upstream, head, body):
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
            if whole.strip() and not is_empty_body(whole):
                log("empty-response retry succeeded on attempt %d" % attempt)
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


def is_empty_body(body: bytes) -> bool:
    """True when the upstream answer carries no completion.

    Zero bytes is the "400 status code (no body)" the client reports; a JSON
    object that names no choices is the same empty answer with a 200 around it.
    A body that carries an error object is a real answer, not an empty one.
    """
    if not body.strip():
        return True
    try:
        data = json.loads(body)
    except Exception:
        return False
    return (isinstance(data, dict) and "error" not in data
            and data.get("choices") in (None, []))


def wants_stream(body: bytes) -> bool:
    """True when the client asked for a streamed completion (SSE)."""
    try:
        return json.loads(body).get("stream") is True
    except Exception:
        return False


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
        if allow_empty_retry and whole is not None and not wants_stream(whole):
            # A valid request can still draw an empty answer or a 200 with no
            # "choices". Re-send it up to RESEND_MAX times, reading each reply
            # whole, so a transient empty answer is repaired before the client
            # ever sees it.
            retry = send_empty_retry(upstream, head, whole)
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
    except Exception:
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
                    help="on an empty OpenAI completion answer, resend the "
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
    print("gateway %s -> %s (auth: %s, mode: %s, empty-retry: %s)"
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
