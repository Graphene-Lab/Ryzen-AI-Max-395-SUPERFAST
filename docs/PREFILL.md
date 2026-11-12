# Prefill: what it costs, and what we measured

Prefill is the part of a request that reads the prompt. It is the axis that
hurts on this machine, because an agent starts every conversation with a large
prompt: the 122B reads 60,000 tokens in about four minutes. Decode — the part
that writes the answer — is the axis the tables elsewhere in this repository
report.

All the numbers below were measured on the reference machine (Strix Halo,
gfx1151, RADV, engine `localhost/superfast-vk:patch0012`) on 2026-11-12, with a
cold prefix cache and the same prompt text across variants, so the token count
is identical and the rates are comparable.

## The curve, by model and depth

| model | prompt | prefill |
|---|---|---|
| Ornith-1.5-35B-A3B (h16 kv2, hd 256, hybrid) | 12,818 tok | 1,016 tok/s |
| | 60,016 tok | 831 tok/s |
| | 85,016 tok | 614 tok/s |
| Ornith-1.5-122B (hd 256, hybrid) | 60,016 tok | 268 tok/s (f16 KV) |
| | 60,016 tok | 220 tok/s (q8_0 KV) |
| | 78,000 tok | 155-162 tok/s |

The 35B rate falls by a third between 13k and 85k; the 122B's falls faster
because it is three and a half times the model. Neither collapse is a defect:
it is what a hybrid attention stack costs as depth grows.

## The flags

Sweep at 60,016 tokens on the 35B, one change per run: shipped flags 831 t/s,
`--flash-attn on` 820 (noise — `auto` already resolves to on), `-ub 1024` 785,
`-ub 256` 728, `-ctk/-ctv q8_0` with Flash Attention 619. The table and the
reading live in [`FLAGS.md`](FLAGS.md); the only line that changed a decision is
the KV one.

**The quantized cache costs prefill.** On the 122B the same prompt takes 272.6 s
with q8_0 and 224.1 s with f16 — 220 against 268 tok/s, +22% for f16 — and on
the 35B the gap is 25%. Re-measured in production on the same day, switching the
real profile: **233.3 s and 257 tok/s** at 60,016 tokens with the f16 cache the
unit now ships. That is why `ornith122` moved to f16 despite the vendor's q8_0
recommendation: it pays about 3 GiB of the 45 GiB the profile leaves free, and
about 5% of decode (23.5 against 22.2 t/s), and gains prefill and two quality
points (84.0 against 81.9 on PipelineScore).

## The one lever we did not pull

The upstream Vulkan fixes for this chip are real and they are documented with
numbers: [`Nathanw1014/strix-halo-llamacpp`](https://github.com/Nathanw1014/strix-halo-llamacpp)
keeps them as **one branch per fix** on its `llama.cpp` fork, not as a patched
dump. The gain depends on the model's attention head width:

| model family | gain at 64k | why |
|---|---|---|
| head-dim **128** (Qwen3-Coder-30B-A3B) | **2.63-3.26×** | the strided KV read collapses the cache; the fix contiguizes it |
| head-dim **256**, delta-net MoE (Qwen3.6-35B-A3B) | **+10.7%** at 64k, +30.8% at 2048 | the conv-state concat and the MoE epilogue |

Both of our models are head-dim **256** (`qwen35moe.attention.key_length = 256`)
and hybrid, so we sit in the second row: the 3× is not available to us, and the
35B already prefill at the level of their patched arm at depth (614 against
618 tok/s at 64k). A control run made the same day with a head-dim 128 model on
our engine — Qwen3-VL-8B, dense, 36 layers — gave 355 tok/s at 25k, which is
their *stock* value (358 at 32k), so the collapse is real and our engine has not
got the contiguity fix.

Not ported, for three reasons, all of them measured:

1. the expected gain at our depths is about +10% on the 122B (268 → ~295 tok/s);
2. the patches are written against a newer llama.cpp: the concat dispatch they
   extend (`ggml_vk_concat_supported`, `ggml_vk_concat_unit_size`) does not exist
   in our tree, so each of the three needs manual adaptation, a rebuild and a
   full re-measurement of the published numbers;
3. one of the four (`vulkan-fuse-silu-mul`) applies cleanly and is worth +0.76%,
   which does not justify an image on its own.

The recipe, if it ever is worth it: branch `vulkan-concat-transpose` (`1440613`,
82 lines), `vulkan-mmid-scale-epilogue` (`5edacdd`, 69 lines, stacked on
`vulkan-mmid-rowlists` `ffe5cb4`) and `vulkan-fuse-silu-mul` (`ed809a4`,
50 lines) on `Nathanw1014/llama.cpp`; port them into `pugant/strix-nebulosa`
under `rocmfpx/`, build a separate image tag, and measure with the prompt above
before touching a unit. `vulkan-fa-f16-kv-contig` (`ab5910a`) is the one for
head-dim 128 models and does not pay here.

## Why not the NPU

The machine has one — XDNA 2 at PCI `1022:17f0`, the `amdxdna` module loaded,
`/dev/accel0` present and openable from user space, and no `amd_iommu=off` in
the kernel command line (the parameter that disables the NPU section in other
Strix Halo setups). So the hardware is not the obstacle; the shape of the
workload is.

The reference hybrid pipeline for this exact SoC
([`julianmb/q38rocm`](https://github.com/julianmb/q38rocm), same processor and
iGPU) does not offload prefill. It **streams the first ~24 tokens from a 0.8B
model on the NPU and then asks the 27B on the iGPU to continue that prefix**,
which takes first-token latency from ~1587 ms to ~870 ms. The authors call it a
latency/quality trade and not speculative decoding, because the tokens already
sent to the client cannot be corrected, and they recommend the iGPU-only
endpoint for structured output, tool calls and anything correctness-sensitive.
Sustained decode does not improve, and the NPU under contention with the iGPU
falls from 42.9 to ~14 tok/s because the DRAM bus is shared.

That is the opposite of what this machine is used for: an agent that edits code
and calls tools cannot accept the first 24 tokens from a 0.8B model. And the
NPU runtimes serve a curated list of models with hand-tuned kernels — FastFlowLM
ships Qwen, Gemma, Llama, Phi, gpt-oss and DeepSeek families — so Ornith-1.5 is
not servable there at all, whatever its size. The only model here that could
move is the orchestrator, and that would mean building XRT from source and
re-plumbing its unit and the gateway for about a gigabyte of memory and no
measurable latency gain.

## How to measure it without fooling yourself

The engine caches the prompt prefix in RAM (`prompt cache RAM enabled`), so a
second request with the same text is answered from the cache and looks
instantaneous. Every variant needs a different filler sentence, and the token
counts have to be compared rather than assumed: a filler of different length
gives a different depth, and the rate depends on depth. The two rates worth
quoting are the total wall time and `prompt_tokens / wall`, both of which the
scripts print.
