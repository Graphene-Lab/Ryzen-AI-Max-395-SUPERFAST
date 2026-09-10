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
| `-c 262144` (gemma), `-c 1048576` (deepseek) | the largest window each model supports. Gemma-4 in use: ~23 GB of memory. DeepSeek at 1M: ~116 GB, about 8 GB left — use `-c 524288` if the machine also runs a desktop and other services |
| `--jinja` | tool calling. llama.cpp needs the model's chat template for tools; verified with a tool request on Gemma-4, which answered with a proper `tool_calls` reply |
| *not* `--cache-reuse` | llama.cpp answers "cache_reuse is not supported by this context, it will be disabled" with the unified KV cache these servers use, so the flag would only add a warning |

Multi-turn conversations reuse the KV prefix of the previous turn
automatically; the rest of the context handling is described in the README
under "What each profile ships: context, tokens, tools".

The Gemma and DeepSeek units need `llama-rocmfpx:7.2.4`, the GGUF runtime built
from [`runtime/`](../runtime/README.md). It is published by this repository's
workflow as
`ghcr.io/graphene-lab/superfast-runtime:llama-rocmfpx-1`; the setup script
pulls it and tags it, and builds it from `runtime/` if the pull fails (it also
tries an older hand-pushed package name, which may still be private).

Two files in the download table are deliberately absent. The DeepSeek DSpark
drafter is not downloaded: it is built for the Ember runtime and llama.cpp
refuses it (`unknown model architecture: 'deepseek4-dflash-draft'`). The Gemma
MTP head *is* downloaded, but the runtime build rejects the flag it needs, so
it is unused today.
