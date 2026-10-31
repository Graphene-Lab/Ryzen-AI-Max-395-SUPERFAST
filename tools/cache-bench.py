#!/usr/bin/env python3
"""Measure how much of a long prompt the engine reuses between turns.

The engine reports, for every completion, `timings.cache_n` (tokens taken from
the KV already in the slot) and `timings.prompt_n` (tokens evaluated again).
A turn that finds the cache pays cache_n ~= prompt size and prompt_n ~= 0; a
turn that lost it pays prompt_n = the whole prompt, which at ~350 t/s is the
five-minute stall this benchmark exists to explain.

Each case sends the same long prefix twice, with one variable changed between
the two sends, and reports the second send.

    python tools/cache-bench.py --url http://192.168.43.253:8741 --tokens 20000

Exit status is 0 whatever the numbers are: this is a measuring instrument.
"""

import argparse
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request

SENTENCE = ("Row {i:06d} archives record {j:06d} while the supervisor checks "
            "that nothing in the ledger was dropped by the nightly job. ")


def prefix(n_tokens: int) -> str:
    """~n_tokens of filler; each line is about 26 tokens on this tokenizer."""
    lines, i = [], 0
    while i < n_tokens:
        lines.append(SENTENCE.format(i=i, j=(i * 7919) % 1000003))
        i += 26
    return "".join(lines)


def body(model: str, text: str, tail: str = None, system: str = None, guess: bool = False):
    msgs = [{"role": "system", "content": system or
             "You are a measuring instrument. Answer with one word."}]
    msgs.append({"role": "user", "content": text})
    if tail:
        msgs.append({"role": "assistant", "content": "ok"})
        msgs.append({"role": "user", "content": tail})
    return {"model": model, "messages": msgs, "max_tokens": (1 if guess else 8),
            "temperature": 0, "stream": True, "stream_options": {"include_usage": True}}


def send(url: str, key: str, payload: dict, timeout: int = 1800) -> dict:
    """POST a streamed completion; return ttft, wall, and the engine's counters."""
    req = urllib.request.Request(
        url.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
    )
    t0 = time.time()
    ttft, timings, usage, text = None, {}, {}, ""
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                except ValueError:
                    continue
                for ch in chunk.get("choices") or []:
                    piece = (ch.get("delta") or {}).get("content") or ""
                    if piece and ttft is None:
                        ttft = time.time() - t0
                    text += piece
                if chunk.get("timings"):
                    timings = chunk["timings"]
                if chunk.get("usage"):
                    usage = chunk["usage"]
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        return {"error": "%s: %s" % (type(e).__name__, e)}
    wall = time.time() - t0
    return {
        "ttft": round(ttft if ttft is not None else wall, 3),
        "wall": round(wall, 3),
        "prompt_tokens": usage.get("prompt_tokens"),
        "cached_tokens": (usage.get("prompt_tokens_details") or {}).get("cached_tokens"),
        "cache_n": timings.get("cache_n"),
        "prompt_n": timings.get("prompt_n"),
        "prompt_ms": timings.get("prompt_ms"),
        "prompt_per_second": timings.get("prompt_per_second"),
        "answer": text[:40],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8741")
    ap.add_argument("--model", default="ornith-1.5-35b-a3b")
    ap.add_argument("--tokens", type=int, default=20000, help="approximate prompt size")
    ap.add_argument("--idle", type=int, default=300, help="seconds of silence to test")
    ap.add_argument("--key", default=os.environ.get("SUPERFAST_API_KEY", "local"))
    ap.add_argument("--cases", default="cold,warm,append,head_change,tiny_between,idle")
    ap.add_argument("--burst", nargs="*", default=[],
                    help="captured Qwen Code requests to replay between the two sends")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    text = prefix(a.tokens)
    tiny = body(a.model, "Say OK", guess=True)
    results = {}

    def case(name, first, second, wait=0):
        print("%-14s" % name, end=" ", flush=True)
        r0 = send(a.url, a.key, first)
        print("%s tokens..." % r0.get("prompt_tokens"), end=" ", flush=True)
        if wait:
            time.sleep(wait)
        r1 = send(a.url, a.key, second)
        r1["first"] = r0
        results[name] = r1
        if "error" in r1:
            print("ERROR", r1["error"])
            return
        print("cached %s / prompt %s   ttft %ss" %
              (r1["cache_n"], r1["prompt_tokens"], r1["ttft"]))

    if "cold" in a.cases:
        r = send(a.url, a.key, body(a.model, text))
        results["cold"] = r
        print("%-14s prompt %s tokens, prefill %ss" %
              ("cold", r.get("prompt_tokens"), r.get("ttft")))
    if "warm" in a.cases:
        case("warm", body(a.model, text), body(a.model, text))
    if "append" in a.cases:
        case("append", body(a.model, text), body(a.model, text, tail="Go on."))
    if "head_change" in a.cases:
        case("head_change", body(a.model, text),
             body(a.model, text, system="You are a measuring instrument. Answer in one word."))
    if "tiny_between" in a.cases:
        print("%-14s" % "tiny_between", end=" ", flush=True)
        r0 = send(a.url, a.key, body(a.model, text))
        send(a.url, a.key, tiny)  # one small completion in between
        r = send(a.url, a.key, body(a.model, text))
        r["first"] = r0
        results["tiny_between"] = r
        print("cached %s / prompt %s   ttft %ss" % (r.get("cache_n"), r.get("prompt_tokens"), r.get("ttft")))
    if "idle" in a.cases:
        case("idle_%ds" % a.idle, body(a.model, text), body(a.model, text), wait=a.idle)
    if "burst" in a.cases and a.burst:
        print("%-14s" % "burst", end=" ", flush=True)
        r0 = send(a.url, a.key, body(a.model, text))
        for path in a.burst:
            with open(path, encoding="utf-8") as f:
                d = json.load(f)
            b = d.get("request") or d
            b = {k: v for k, v in b.items() if k in ("messages", "tools", "tool_choice")}
            b.update({"model": a.model, "max_tokens": 1, "stream": True,
                      "stream_options": {"include_usage": True}})
            rb = send(a.url, a.key, b)
            print("[%s tok %s] " % (rb.get("prompt_tokens"), rb.get("cache_n")), end="", flush=True)
        r = send(a.url, a.key, body(a.model, text))
        r["first"] = r0
        results["burst"] = r
        print("cached %s / prompt %s   ttft %ss" % (r.get("cache_n"), r.get("prompt_tokens"), r.get("ttft")))

    if "pburst" in a.cases and a.burst:
        # Qwen Code launches its auto-memory subagents together, so the extra
        # traffic is parallel: that is what over-subscribes one shared window.
        import threading
        print("%-14s" % "pburst", end=" ", flush=True)
        r0 = send(a.url, a.key, body(a.model, text))
        jobs = []
        for path in a.burst:
            with open(path, encoding="utf-8") as f:
                d = json.load(f)
            b = d.get("request") or d
            b = {k: v for k, v in b.items() if k in ("messages", "tools", "tool_choice")}
            b.update({"model": a.model, "max_tokens": 1, "stream": True,
                      "stream_options": {"include_usage": True}})
            jobs.append(b)
        out = {}

        def one(i, payload):
            out[i] = send(a.url, a.key, payload)

        threads = [threading.Thread(target=one, args=(i, p)) for i, p in enumerate(jobs)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        for i in sorted(out):
            print("[%s tok %s] " % (out[i].get("prompt_tokens"), out[i].get("cache_n")), end="", flush=True)
        r = send(a.url, a.key, body(a.model, text))
        r["first"] = r0
        r["burst"] = {str(i): {k: out[i].get(k) for k in ("prompt_tokens", "cache_n", "ttft")} for i in out}
        results["pburst"] = r
        print("cached %s / prompt %s   ttft %ss" % (r.get("cache_n"), r.get("prompt_tokens"), r.get("ttft")))

    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=1)
        print("written", a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
