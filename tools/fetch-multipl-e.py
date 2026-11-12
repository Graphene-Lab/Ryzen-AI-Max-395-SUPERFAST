"""Build multipl_e_cs.jsonl from the Hugging Face datasets server.

The runner needs name/prompt/tests for the 158 humaneval-cs rows. Keeping the
file in the repository is what makes a re-run possible at all: the copies used
in 2026-10 lived outside it, and a run cannot be repeated from the archives
alone.
"""
import json
import urllib.request

URL = ("https://datasets-server.huggingface.co/rows?dataset=nuprl%2FMultiPL-E"
       "&config=humaneval-cs&split=test&offset={offset}&length={length}")
OUT = "benchmarks/multipl-e/multipl_e_cs.jsonl"

rows = []
offset = 0
while True:
    with urllib.request.urlopen(URL.format(offset=offset, length=100), timeout=60) as r:
        page = json.load(r)
    batch = page["rows"]
    if not batch:
        break
    rows += [b["row"] for b in batch]
    offset += len(batch)
    if offset >= page["num_rows_total"]:
        break

with open(OUT, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps({"name": row["name"], "prompt": row["prompt"],
                             "tests": row["tests"]}, ensure_ascii=False) + "\n")

print(f"{len(rows)} righe in {OUT}")
