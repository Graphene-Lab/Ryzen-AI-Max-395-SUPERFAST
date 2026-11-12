# External projects: what we are pinned to, and what to watch

This is a register, not documentation. Each entry is something the machine is
built on or something we measured and decided against, with the exact version we
were aligned to on 2026-11-12. Check the identifier before trusting anything
here: a branch moves, a model repository gains files, a driver changes the
numbers.

## What the machine runs

| component | pinned to | where it lives | what an update would change |
|---|---|---|---|
| engine source | `pugant/strix-nebulosa`, branch `qwen4exp-conv-ring-slots`, commit **`502e810`** (2026-09-11) | `~/.cache/strix-nebulosa/rocmfpx` on the host | `--reasoning` and `--spec-mtp-strict-qwen` come from patch 0012 and exist nowhere else; a newer branch may fix prefill, and `deploy/build-vulkan-image.sh` re-clones it on every setup run |
| engine image | `localhost/superfast-vk:patch0012`, digest **`be4e0daaa110`** (published as `ghcr.io/graphene-lab/ryzen-ai-max-395-superfast:flash-vk-1`) | podman, local | the published image is pulled first; if it predates patch 0012 the build script falls back to the source |
| upstream llama.cpp | the fork's base includes **PR #25494** (dequant q8_0 KV once in coopmat1), merged 2026-08-19 | — | q8_0 KV prefill on our engine already carries it; a rebase of the fork onto a newer master is what would bring the rest |
| driver and kernel | `mesa-vulkan-drivers 26.1.8-1.fc44`, kernel `7.1.13-200.fc44` | Fedora 44 | a Mesa bump moves every Vulkan number here: re-measure prefill before quoting old ones |
| headless client | Qwen Code **0.23.4** at `/usr/local/bin/qwen` | host; GitHubAssistant drives it | a new release can change the tool-call loop and the prompt handling the assistant depends on |
| dataset | `nuprl/MultiPL-E`, config `humaneval-cs`, 158 rows | rebuilt by `tools/fetch-multipl-e.py` into `benchmarks/multipl-e/multipl_e_cs.jsonl` | a new revision changes the prompts and makes old archives incomparable; the names and order are checked at fetch time |
| PipelineScore CLI | `ps-bench` through `npx`, **version not recorded** | host, on demand | pin it (`npx ps-bench@<version>`) before the next run, otherwise the cards are not comparable |
| model weights | see `deploy/profiles/download-weights.sh` — repository, size and SHA-256 per file | `~/<profile>-models` | that file is the single source of truth; the setup verifies the hash before using a file |

## Evaluated and not used

Each of these was checked on 2026-11-12. They are listed so that a future check
is a comparison and not a new investigation.

| project | what it is | state when checked | why it is not used, and what would change that |
|---|---|---|---|
| [`Nathanw1014/strix-halo-llamacpp`](https://github.com/Nathanw1014/strix-halo-llamacpp) | per-concern Vulkan patches for gfx1151: FA, MoE and delta-net prefill | 225 stars; branches `vulkan-concat-transpose` `1440613`, `vulkan-mmid-scale-epilogue` `5edacdd` (on `ffe5cb4`), `vulkan-fuse-silu-mul` `ed809a4`, `vulkan-fa-f16-kv-contig` `ab5910a`; combined `strix-halo-vulkan` on `Nathanw1014/llama.cpp` | measured gain is 3× on head-dim-128 models and ~+11% at 64k on ours, and the patches extend helpers (`ggml_vk_concat_*`) our older tree lacks. **Would change it:** the delta-net group landing upstream, or a rebase of our fork onto a master that already has them |
| [`lazarevtill/strix-halo-llm`](https://github.com/lazarevtill/strix-halo-llm) | Vulkan tuning notes plus a catalogue of 13 measurement bugs | 3 stars | useful as method, not as an engine. **Would change it:** nothing; it is a reading reference |
| [`julianmb/q38rocm`](https://github.com/julianmb/q38rocm) | NPU-burst → iGPU pipeline for this exact SoC | `v1.7.0`; the burst streams ~24 tokens from a 0.8B model on the NPU, TTFT 1587 → 870 ms | it is a latency/quality trade, not a prefill offload, and the authors say to use the iGPU alone for tool calls and structured output. **Would change it:** a real prefill handoff between the two engines |
| [`ROCm/FastFlowLM`](https://github.com/ROCm/FastFlowLM) | NPU inference runtime (`flm`), the backend behind the burst | supports XDNA2 (Strix, Strix Halo, Kraken, Gorgon) with a curated model list: Qwen, Gemma, Llama, Phi, gpt-oss, DeepSeek | Ornith-1.5 is not in it, so no profile can move. **Would change it:** an Ornith entry, which would make the NPU usable for a small profile |
| [`lemonade-sdk/lemonade`](https://github.com/lemonade-sdk/lemonade) | local LLM server that orchestrates ROCm, Vulkan and NPU | current SDK, with a Strix Halo Docker image | it would replace the units, the gateway and the switch with a server we do not control, to provide backend switching we already have. **Would change it:** a mode that drives our per-profile units instead of its own |
| [`sypherin/strix-halo-setup`](https://github.com/sypherin/strix-halo-setup) | a hands-on setup guide for this chip, NPU section included | NPU section disabled for `amd_iommu=off` | our command line does not use that parameter (the NPU opens fine), so there is nothing to copy. **Would change it:** a step that adds something the docs here lack |
| [`BrandedTamarasu-glitch/OllamaAMDNPU`](https://github.com/BrandedTamarasu-glitch/OllamaAMDNPU) | llama.cpp fork that offloads GEMM to the NPU while prefill stays on Vulkan | proof of concept, 43.7 tok/s on Llama 8B by its own author's account | a PoC on 8B models, not a serving path for a 122B. **Would change it:** the offload landing in a maintained backend |

## How to check

```bash
# the fork's branch and the commit we built from
git -C ~/.cache/strix-nebulosa log -1 --format='%h %ad %s' --date=short
# upstream PRs the fork relies on
gh pr view 25494 --repo ggml-org/llama.cpp --json state,mergedAt
# the tracked projects: anything merged since the dates above
gh release view --repo ROCm/FastFlowLM
gh api repos/lemonade-sdk/lemonade/commits --jq '.[0:3][] | "\(.commit.committer.date) \(.commit.message | split("\n")[0])"'
# the model repositories: new files, new revisions
curl -s "https://huggingface.co/api/models/ornith-ai/Ornith-1.5-122B-GGUF/tree/main" | head -c 400
```

Re-measure only what the update touches, with the method in
[`PREFILL.md`](PREFILL.md), and put the new number beside the old one rather than
replacing it: a driver bump that costs 10% is worth knowing about, and the old
figure is what the published tables were made with.
