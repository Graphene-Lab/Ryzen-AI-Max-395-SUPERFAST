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

The Gemma and DeepSeek units need `llama-rocmfpx:7.2.4`, the GGUF runtime built
from [`runtime/`](../runtime/README.md). It is not published on GHCR yet, so
the setup script builds it (that build takes a while and needs about 10 GB of
disk).

Two files in the download table are deliberately absent. The DeepSeek DSpark
drafter is not downloaded: it is built for the Ember runtime and llama.cpp
refuses it (`unknown model architecture: 'deepseek4-dflash-draft'`). The Gemma
MTP head *is* downloaded, but the runtime build rejects the flag it needs, so
it is unused today.
