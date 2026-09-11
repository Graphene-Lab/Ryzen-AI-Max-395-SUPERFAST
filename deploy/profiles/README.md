# deploy/profiles — profile units and the weights downloader

These files are the profiles the model switch can start, and the downloader
that fetches their weights. They are templates: `deploy/setup-fedora.sh`
installs them, replacing the two placeholders

- `__HOME__` — the home directory of the user running the script,
- `__XDG__` — `/run/user/<uid>`, which rootless Podman needs.

| file | what it is |
|---|---|
| `superfast-flash.service` | Qwen3.8-Flash-Next MoE, the fast profile on the engine image |
| `gemma.service` | Gemma-4-26B-A4B ROCmFP4, on the local `llama-rocmfpx` image |
| `deepseek.service` | DeepSeek-V4-Flash ROCmFPX, on the local `llama-rocmfpx` image |
| `orchestrator.service` | the small LFM2.5 router, on port 8732 (runs beside a profile) |
| `superfast-download@.service` | one downloader per profile: `superfast-download@flash`, `@gemma`, `@deepseek`, `@small` |
| `download-weights.sh` | the downloader itself: resume at the exact byte offset, one writer per file, SHA-256 verified before the final rename |

Only one profile serves port 8731 at a time; `superfast-switch use <profile>`
stops the others first. All these units stay disabled until the switch starts
them, except the downloaders, which the setup script enables only for profiles
whose weights are still missing.

The GGUF units are configured for agent use, and the values were measured on
the reference host:

| flag | why |
|---|---|
| `-c 262144` (gemma), `-c 524288` (deepseek) | the largest window that still works well on this machine. Gemma-4 in use: ~23 GB of memory. DeepSeek at 512K: ~102 GB in use, ~21 GB left, and a 1024-token generation completes in 101 s. The model's own maximum is 1M and it does load, but with only ~7 GB left long generations then stall (a 8192-token request stopped after 5668 tokens and burned 14 cores for 25 minutes without producing anything) |
| `--jinja` | tool calling. llama.cpp needs the model's chat template for tools; verified with a tool request on Gemma-4, which answered with a proper `tool_calls` reply |
| *not* `--cache-reuse` | llama.cpp answers "cache_reuse is not supported by this context, it will be disabled" with the unified KV cache these servers use, so the flag would only add a warning |

Multi-turn conversations reuse the KV prefix of the previous turn
automatically; the rest of the context handling is described in the README
under "What each profile ships: context, tokens, tools".

`superfast-flash.service` carries engine settings instead, because that profile
runs the Flash-Next engine and the settings are how several agent
conversations stay resident at once:

| setting | value | why |
|---|---|---|
| `HALOGEN_KV_POOL_POSITIONS` | `1048576` | positions resident across **all** conversations. The image default is 524288 (two full-length conversations); a client that opens subagents needs more, and each request reserves `prompt + max_tokens` of it |
| `HALOGEN_KV_POOL_FIT` | `0` | without it the engine shrinks the pool at startup — a pool requested as 1048576 came up as 524288, so the setting did nothing |
| `HALOGEN_MAX_TOK` | `16384` | the prefill arena (not the answer budget). A 1,048,576-position pool fits only with the arena halved; longer prompts are prefilled in arena-sized pieces |
| `HALOGEN_CACHE_ENTRIES` | `32` | conversations whose resumable state the cache keeps. The image ships 8; 32 leaves headroom for a client that opens subagents. ~111 MiB each |
| `HALOGEN_KV_SLOTS` / `HALOGEN_CTX` | `4` / `262144` | explicit rather than inherited, so what the unit runs with is readable in the unit |
| `HALOGEN_QUEUE_TIMEOUT` | `3600` | seconds a request waits for room in the pool before the engine answers 503. Four concurrent worst-case requests are 2,386 s here, and a 503 throws away the work already queued. The dense unit ships 6000 for the same reason (one slot, four requests, 4,980 s) |
| `HALOGEN_MAX_TOKENS_CAP` | `65536` | largest answer budget a request may ask for. Above it the engine answers 400 rather than truncating; the largest client budget this project documents is 32,768 |

Both are the engine's own names, and both are written explicitly rather than
left to the image: they decide whether a long turn is refused, and a default
that changes under a new image tag is not something to discover in production.
The values, and the client-side ones that pair with them, are derived in the
README under "Timeouts, and why they are what they are".

The two llama.cpp units set `--timeout` for a different reason: it is the
*socket* timeout (600 s by default, `LLAMA_ARG_TIMEOUT`), and the server sends
nothing while it prefills. Gemma ships 1800 s, deepseek 3600 s, because a
507,904-token prompt on deepseek is 3,116 s of silence. See the comments in
those units.

The names are the engine's, and they are `HALOGEN_*`: `SUPERFAST_*` belongs to
this project's own tools and no image contains it, so an engine setting written
that way is read by nobody. The measurements for these values, and how to
put the image defaults back, are in the README under "Many agents at once";
every name is listed in [`docs/FLAGS.md`](../../docs/FLAGS.md).

The Gemma and DeepSeek units need `llama-rocmfpx:7.2.4`, the GGUF runtime built
from [`runtime/`](../../runtime/README.md). It is published by this repository's
workflow as
`ghcr.io/graphene-lab/superfast-runtime:llama-rocmfpx-1`; the setup script
pulls it and tags it, and builds it from `runtime/` if the pull fails (it also
tries an older hand-pushed package name, which may still be private).

Two drafter files cannot be used. Both were re-checked on the reference machine
on 2026-09-11 with `llama-rocmfpx:7.2.4`:

- **The Gemma-4 MTP head** (`mtp-gemma-4-26B-A4B-it-Q8_0.gguf`, which the
  installer does download). The runtime now has the flags for it —
  `--spec-draft-model /models/mtp-….gguf` with `--spec-type draft-mtp`, and
  `--spec-type draft-simple` as well — but loading the head fails in both
  cases with `llama_init_from_model: failed to initialize the context:
  Gemma4Assistant requires ctx_other to be set`, then `failed to create draft
  context`. The build has no flag for that assistant context (only
  `--prefill-assistant` exists, which is a different thing), so the head stays
  unused.
- **The DeepSeek DSpark drafter** (`…DSpark-draft-4.25bpw.gguf`, 10.9 GB). It is
  not in the download table — the file that is in `~/deepseek-models` came from
  a manual fetch — and the current runtime still refuses its architecture:
  `unknown model architecture: 'deepseek4-dflash-draft'`.
