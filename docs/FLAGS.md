# superfast environment flags

Everything is configured by environment variable; there is no config file.
All flags are read **once at startup**.

There are two families of variables, and the prefix decides who reads them:

| prefix | read by | set it |
|---|---|---|
| **`HALOGEN_*`** | the engines, inside the containers — both the dense image and the Flash-Next one | `-e NAME=value` on `podman run`, or `environment:` in `docker-compose.yml` |
| **`SUPERFAST_*`** | this project's own tools: the installer, `superfast-switch`, `superfast-tui`, the API-key gateway, the benchmarks, the client `envKey` | the shell or the client configuration that runs them |

**An engine setting written with the `SUPERFAST_` prefix does nothing.** Neither
image contains that string anywhere — searched, not assumed — so the engine
falls back to its built-in default and says nothing about it. That is what
`docker-compose.yml` did until 2026-09-11: it set `SUPERFAST_BIND`, so the
engine bound `127.0.0.1` inside its own network namespace, where the front-end
container could never reach it.

Everything below is an engine setting unless the section says otherwise.
The engine carries additional kernel-tuning levers that are not listed: they
select internal implementation variants, the shipped defaults are the measured
winners, and changing what is not listed is not supported.

| class | meaning |
|---|---|
| **BITWISE** | output is byte-identical. Safe to change. |
| **NUMERIC** | output *can* change. |

Every flag below is **BITWISE** — they are deployment policy, not arithmetic —
except `HALOGEN_W4A4` and `HALOGEN_W4A4_EXCL`, which are **NUMERIC** and
documented as such. The `images` column says which of the two engine images
honours the name: `dense` is `ghcr.io/peonist-ai/halogen:0.1.3`, `flash` is
`ghcr.io/peonist-ai/halogen-flash-server:0.5.6`.

The engines read these names from their own environment, and the two
entrypoints forward a different subset of them on the command line — the dense
one forwards only the port, bind, checkpoint, tokenizer, cap and timeout; the
Flash-Next one also forwards slots, context, arena and pool. A name the
entrypoint does not forward still works: pass it with `-e` and the engine reads
it itself. That is why the table below is about the *engine* each name belongs
to, not about the entrypoint. The set of names is not guesswork: they are the
`HALOGEN_*` strings the two shipped binaries actually contain, and
`SUPERFAST_*` appears in neither.

## Model and tokenizer

| flag | images | default | meaning |
|---|---|---|---|
| `HALOGEN_CHECKPOINT` | both | `/models/qwen3.8-27b-p1w4d-d2.hgn` (dense), `/models/qwen38-flash-next-w4b.hgn` (flash) | Path to the `.hgn` checkpoint the engine loads. |
| `HALOGEN_TOKENIZER` | both | `/tokenizer` | Flat tokenizer directory. Must contain `tokenizer.json`. HuggingFace cache snapshots are symlinks into a sibling `blobs/` and dangle inside a container, so materialize with `cp -L`. |

## Networking

| flag | images | default | meaning |
|---|---|---|---|
| `HALOGEN_BIND` | both | `127.0.0.1` | Engine bind address. Loopback when engine and front-end share a container; `0.0.0.0` for the two-container topology, where it stays unpublished to the host. |
| `HALOGEN_PORT` | both | `8730` | Engine port. **The engine protocol has no authentication** — keep it unpublished. |
| `HALOGEN_API_PORT` | both | `8731` | Port for the OpenAI-compatible front-end. The only port that should be published. |
| `HALOGEN_ENGINE` | both | `127.0.0.1:$HALOGEN_PORT` | Where the front-end reaches the engine. Compose gives the services separate network namespaces, so it needs `engine:8730` there. |

## Request policy

| flag | images | default | meaning |
|---|---|---|---|
| `HALOGEN_MAX_TOKENS_CAP` | both | `65536` | Largest `max_tokens` a request may ask for. Exceeding it is a **400**, never a silent truncation — a truncated response and a model that stopped on its own both end with `finish_reason: "length"`, so a client cannot tell them apart. **Coupled to `HALOGEN_QUEUE_TIMEOUT`** — see the README. |
| `HALOGEN_QUEUE_TIMEOUT` | both | `7200` (dense), `3600` (flash) | Seconds a queued request waits before `503 engine_busy`. Must exceed the time a full-length request takes, or a long request 503s everyone behind it. |
| `HALOGEN_DRAFTER` | dense | `2` | Default drafter for requests that do not name one: `0` serial, `1` MTP, `2` DFlash2. Output is identical whichever is used; only speed changes. Overridable per request. The Flash-Next engine has no DFlash: its two drafters are `serial` and `mtp`, and `/health` reports which it defaults to. |

## Concurrency and the KV pool

These are the settings that decide whether several conversations — a coding
agent that opens subagents, for example — stay resident or re-prefill their
whole history. `deploy/profiles/superfast-flash.service` ships the values
under "what this project ships" below; the measurements are in the README
under "Many agents at once".

| flag | images | default | what this project ships | meaning |
|---|---|---|---|---|
| `HALOGEN_KV_SLOTS` | both | `4` (flash), `1` (dense) | `4` (flash) | Sequences resident at once. In the **Flash-Next** engine (0.3 and later) the slots share one pool, and a slot costs only its ~115 MiB of O(1) state. In the **dense** engine each slot owns a private KV of `HALOGEN_SLOT_CTX`, which is what the `slots × ctx` table in the README is about — 8 slots at the native context asks for 137 GB and will not fit. |
| `HALOGEN_SLOT_CTX` | dense | `262144` | *(default)* | Context each dense-engine slot holds. The KV costs ~64 KiB per position per slot, so `slots × slot_ctx` is the allocation to keep inside the machine. |
| `HALOGEN_CTX` | flash | `262144` | `262144` | The most context **one request** may use. Past the native 262144 the engine also requires `HALOGEN_ROPE_YARN` (4 for 1M, 2 for 524288), which rescales every position, short prompts included. |
| `HALOGEN_KV_POOL_POSITIONS` | flash | `2 × HALOGEN_CTX` (524288) | `1048576` | Positions resident across **all** conversations. Each request reserves `prompt + max_tokens` of it and **waits** when they do not fit, so this is the number that bounds how many agent sessions can be live at once. The engine refuses a pool smaller than `HALOGEN_CTX`, non-multiples of 256, and anything above 16777216 — an explicit value must be at least `--ctx` (`--kv-pool 16384: at least --ctx 262144, a multiple of 256, at most 16777216`). |
| `HALOGEN_KV_POOL_FIT` | flash | `1` | `0` | `1` lets the engine shrink the pool to what it judges the machine can take **at startup**. It is why a pool requested as `1048576` came up as `524288` and the setting appeared to do nothing. `0` takes the number as given. |
| `HALOGEN_KV_POOL` | flash | `1` | `1` | `1` = one shared pool plus ~115 MiB per slot. `0` is the pre-0.3 form: a private KV per slot, `slots × ctx × ~26 KiB`, which is why 4 × 262144 used to fail to load. |
| `HALOGEN_MAX_TOK` | flash | `32768` | `16384` | The single-call prefill arena, not the answer budget (**that** is `HALOGEN_MAX_TOKENS_CAP`). It is capped at 32768 and must not follow the context: longer prompts are prefilled in arena-sized pieces. A 1,048,576-position pool fits only with the arena at 16384. |

## Prompt cache

A follow-up turn resumes instead of re-prefilling: roughly 20× on
time-to-first-token at 32K, and 145× in the four-agent measurement in the
README. The cache key is **the token prefix itself** — there is no
per-conversation key to send, and `prompt_cache_key` in the OpenAI Responses
shape is accepted and ignored for exactly that reason.

| flag | images | default | what this project ships | meaning |
|---|---|---|---|---|
| `HALOGEN_PROMPT_CACHE` | flash | `2` (baked into the image) | `2` | The snapshot mode. `1` = snapshot on a prefill-chunk boundary, which is what makes a warm answer byte-identical to a cold one; `2` = snapshot at every request end, faster at every prompt length and **not** byte-identical. `0` disables the cache. `/health` reports the mode and whether warm is bitwise-identical as `prompt_cache`. |
| `HALOGEN_CACHE_ENTRIES` | flash | `8` | `32` | How many conversations keep their resumable state. Each entry is ~111 MiB at `HALOGEN_CTX=262144` and holds the O(1) recurrent state; the attention KV itself stays in the pool. The engine prints the armed value at startup (`prompt cache ON, resume-anywhere (8 entries, …)`, and `(32 entries, …)` from this project's unit), and the entrypoint's budget estimate follows it: 8 entries = 0.9 GiB, 32 = 3.6 GiB at the native context. Raise it for a fleet of parallel agents. `/cache`'s `entries` and `cap_bytes` are the snapshots currently stored and their per-entry size, not this allowance. |
| `HALOGEN_CACHE_INPLACE` | flash | `1` | `1` | `1` keeps the KV where it is and stores ~111 MiB per conversation. `0` copies the whole KV per entry (~26 KiB per position) and is only interesting together with `HALOGEN_CACHE_FILE`. |
| `HALOGEN_CACHE_FILE` | flash | *(unset)* | *(unset)* | A file for the snapshot, used with `HALOGEN_CACHE_INPLACE=0`. The entrypoint sets `/var/tmp/halogen-cache.snapshot` by itself when the context is past the native 262144 and in-place is off. On this machine's unified memory the host RAM a disk snapshot would save is the same pool the GPU draws from, so a disk tier buys little and pays NVMe reads; see the README. |
| `HALOGEN_CACHE_ALIGN` | dense | `2048` | `2048` | Snapshot alignment. This value is what makes a warm answer byte-identical to a cold one; any other value is not. Do not change it. |
| `HALOGEN_CACHE_MB` | dense | *(empty = auto)* | *(default)* | Prompt-cache budget in MB. Empty means the engine sizes it from available memory at startup. `0` disables it. A small explicit value yields a cache that reports itself enabled and never hits — one full-context entry is about 18.4 GB at 262K. |
| `HALOGEN_CACHE_RESERVE_MB` | dense | `8192` | *(default)* | Memory left for the system when the cache sizes itself automatically. |

## Precision

| flag | images | default | meaning |
|---|---|---|---|
| `HALOGEN_W4A4` | dense | `64` | Minimum rows for the int4 GEMM path used in prefill. `0` disables it entirely — slower, higher precision. Decode never crosses this threshold, so **decode is unaffected either way**. |
| `HALOGEN_W4A4_EXCL` | dense | `""` | Which weight planes are excluded from the int4 path. The image ships `""` (no exclusions), worth about **+9% prefill** against roughly **-0.45 pt** top-1 aggregate, with decode unharmed. This is the one default whose emitted tokens differ from the engine's built-in default; it does not affect speculation-equals-serial, warm-equals-cold, or batched-equals-solo. See the README to roll it back. |

## Vision (Flash-Next)

The Flash-Next engine can carry a vision tower; it is **off** in the published
image, and `/health` says so.

| flag | images | default | meaning |
|---|---|---|---|
| `HALOGEN_VISION_TOWER` | flash | *(unset)* | Path to the vision tower. Unset = the engine starts without one, and `/health` reports `vision.enabled: false` with the reason. |
| `HALOGEN_VISION_MAX_PIXELS` | flash | `3686400` | Largest accepted image, in pixels. `/health` reports the effective value. |

## Fairness and diagnostics (Flash-Next)

| flag | images | default | meaning |
|---|---|---|---|
| `HALOGEN_ADMIT_CHUNK` | flash | *(engine default)* | A prompt that arrives while other streams are decoding is admitted in pieces of this size, so a long prefill does not freeze them. |
| `HALOGEN_ENGINE_YIELD_MS` | flash | *(engine default)* | How long the engine yields between pieces. |
| `HALOGEN_ENGINE_WATCHDOG_S` | flash | `180` | The container kills the engine if it stops answering for this long. `0` disables the watchdog for diagnosis — documented, and it used to be the flag that killed the server when set to `0`. |
| `HALOGEN_VERBOSE` | flash | `0` | `1` makes the engine narrate how it is armed (kernel arrangements, tuning constants) instead of printing only what it is serving. For troubleshooting. |
| `HALOGEN_CK_OVERLAY` | flash | *(sibling of the checkpoint)* | Path to the quality sidecar `.hgn` overlay. |

## Optional model download

| flag | images | default | meaning |
|---|---|---|---|
| `HALOGEN_DOWNLOAD` | both | *(unset = off)* | HuggingFace repo id to fetch weights from at startup, e.g. `peonist-ai/halogen-qwen3.8-27b`. **Off by default**: with it unset the container makes no outbound connections at all. It fires only when the checkpoint is genuinely missing, so restarts never re-download, and interrupted transfers resume. The models volume must be mounted read-**write** for this, not `:ro`. |

## This project's own variables

`SUPERFAST_*` names are read by our scripts, never by the engines.

| flag | default | meaning |
|---|---|---|
| `SUPERFAST_API` | `http://127.0.0.1:8731` | Endpoint the bundled benchmarks target. |
| `SUPERFAST_API_LOG` | *(unset)* | Path to a teed front-end log, so the serving benchmark can read throughput counters from inside a container. |
| `SUPERFAST_ROOT`, `SUPERFAST_PROMPTS`, `SUPERFAST_API_CTR` | *(derived)* | Benchmark inputs: the image's tool directory, the prompt fixture, the container whose log the counters are read from. |
| `SUPERFAST_PORT`, `SUPERFAST_ORCH_PORT` | `8731`, `8732` | Ports the switch and the TUI probe. |
| `SUPERFAST_FLASH_DIR`, `SUPERFAST_GEMMA_DIR`, `SUPERFAST_DEEPSEEK_DIR`, `SUPERFAST_ORCH_DIR` | `~/superfast-flash`, `~/gemma-models`, `~/deepseek-models`, `~/small-models` | Where each profile's weights live. |
| `SUPERFAST_*_UNIT` | `superfast.service`, `superfast-flash.service`, … | Override the systemd unit a profile maps to. |
| `SUPERFAST_GATEWAY_PORT`, `SUPERFAST_KEY_FILE` | `8741`, `~/.config/superfast/api.key` | The API-key gateway. |
| `SUPERFAST_API_KEY` | *(client side)* | The key the client sends as `Authorization: Bearer …`. `envKey` in the client entry names this variable. |
| `SUPERFAST_NO_KEY` | `0` | `1` makes the installer skip creating an API key. |
| `SUPERFAST_IMAGE`, `SUPERFAST_FLASH_IMAGE`, `SUPERFAST_RUNTIME_IMAGE`, `SUPERFAST_RUNTIME_PUBLISHED`, `SUPERFAST_RUNTIME_PUBLISHED_EXTRA` | the published tags | Installer overrides: which engine and runtime images to pull, and where to look for the runtime before building it from `runtime/`. |
| `PROFILES`, `ONLY`, `MODELS_DIR_*` | `dense` | Installer phase selection and weight locations. |
