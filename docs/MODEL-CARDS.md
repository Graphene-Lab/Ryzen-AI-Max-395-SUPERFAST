# What the model cards say

Notes taken on 2026-10-23 from the Hugging Face cards of the two main profiles, because they name
settings and a known bug that our units do not use yet. Read as documentation of the model, then
checked against our build: two of the flags below do **not** exist in the engine we run today.

## ornith — julianmb/Ornith-1.5-35B-A3B-ROCmFP4-GGUF

The card documents a runtime bug and a way to switch the reasoning off.

**Reasoning.** The chat template honours `enable_thinking` and llama.cpp exposes it as
`--reasoning on|off|auto`. With `--reasoning off` the template emits a pre-closed empty `<think>`
block, so no thinking tokens are generated. The flag is server-side, not per request, and
`enable_thinking` through `--chat-template-kwargs` is deprecated and ignored on current builds.
Our build does not have `--reasoning` at all (`llama-server --help` returns nothing for it), so
today the only lever on a reasoning runaway is the output budget.

**Known bug, quoted.** "Output depends on the previous request… the same prompt can return
different text depending on what ran before it, and can collapse into degenerate repetition." The
named cause is llama.cpp issue #29092, Gated Delta Net recurrent state not cleared between
requests on a reused slot. The card's advice: run with `-np 1` (we do, `--parallel 1`), restart
the server between unrelated sessions, and set `cache_prompt: false` for the requests that matter.

**Recommended server line, quoted.**

```
llama-server -m Ornith-1.5-35B-A3B-ROCmFP4.gguf -mm mmproj-Ornith-1.5-35B-BF16.gguf \
  -ngl 999 -c 131072 -fa on -np 1 \
  --spec-type draft-mtp --spec-mtp-strict-qwen \
  --spec-draft-n-max 2 --spec-draft-p-min 0.6
```

`--spec-mtp-strict-qwen` is not in our build either. `-np 1` and `-c 131072` are one step below
the 262144 we serve.

**KV cache.** `q8_0` is described as the safe step down; `q4_0` and `q4_1` are a known cause of
degraded long-horizon coherence.

**Not usable from Ollama.** Quoted: "This quant will not load in stock ggml-org/llama.cpp, LM
Studio, or Ollama. The `q4_0_rocmfp4` tensor types (ggml ids 100 and 101) do not exist upstream."

## flash — pugant/Qwen3.8-Flash-Next-ROCMFP4_STRIX_LEAN-GGUF

The card documents the root cause of the output-integrity incidents we have been seeing.

**The bug, quoted.** "Earlier agent sessions with this quant showed output-integrity incidents
(reasoning breaking mid-sentence, digit loss inside hex/number runs, malformed tool calls,
premature stops). Root cause: a runtime bug in our fork, not the quant. The qwen4exp conv-history
writer restored the GDN conv state and the PLE history from never-written ring slots after every
speculative rollback." Fixed by patch `0012` (`qwen4exp-conv-ring-slots`); with the fix the draft
acceptance goes from ~0.74 to 0.91-0.95.

That is the same family as our two deaths of 2026-10-22/23 — `Model stream ended after a tool
result without visible progress` — and it points at the engine build, not at the client and not at
the network.

**Recommended production line, quoted.**

```
llama-server -m ...ROCmFP2...-00001-of-00002.gguf -md Qwen3.8-Flash-Next-MTP-Q8_0.gguf \
  --spec-type draft-mtp --spec-draft-ngl all \
  --spec-draft-n-max 6 --spec-draft-p-min 0.75 --spec-draft-p-split 0.10 \
  -ngl 999 -fa on --jinja -c 131072 -b 2048 --ubatch-size 512 -fit off \
  --ple-disk --ple-cache-mib 4096 --no-mmap \
  --cache-type-k q5_1 --cache-type-v q5_1 --threads 16
```

Differences from our unit worth acting on: the card measures with `--cache-type-k/v q5_1` where we
use `q8_0`, adds `--spec-draft-p-split 0.10` and `--spec-draft-ngl all`, and uses `-fit off`.
`n_max 6` matches us; 8 regresses.

**mmap.** For the LEAN base the card says keep mmap on, because `--no-mmap` runs out of memory
through the cgroup with nothing in the log. Our unit runs the ple-disk 64 GB configuration, where
`--no-mmap` is the measured choice, so the two statements are not in conflict — but the base
configuration is not ours.

## What this means for the project

Both cards say the same thing in different words: the engine build matters more than any client
setting. A rebuild to a ROCmFPX that carries patch `0012` and exposes `--reasoning` and
`--spec-mtp-strict-qwen` would give the reasoning switch for ornith and the rollback fix for flash,
which is where our unexplained failures live. Until then the honest statement is that the profiles
run on an older build, and the assbench results of 2026-10-23 were taken on it.
