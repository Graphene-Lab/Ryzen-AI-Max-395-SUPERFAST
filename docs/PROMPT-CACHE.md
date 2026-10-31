# The prompt cache on the ornith profile

A long session on this machine sometimes waits minutes before the first token
of a new prompt. This page records the measurement of that wait, what causes
it, and the two levers that change it. Every number was taken on this host
with the instruments listed at the end.

## What the wait is

The engine reports, for every completion, how many prompt tokens it took from
the state it already held (`cache_n`) and how many it evaluated again
(`prompt_n`). On a session of 126,977 tokens:

| state of the engine | reused | evaluated again | first token |
| --- | --- | --- | --- |
| warm | 126,973 | 4 | 0.7 s |
| after 168k of other requests | 0 | **126,977** | **273 s** |

Prefill runs at 320-460 tokens per second, so the wait grows with the session:
127k costs four to seven minutes, 200k costs more. That is the "five minutes"
a user sees.

## What it is not

**It is not a server-side timeout.** A warm 127k prompt sent again after 330 s
of silence reused 126,973 tokens in 0.62 s, and the same after 600 s. The cache
does not expire; there is no idle flush to lengthen.

**It is not Qwen Code changing the prompt.** The system message and the tool
list are byte-identical between turns and between sessions (36,049 characters,
10 tools), and the message list only grows. The harness does not touch the
prefix.

## What it is

**Ornith-1.5 has hybrid/recurrent layers, so reuse is all-or-nothing.** The
engine cannot resume from a partial prefix and says so:

```
forcing full prompt re-processing due to lack of cache data
(likely due to SWA or hybrid/recurrent memory)
```

It resumes only from the checkpoints it stores every 8,192 tokens — up to 32
per prompt, 62.8 MiB each; the state of a 127k prompt is 2,545 MiB.

**The prompt cache holds at most `n_ctx` tokens across every saved prompt.**
The engine prints its own limits:

```
cache state: 1 prompts, 3613.216 MiB (limits: 8192.000 MiB, 262144 tokens, ...)
```

`--cache-ram` moves the first figure (16384 was tried and confirmed) and leaves
the second one at 262,144. A session therefore keeps its state only while the
traffic between two of its own requests stays inside that token budget; when it
does not, the engine saves the newcomer and the session's entry is the one
evicted, because it is the oldest.

**Qwen Code 0.26.4 supplies exactly that traffic.** After every turn it runs one
`auto-memory-recall` side query and eight to ten `auto-memory-dreamer` /
`extractor` completions, launched in parallel. One ordinary turn of this
repository produced ten such requests; replayed against this engine, the four
largest are 82,670 + 31,119 + 28,837 + 27,107 = 169,733 tokens, and the others
are smaller. The client's own log of that turn (`qwen --openai-logging`) shows
the shape, with the token counts of the model it happened to run on:

```
MAIN  27,895 prompt   3,840 cached   (the user's turn)
bg     7,708          384            recall side query
bg    80,465        5,248            extractor
bg    16,210-29,601 9,216-27,520     eight dreamers
```

Both halves are needed for the stall: a warm session is fine until that traffic
arrives, and the traffic is fine while the session is short. Put together, on a
session of ~127k, the pair exceeds the 262,144-token budget and the next user
prompt is prefilled from zero.

A second, smaller factor was real and is now gone. The vision drop-in
(`ornith.service.d/override.conf`) replaces the unit's `ExecStart`, and the copy
installed on this host predated the `--parallel 1` fix of 2026-10-19, so the
engine ran `n_parallel = 4 and kv_unified = true` with four sequences over the
single 262,144-position window. The probe below shows the slot count is not what
decides this stall, but four sessions sharing one window is never what the
reference machine asked for, and it also costs memory.

## The measurement

The probe: send a long prompt, send the auto-memory traffic, send the same long
prompt again, read `cache_n` on the last send. The traffic replayed is the real
captured burst (82,670 + 31,119 + 28,837 + 27,107 tokens).

| engine | traffic between the two sends | reused | first token |
| --- | --- | --- | --- |
| 4 slots | 82,670 tokens, one request | 126,973 | 1.3 s |
| 1 slot | 82,670 tokens, one request | 126,973 | 1.2 s |
| 4 slots | 169,733 tokens, four requests, sequential | **0** | **273 s** |
| 4 slots | 169,733 tokens, four requests, parallel | **0** | **283 s** |
| 1 slot | 169,733 tokens, four requests, parallel | **0** | **275 s** |

The row that matters is the boundary between 82k and 170k: 127k + 82k = 209k
fits the 262,144-token budget, 127k + 170k = 296k does not. Pinning one slot
does not move that boundary, which is why the flag alone does not cure the
stall.

## The two levers

**Fewer background tokens.** Qwen Code exposes both halves as settings, in
`settings.json` or in the status dialog of the TUI:

```json
{ "memory": { "enableManagedAutoDream": false } }
```

`enableManagedAutoDream` is eight of the ten requests; what remains is one
extractor of about 82k tokens. Measured: 82k of extra traffic against a 127k
session still leaves the whole prompt cached (first row of the table), so
turning the dreamer off brings a session of up to about 180k back inside the
budget. `memory.enableManagedAutoMemory` removes the extractor as well, at the
cost of the background memory maintenance itself. Above roughly 180k of session
even the extractor alone exceeds the budget, and the only cure is to keep the
background work off this model — for example by running that client against a
model that is not the one being chatted with.

**One slot, as the reference machine says.** `--parallel 1` must sit in the
drop-in as well as in the unit: a drop-in that sets `ExecStart=` replaces the
whole command line, so the flag in `deploy/profiles/ornith.service` does not
survive it. The repository templates already carry it; the installed copy on
this host did not. `deploy/setup-fedora.sh` now verifies `ornith:--parallel 1`
in the effective `ExecStart`, the way it already verified it for gemma, so the
drift shows up at the end of an install instead of as a five-minute wait.

## Instruments

- `tools/cache-bench.py` — sends the probe above and reports `cache_n`,
  `prompt_n` and the time to first token. `--cases pburst` replays captured
  requests in parallel; `--burst` takes the files written by
  `qwen --openai-logging`.
- `tools/cache-report.py` — reads the `qwen-code.api_response` rows of past
  sessions (`~/.qwen/projects/*/chats/*.jsonl`) and prints, per call, the reuse
  percentage and the time to first token. On this machine it showed the shape of
  the problem before any synthetic test existed: reuse is 93-100% inside a turn
  and has a median of 0% on the 312 calls that follow a gap of five minutes or
  more.
- `tools/log-proxy.py` — a recording TCP proxy for a client that cannot write
  its own logs; `tools/payload-diff.py` compares two captured requests and names
  the first message that differs.
- `tools/host-run.py` — one read-only command on the host over SSH (paramiko,
  password in `SSHPW`).
