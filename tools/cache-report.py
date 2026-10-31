#!/usr/bin/env python3
"""Report the prefix-cache reuse and time-to-first-token of past Qwen Code calls.

Every completion Qwen Code makes is written to the chat transcript as a
`qwen-code.api_response` telemetry row carrying `input_token_count`,
`cached_content_token_count` and `ttft_ms`. The first two say how much of the
history the engine had to evaluate again; `ttft_ms` says what the user waited
for. Reuse near zero on a long history is the five-minute stall, measured on
real sessions instead of on a synthetic prompt.

    python tools/cache-report.py --root C:/Users/andre/.qwen/projects --model ornith --csv out.csv
"""

import argparse
import glob
import json
import os
import statistics
import sys


def rows(root, model):
    for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        if path.endswith(".ledger.jsonl"):
            continue
        try:
            fh = open(path, encoding="utf-8")
        except OSError:
            continue
        with fh:
            for line in fh:
                if "cached_content_token_count" not in line:
                    continue
                try:
                    rec = json.loads(line)
                    ev = rec["systemPayload"]["uiEvent"]
                except (ValueError, KeyError):
                    continue
                if ev.get("event.name") != "qwen-code.api_response":
                    continue
                if model and model not in str(ev.get("model", "")):
                    continue
                yield {
                    "session": os.path.basename(path)[:-6],
                    "time": ev.get("event.timestamp", ""),
                    "model": ev.get("model", ""),
                    "input": ev.get("input_token_count") or 0,
                    "cached": ev.get("cached_content_token_count") or 0,
                    "out": ev.get("output_token_count") or 0,
                    "ttft": ev.get("ttft_ms") or 0,
                    "dur": ev.get("duration_ms") or 0,
                    "status": ev.get("status_code"),
                }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="C:/Users/andre/.qwen/projects")
    ap.add_argument("--model", default="ornith")
    ap.add_argument("--min-input", type=int, default=0)
    ap.add_argument("--csv", default="")
    a = ap.parse_args()

    data = [r for r in rows(a.root, a.model) if r["input"] >= a.min_input]
    data.sort(key=lambda r: r["time"])
    if not data:
        print("no api_response rows")
        return 1

    print("%-19s %-9s %8s %8s %6s %8s %8s" %
          ("time", "session", "input", "cached", "reuse", "ttft_s", "eval_t/s"))
    for r in data:
        reuse = 100.0 * r["cached"] / r["input"] if r["input"] else 0
        fresh = max(r["input"] - r["cached"], 1)
        rate = fresh / (r["ttft"] / 1000.0) if r["ttft"] else 0
        print("%-19s %-9s %8d %8d %5.0f%% %8.1f %8.0f" %
              (r["time"][:19], r["session"][:9], r["input"], r["cached"], reuse,
               r["ttft"] / 1000.0, rate))

    print("\n%d calls, sessions:" % len(data))
    for s in sorted({r["session"] for r in data}):
        mine = [r for r in data if r["session"] == s]
        low = [r for r in mine if r["input"] and r["cached"] / r["input"] < 0.5]
        print("  %-36s %3d calls, %2d under 50%% reuse, median ttft %.1fs" %
              (s, len(mine), len(low), statistics.median(r["ttft"] for r in mine) / 1000.0))
    ttfts = [r["ttft"] / 1000.0 for r in data]
    print("\nmedian ttft %.1fs, worst %.1fs, total wait %.1f min" %
          (statistics.median(ttfts), max(ttfts), sum(ttfts) / 60.0))
    if a.csv:
        import csv
        with open(a.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(data[0]))
            w.writeheader()
            w.writerows(data)
        print("written", a.csv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
