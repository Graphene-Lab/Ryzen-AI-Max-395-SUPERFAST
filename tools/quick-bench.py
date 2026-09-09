#!/usr/bin/env python3
"""quick-bench.py — short HTTP benchmark for the SUPERFAST engine.

Measures end-to-end wall time and tokens/s per request (greedy, no
streaming). Use it to compare a configuration before and after tuning:
run it, change something, run it again, compare the numbers.

Usage:
    python3 quick-bench.py [--api http://127.0.0.1:8731] [--reps 3] [--max-tokens 192]

Stdlib only; works from the host, a LAN machine, or the laptop.
"""
import argparse
import json
import statistics
import time
import urllib.request

FILLER = ("The unified memory architecture changes how inference engines "
          "schedule work across the accelerator and the host processor. ")

PROMPTS = {
    "prose": "Write a long, detailed essay about local LLM inference on "
             "unified-memory AMD hardware.",
    "code":  "Write a complete, commented Python function that merges two "
             "sorted lists without using the standard library.",
}

def post(api, prompt, max_tokens):
    body = {"messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens, "reasoning_effort": "low"}
    req = urllib.request.Request(
        api + "/v1/chat/completions", json.dumps(body).encode(),
        {"content-type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=900) as r:
        d = json.loads(r.read())
    wall = time.monotonic() - t0
    u = d["usage"]
    return u["prompt_tokens"], u["completion_tokens"], wall

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default="http://127.0.0.1:8731")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=192)
    a = ap.parse_args()

    try:
        with urllib.request.urlopen(a.api + "/health", timeout=10) as r:
            health = json.loads(r.read())
    except Exception as e:
        print("cannot reach %s/health: %s" % (a.api, e))
        return 2
    print("model: %s | context: %s" % (health.get("model", "?"),
                                       health.get("context", "?")))
    print("endpoint: %s | reps: %d | max_tokens: %d" %
          (a.api, a.reps, a.max_tokens))

    # context-size probe: ~2K tokens of filler (repeat until the server sees
    # roughly 2048 prompt tokens), asking for a 1-token answer.
    context = FILLER * 60
    pt, _, _ = post(a.api, context, 1)
    scale = max(1, round(2048 / max(1, pt)))
    context = FILLER * (60 * scale)
    pt, ct, wall = post(a.api, context, 16)
    print("context probe: prompt=%d tok, answer wall %.2fs (%.0f t/s prefill-ish)"
          % (pt, wall, pt / max(wall, 1e-9)))

    for name in ("prose", "code"):
        vals = []
        for _ in range(a.reps):
            pt, ct, wall = post(a.api, PROMPTS[name], a.max_tokens)
            vals.append((pt, ct, wall))
            print("  %s: prompt=%d comp=%d wall=%.2fs -> %.2f t/s" %
                  (name, pt, ct, wall, ct / max(wall, 1e-9)))
        cts = [v[1] for v in vals]
        walls = [v[2] for v in vals]
        rates = [c / max(w, 1e-9) for c, w in zip(cts, walls)]
        print("  %s mean: %.2f t/s  (comp %d tok, wall %.2fs)  min %.2f max %.2f"
              % (name, statistics.fmean(rates), round(statistics.fmean(cts)),
                 statistics.fmean(walls), min(rates), max(rates)))
    return 0

if __name__ == "__main__":
    import sys
    sys.exit(main())
