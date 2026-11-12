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

## The MTP flags cost more than they return

The 35B carries a speculative-decoding head inside its weights, and the profile
ran with the pair `--spec-type draft-mtp --spec-draft-n-max 2
--spec-draft-p-min 0.6` until 2026-11-12. Measured on one image, one prompt,
cold cache:

| flags | prefill at 9,916 tok | decode |
|---|---|---|
| none | **1,241 tok/s** | 73.2 tok/s |
| `--spec-draft-n-max 2` | 1,036 tok/s | 75.1 tok/s |
| `--spec-draft-n-max 1` | 1,049 tok/s | 77.0 tok/s |

The pair costs **16% of prefill and returns about 3% of decode**, which is noise,
and the draft depth does not change it. The flags are gone from the 35B unit, and
the production measurement follows: **1,245 / 1,026 / 843 tok/s** at 9,916 /
39,617 / 64,016 tokens, against 1,040 / 897 / 726 with them. The 122B keeps the
pair: there the measured decode gain is +25-40% (25.0 against 20.4 tok/s), which
pays for the same prefill cost.

This is also where the "12% gap" went. The production unit was 10-15% slower
than the test container at the same depth, and the cause was the MTP flags, not
the window — the two differ by 16% at 10k, which is the number the window never
showed.

## The upstream Vulkan fixes

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

**Ported, measured, and left opt-in.** On 2026-11-12 the concat transpose
(`1440613`) and the fused silu/mul (`ed809a4`) were adapted by hand to our tree
— the concat dispatch it extends (`ggml_vk_concat_supported`,
`ggml_vk_concat_unit_size`) does not exist here — and built as
`localhost/superfast-vk:prefill`. The change lives in
[`deploy/patches/vulkan-prefill-20261112.patch`](../deploy/patches/vulkan-prefill-20261112.patch),
with the build recipe next to it. The concat path is gated at runtime by
`GGML_VK_CONCAT_TRANSPOSE=1`, so one image gives both arms. Measured on the 35B,
cold cache, same prompt:

| prompt | patch off | patch on | delta |
|---|---|---|---|
| 9,916 tok | 1,199 tok/s | 1,243 tok/s | +3.7% |
| 39,617 tok | 995 tok/s | 1,025 tok/s | +3.0% |
| 64,016 tok | 823 tok/s | 831 tok/s | +1.0% |

Generated text is byte-identical with the flag on and off (375 bytes, same 16
lines at temperature 0), which is the check that matters: the concat feeds the
delta-net state, so a wrong transpose would corrupt the answer rather than slow
it. The baseline arm also reproduces the production number (833 against 831
tok/s at 60k), so the comparison is between two arms of the same engine.

It is **on in the units**: `-e GGML_VK_CONCAT_TRANSPOSE=1` in `ornith.service` and
`ornith122.service` and in their vision drop-ins. The same measurement on the
production configuration — 262K window, MTP, vision, through the gateway — gives
a smaller gain, because the window itself costs more than the patch buys:

| prompt | patch off | patch on | delta |
|---|---|---|---|
| 9,916 tok | 1,016 tok/s | 1,040 tok/s | +2.4% |
| 39,617 tok | 884 tok/s | 897 tok/s | +1.5% |
| 64,016 tok | 728 tok/s | 726 tok/s | 0% |

Those two arms are the same unit restarted, so the only difference is the
variable. **The window is not the lever I first took it for.** Halving it, from
262,144 to 131,072, changes nothing measurable on the same unit with the same
flags: 1,045 / 906 / 745 tok/s at 9,916 / 39,617 / 64,016 tokens against
1,040 / 897 / 726. The 12% gap I had attributed to the window was the difference
between the *test container* (96K, no vision, no MTP, direct port) and the
*production unit* — 831 against 745 tok/s at 60k — and which of the unit's other
flags owns it is not measured yet.

So the window stays at **262,144**, the model's native size. Halving it gave no
speed, and the window is the one thing this machine is used for: an agent that
holds a conversation, the tool definitions and the files it is editing needs the
room, and a smaller window costs more than any prefill percentage buys.

The third fix of the group, `vulkan-mmid-scale-epilogue` (`5edacdd`), is not
ported: it depends on the `vulkan-mmid-rowlists` prepass (`ffe5cb4`) that our
tree does not have, and it is worth +4% at 2048 tokens, which is not a depth this
machine sees. `vulkan-fa-f16-kv-contig` (`ab5910a`) is the one for head-dim 128
models and does not pay here.

One trap when changing a unit's flags: `superfast-switch use <profile>` does
**nothing** when that profile is already loaded — it reports the profile serving
and leaves the old container running. A flag change needs
`systemctl --user restart <unit>`, and the check that it took is
`podman inspect <container> --format '{{.Config.Env}}'`.

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
