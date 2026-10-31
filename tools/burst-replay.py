#!/usr/bin/env python3
"""Replay the requests Qwen Code fires behind the user's back, then measure the cache.

After every turn Qwen Code 0.26.4 launches an auto-memory burst: one recall side
query before the turn and about ten dreamer/extractor completions after it, the
biggest being an ~80k-token prompt. Those occupy the engine's slots and its
prompt cache while the session is idle, so the next user prompt has to be
prefilled again -- the five-minute stall.

This replays a captured burst between two sends of the same long prompt, which
is the session's own history, and reports how much of it the engine still had.
`--logs` is a directory written by `qwen --openai-logging`.

    python tools/burst-replay.py --logs C:/Users/andre/qwen-logs --tokens 100000
"""

import argparse
import glob
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("cb", os.path.join(HERE, "cache-bench.py"))
cb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cb)


def burst(logs, limit, skip=None):
    """The captured requests, oldest first, in the shape the engine received."""
    out = []
    for path in sorted(glob.glob(os.path.join(logs, "*.json"))):
        name = os.path.basename(path)
        if skip and re.search(skip, name):
            continue
        try:
            d = json.load(open(path, encoding="utf-8"))
        except (ValueError, OSError):
            continue
        body = d.get("request") or {}
        if not body.get("messages"):
            continue
        body["max_tokens"] = 1
        body.pop("stream", None)
        body["stream"] = True
        body["stream_options"] = {"include_usage": True}
        out.append((name, body))
    return out[:limit] if limit else out


def show(tag, r):
    if "error" in r:
        print("%-24s ERROR %s" % (tag, r["error"]))
        return
    print("%-24s prompt %7s cached %7s  ttft %6ss" %
          (tag, r.get("prompt_tokens"), r.get("cache_n"), r.get("ttft")))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://192.168.43.253:8741")
    ap.add_argument("--key", default=os.environ.get("SUPERFAST_API_KEY", "local"))
    ap.add_argument("--model", default="ornith-1.5-35b-a3b")
    ap.add_argument("--logs", default="C:/Users/andre/qwen-logs")
    ap.add_argument("--tokens", type=int, default=100000)
    ap.add_argument("--limit", type=int, default=12)
    ap.add_argument("--skip", default="", help="regex on the log file name to leave out")
    a = ap.parse_args()

    text = cb.prefix(a.tokens)
    big = cb.body(a.model, text)
    print("== session prompt, cold or warm")
    show("session (before)", cb.send(a.url, a.key, big))
    for name, payload in burst(a.logs, a.limit, a.skip):
        show(name[-34:], cb.send(a.url, a.key, payload))
    print("== the user's next prompt")
    show("session (after burst)", cb.send(a.url, a.key, big))
    return 0


if __name__ == "__main__":
    sys.exit(main())
