#!/usr/bin/env python3
"""tools/bench-concurrent.py — what several agents at once actually cost.

Run ON the box (it reads the container's log for the engine's own ledger):

    python3 tools/bench-concurrent.py [clients] [prefix_words] [max_tokens] [reps] [mode]

    python3 tools/bench-concurrent.py 4 120000 16384 2 shared

The prefix argument counts WORDS of the fixed filler below, not tokens: this
word list tokenizes to about 1.25 tokens per word, so 80000 produces prompts of
~101,000 tokens. Every run prints the prompt size the engine actually reported,
and that number — not the argument — is the one to reason about, because the
reservation a request takes out of the KV pool is prompt + max_tokens.

WHY THIS EXISTS. `tools/bench-serving.py` answers "which drafter is faster" and
runs one request at a time with 11-token prompts. That is the wrong instrument
for the question this machine gets asked in practice — a client that opens
subagents, or two people using it at once — where the engine has to arbitrate
between conversations. Wall clock per request then depends on things the
single-stream bench cannot see: how many conversations fit the KV pool, how many
slots decode at once, and how long a request waits for room.

MODE decides the cache story, and it is the difference between two very
different runs:

    shared    every client sends the same prefix, like subagents sharing one
              system prompt and tool set. Only the first client prefills it.
    distinct  every client sends its own prefix, like unrelated conversations.
              Every client prefills everything, which is the worst case.

WHAT IT REPORTS. Per request: wall clock, tokens, the engine's own numbers for
that request (prompt, cached, prefill) taken from the ledger lines the api
prints, and the queue wait it implies — wall minus prefill minus the decode time
a solo request would need at SOLO_TPS. Then the batch totals: aggregate tokens
per second across all clients, the mean per-client rate, and how much of the
wall clock was spent waiting rather than decoding. A batch where every stream
runs at 38 t/s and one where every stream runs at 13 t/s with the same aggregate
are NOT the same machine, and only these columns tell them apart.

Recognising which of the engine's ledger lines are this run's own is the whole
difficulty of measuring a live box, and it is done with a fingerprint: every
client asks for the same distinctive `max_tokens`, and each response reports its
own prompt length, so a line is ours when its generated-token count equals
MAXTOK and its prompt length falls in the band the clients reported. Two other
approaches were tried on a box with agents running and both were wrong: counting
log-tail lines attributed two of the live agents' 107K-prompt requests to this
benchmark's 3K clients, and asking for the non-speculative `serial` drafter as a
tag hid the very lines it was meant to mark, because a serial request prints no
ledger line at all.
"""

import json
import os
import re
import statistics
import subprocess
import sys
import threading
import time
import urllib.request

API = os.environ.get("SUPERFAST_API", "http://127.0.0.1:8731")
CTR = os.environ.get("SUPERFAST_API_CTR", "ornith-server")
SOLO_TPS = float(os.environ.get("SUPERFAST_SOLO_TPS", "38.5"))
# Making this run's own requests identifiable is the whole difficulty of
# measuring a live box. Two things do not work, both measured: counting tail
# lines (the window scrolls, and a smoke run attributed two of the live agents'
# 107K-prompt requests to this benchmark's 3K clients), and asking for the
# `serial` drafter as a tag (a non-speculative drafter prints NO ledger line at
# all, so the tag hid the very lines it was meant to mark). What works is a
# fingerprint: every client here asks for the same distinctive max_tokens, and
# each response reports its own prompt_tokens, so the engine's lines are the
# recent ones whose generated-token count equals MAXTOK and whose prompt length
# falls in the band the clients reported. MAXTOK is therefore what separates
# this run from the live traffic, which generates its own varied counts.
DRAFTER = os.environ.get("SUPERFAST_BENCH_DRAFTER", "mtp")

CLIENTS = int(sys.argv[1]) if len(sys.argv) > 1 else 4
PREFIX = int(sys.argv[2]) if len(sys.argv) > 2 else 120000
MAXTOK = int(sys.argv[3]) if len(sys.argv) > 3 else 16384
REPS = int(sys.argv[4]) if len(sys.argv) > 4 else 1
MODE = sys.argv[5] if len(sys.argv) > 5 else "shared"

LEDGER = re.compile(
    r"serve_api: (\w+) (\d+) tok in ([\d.]+)s = ([\d.]+) t/s"
    r"(?: \| (\d+) rounds, commit ([\d.]+)/round)?"
    r" \| prompt (\d+)(?: \((\d+) cached\))?, prefill ([\d.]+)s")

# A deterministic word pool: the same client count and prefix length must build
# the same prompt on every run, or two runs are not comparable.
WORDS = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima "
         "mike november oscar papa quebec romeo sierra tango uniform victor whiskey "
         "xray yankee zulu archive buffer cache delta engine figure gradient horizon "
         "index jitter kernel latency margin node offset packet quantum ratio signal "
         "throughput unit vector window yield zone").split()


def filler(tokens, nonce):
    """About `tokens` tokens of text that is stable per (tokens, nonce)."""
    out, n = [], 0
    i = nonce
    while n < tokens:
        w = WORDS[i % len(WORDS)]
        out.append(w)
        n += 1
        i += 7
    return " ".join(out)


def logs():
    out = subprocess.run(["podman", "logs", "--tail", "20000", CTR],
                         capture_output=True, text=True)
    return out.stdout + out.stderr


def mine(lo, hi):
    """This run's ledger lines: the right drafter, MAXTOK tokens out, and a
    prompt length inside the band the clients themselves reported."""
    lines = [m for m in LEDGER.findall(logs())
             if m[0] == DRAFTER and int(m[1]) == MAXTOK and lo <= int(m[6]) <= hi]
    return lines


def one(prompt, results, idx):
    body = json.dumps({"messages": [{"role": "user", "content": prompt}],
                       "max_tokens": MAXTOK, "drafter": DRAFTER}).encode()
    req = urllib.request.Request(API + "/v1/chat/completions", body,
                                 {"content-type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=7200) as r:
            d = json.loads(r.read())
        results[idx] = (time.time() - t0, d["usage"]["completion_tokens"],
                        d["usage"].get("prompt_tokens"), None)
    except Exception as exc:  # noqa: BLE001 - reported, not raised
        results[idx] = (time.time() - t0, 0, None, str(exc)[:120])


def run_batch(rep):
    prompts, results = [], {}
    for i in range(CLIENTS):
        if MODE == "shared":
            head = "You are one of several agents sharing this context.\n"
            prompts.append(head + filler(PREFIX, 0))
        else:
            head = "Conversation %d, unique to this client.\n" % (rep * 100 + i)
            prompts.append(head + filler(PREFIX, rep * 1000 + i))
    start = threading.Barrier(CLIENTS)

    def go(i):
        start.wait()
        one(prompts[i], results, i)

    threads = [threading.Thread(target=go, args=(i,), daemon=True) for i in range(CLIENTS)]
    t0 = time.time()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    batch_wall = time.time() - t0

    got = {i: results.get(i, (0.0, 0, None, "no result")) for i in range(CLIENTS)}
    seen = [p for (_, _, p, _) in got.values() if p]
    lo = int(min(seen) * 0.98) if seen else 0
    hi = int(max(seen) * 1.02) if seen else 10 ** 9
    candidates = mine(lo, hi)
    stats = candidates[-CLIENTS:] if candidates else []

    print("\n--- rep %d: %d clients, %d-token prefix, %d max_tokens, mode %s, drafter %s ---" % (
        rep, CLIENTS, PREFIX, MAXTOK, MODE, DRAFTER))
    print("batch wall %.1f s; own ledger lines %d of %d (fingerprint: %d tokens out, "
          "prompt %d-%d)%s" % (
              batch_wall, len(stats), CLIENTS, MAXTOK, lo, hi,
              "" if len(stats) == CLIENTS else "  <-- fewer than one per client"))
    # Client side first, and it is exact: each thread timed its own request.
    print("%7s %9s %8s %8s %9s" % ("client", "wall_s", "tok", "t/s", "prompt_tok"))
    tok_per_client, wall_per_client = [], []
    for i in range(CLIENTS):
        wall, tok, ptok, err = got[i]
        tok_per_client.append(tok)
        wall_per_client.append(wall)
        print("%7d %9.1f %8d %8.2f %9s%s" % (i, wall, tok, tok / wall if wall else 0,
                                             ptok or "?", "  ERR " + err if err else ""))
    # Then the engine's own numbers for this batch. They are NOT mapped to
    # clients: the ledger line carries no client id, only the order in which
    # requests finished, so pairing them row by row would be a guess.
    if stats:
        print("%5s %9s %9s %10s %11s %9s" % ("#", "prompt", "cached", "prefill_s",
                                             "engine_wall", "engine_t/s"))
        for j, st in enumerate(stats):
            print("%5d %9s %9s %10.1f %11.1f %9.2f" % (
                j, st[6], st[7] or 0, float(st[8]), float(st[2]), float(st[3])))
    mwall = statistics.mean(wall_per_client)
    mtok = statistics.mean(tok_per_client)
    mpref = statistics.mean(float(st[8]) for st in stats) if stats else 0.0
    mcach = statistics.mean(int(st[7] or 0) / max(int(st[6]), 1) for st in stats) if stats else 0.0
    wait = mwall - mpref - mtok / SOLO_TPS
    print("aggregate %.1f tok/s over %d clients; mean per-client %.2f t/s; "
          "mean wall %.1f s; mean prefill %.1f s; cache hit %.0f%%" % (
              sum(tok_per_client) / max(batch_wall, 1e-9), CLIENTS,
              statistics.mean(t / max(w, 1e-9) for t, w in zip(tok_per_client, wall_per_client)),
              mwall, mpref, 100.0 * mcach))
    print("estimated mean wait %.1f s per request (%.0f%% of the wall clock): wall "
          "minus prefill minus the %.1f s a solo decode of %d tokens takes" % (
              wait, 100.0 * wait / max(mwall, 1e-9), mtok / SOLO_TPS, mtok))
    return sum(tok_per_client) / max(batch_wall, 1e-9)


if __name__ == "__main__":
    print("bench-concurrent: %d clients x %d reps, prefix %d tokens, max_tokens %d, mode %s" % (
        CLIENTS, REPS, PREFIX, MAXTOK, MODE))
    print("SOLO_TPS %.1f (the rate one client alone gets on this machine) is what "
          "the wait column is measured against" % SOLO_TPS)
    for rep in range(REPS):
        run_batch(rep)
