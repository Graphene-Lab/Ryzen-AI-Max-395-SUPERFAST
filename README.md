# SUPERFAST

**The fastest way to run Qwen3.8-27B on AMD Strix Halo — at higher precision
than any engine that gets close.**

SUPERFAST is built for one GPU: AMD Strix Halo (gfx1151). Every kernel is
written for this GPU and for this model family. There is no general-purpose
runtime, no portability layer, and no fallback path. That is why it can be
faster than a general engine — and why it runs on exactly one piece of
silicon.

Measured on a 32K prompt with a 256-token answer, against the fastest
published numbers for this model on this hardware:

| | prefill | decode | **total** |
|---|---|---|---|
| **SUPERFAST** (6.32 bpw) | **57.9 s** | 8.1 s | **66.0 s** |
| [KyaniteLabs](https://github.com/KyaniteLabs/qwen38-27b-strix-halo) (Q4_K_XL) | 84.0 s | 8.5 s | 92.5 s |
| [q38rocm](https://github.com/julianmb/q38rocm) (4.26 bpw) | 133.7 s | 7.8 s | 141.5 s |

SUPERFAST is **2.1× faster than q38rocm and 1.4× faster than KyaniteLabs**
end to end, while carrying about 1.5× their weight precision. Most of the
difference is in prefill, and prefill is most of the wall-clock time on any
prompt with real context.

Output is **byte-identical to serial greedy decode**. Speculation here is a
pure speed optimization, not a quality trade. This is verified on every
release.

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --security-opt seccomp=unconfined --ipc=host \
  -v /path/to/models:/models:ro -v /path/to/tokenizer:/tokenizer:ro \
  ghcr.io/peonist-ai/superfast:0.1.3
```

An OpenAI-compatible endpoint comes up on `:8731`.

On Docker instead of Podman, replace `--group-add keep-groups` with
`--group-add video --group-add render`. `keep-groups` is a Podman keyword that
Docker does not understand: Docker resolves `--group-add` names against the
container's `/etc/group` and fails with `unable to find group keep-groups`.

---

## Set up a new machine

New to SUPERFAST and no Linux machine yet? Do these steps in order. This is
the path we follow on a Ryzen AI Max+ 395.

**The whole journey, in order** — each step links to its section:

1. Install Fedora Workstation 44 and enable SSH — [step 1](#1-install-fedora-workstation-44-recommended) below.
2. Connect to the machine over SSH — [step 2](#2-connect-to-the-machine-over-ssh-optional-but-recommended).
3. Run the setup script, which downloads the model and starts the engine — [step 3](#3-configure-the-machine-for-superfast).
4. Download the weights and learn the API — [Get the weights](#get-the-weights).
5. Measure and compare the speed — [Performance](#performance).
6. Turn the machine into your personal assistant — [AgentBridge](#make-it-your-personal-assistant-with-agentbridge).

### 1. Install Fedora Workstation 44 (recommended)

This is the distribution we recommend. Why:

- **It is the current Fedora.** Fedora 44 is the latest stable release
  (April 2026) and receives updates into 2027. It ships the newest stable
  kernel and Mesa, and that matters here: support for a brand-new AMD APU
  like Strix Halo (gfx1151) lives in the upstream kernel and Mesa, not in
  distro-specific patches.
- **ROCm comes from Fedora itself.** AMD's own ROCm installer
  (`amdgpu-install`) targets Ubuntu and Red Hat families, not Fedora.
  Fedora instead packages the open ROCm stack in its official repositories:
  you install it with `dnf`, and updates follow the release. No third-party
  repositories or PPAs.
- **A normal, well-known desktop system.** Fedora Workstation is the same
  GNOME desktop used by millions of machines, with a straightforward
  installer (Anaconda) that offers disk encryption and automatic
  partitioning out of the box.

Steps:

1. Download the **Fedora Workstation 44** ISO (x86_64) from
   [getfedora.org](https://getfedora.org).
2. Write it to a USB stick with [Fedora Media Writer](https://fedoraproject.org/workstation/download)
   (or any USB writer you trust).
3. Boot the machine from the USB. In the installer, choose your disk, turn
   on disk encryption, create your user account, and pick a hostname.
4. Reboot into the installed system, open a terminal, and enable SSH so the
   rest of the setup can run from your PC:

   ```bash
   sudo dnf install -y openssh-server
   sudo systemctl enable --now sshd
   ```

Remember the user name you created — you need it in step 2.

### 2. Connect to the machine over SSH (optional, but recommended)

If the machine has no keyboard or monitor attached, do every configuration
step from your PC over SSH.

**Option A — with Pi Easy Connect (an Ethernet cable is all you need).**
[Pi Easy Connect](https://github.com/Graphene-Lab/pi-easy-connect) shares the
Windows PC's internet with the machine over a direct Ethernet cable (Windows
ICS) and opens SSH for you. It works with any Linux machine that has a
network port.

1. Connect an Ethernet cable between the PC and the machine.
2. Run `.\pi-easy-connect.ps1 -SshUser <your-fedora-username>`.
3. You land in the machine's shell, with internet on the `192.168.137.x`
   subnet.

The ICS lease can change between reboots. To make the address fixed, set it
once on the machine (subnet of the direct cable):

```bash
nmcli con mod "Wired connection 1" ipv4.method manual \
  ipv4.addresses 192.168.137.100/24 \
  ipv4.gateway 192.168.137.1 \
  ipv4.dns "192.168.137.1 1.1.1.1"
nmcli con up "Wired connection 1"
```

Then connect instantly with `.\pi-easy-connect.ps1 -StaticIp 192.168.137.100
-SshUser <your-fedora-username>`.

**Option B — plain SSH over a normal network.** Put the machine on your LAN
(DHCP is fine to start) and run `ssh <your-fedora-username>@<machine-ip>`
from any computer on the same network. If SSH times out, open the port on the
machine:

```bash
sudo firewall-cmd --add-service=ssh --permanent
sudo firewall-cmd --reload
```

### 3. Configure the machine for SUPERFAST

A fresh Fedora install is not enough — but less than you might expect, because
the SUPERFAST image carries its own ROCm user-space. The machine needs, at
minimum:

- a kernel whose amdgpu driver exposes `/dev/kfd` and `/dev/dri` for gfx1151 —
  a stock Fedora 44 already does,
- a container runtime (Podman or Docker) to run the image,
- your user in the `video` and `render` groups,
- disk space for the ~36 GB checkpoint — see [Get the weights](#get-the-weights).

All of the above is validated on a Ryzen AI Max+ 395 running Fedora
Workstation 44. Two ways to get there:

- **Automated:** `bash deploy/setup-fedora.sh` brings a fresh machine to a
  running SUPERFAST service in one run — system update, SSH, GPU groups,
  auto-suspend off, checkpoint download with exact-offset resume, and the
  engine installed as `superfast.service`, waiting for `/health`.
- **Step by step:** follow the chronological log in
  [`docs/fedora-44-setup.md`](docs/fedora-44-setup.md). Every command there
  was executed and verified on the reference machine, in order.

Things we learned on the reference machine:

- **No host ROCm.** AMD's `amdgpu-install` does not target Fedora, and it is
  not needed anyway: the image bundles ROCm (see `THIRD-PARTY-NOTICES`).
- **Slow or unreliable link?** Do not use `hf download` for the 36 GB file:
  its transport can stall, and its resume silently restarts because the
  server rotates etags between runs. Use the curl `-C -` loop inside
  `deploy/setup-fedora.sh`, which resumes at the exact byte offset and loses
  nothing. On a fast link, `hf download` (under
  [Get the weights](#get-the-weights)) is fine.
- **BIOS memory split.** Set the UMA frame buffer to its minimum in the
  firmware, so the whole unified memory is a single pool. Large checkpoints
  such as the Flash-Next MoE need it; the setup script also raises the
  TTM/GTT shared-memory limit to ~120 GiB.
- **LUKS disk encryption:** every reboot stops at the passphrase prompt on
  the console, so a headless reboot needs someone at the keyboard (TPM2
  auto-unlock is a possible future option).
- **SELinux stays Enforcing** — passing `/dev/kfd` and `/dev/dri` into
  rootless Podman works out of the box.
- **The engine runs as a systemd user service** (`superfast.service`):
  starts at boot, restarts on failure, serves the OpenAI-compatible API on
  port 8731.

---

## Get the weights

The image has **no model weights**. It is 3.5 GB of engine, and the
checkpoint is 35.9 GB. Download it once and mount it:

```bash
pip install -U "huggingface_hub[cli]"
hf download peonist-ai/superfast-qwen3.8-27b \
  --local-dir ~/superfast-models
```

That repository carries both the `.hgn` checkpoint **and a flat tokenizer
directory**, so there is nothing to assemble by hand:

```
~/superfast-models/
  qwen3.8-27b-p1w4d-d2.hgn      35.9 GB   the checkpoint
  tokenizer/                              tokenizer.json, chat template, ...
```

Then point the container at both:

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --security-opt seccomp=unconfined --ipc=host \
  -v ~/superfast-models:/models:ro \
  -v ~/superfast-models/tokenizer:/tokenizer:ro \
  ghcr.io/peonist-ai/superfast:0.1.3
```

### Or let SUPERFAST fetch the weights for you

If you do not want to download separately, set `SUPERFAST_DOWNLOAD` and the
container fetches the weights on first start:

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --security-opt seccomp=unconfined --ipc=host \
  -e SUPERFAST_DOWNLOAD=peonist-ai/superfast-qwen3.8-27b \
  -e SUPERFAST_TOKENIZER=/models/tokenizer \
  -v ~/superfast-models:/models \
  ghcr.io/peonist-ai/superfast:0.1.3
```

Two differences from the manual route. The models volume is mounted
**read-write** — it has to be, because the download writes into it. And there
is only *one* mount: the download brings the tokenizer with it, so
`SUPERFAST_TOKENIZER` points inside `/models` rather than at a second volume.
Mounting `~/superfast-models/tokenizer` here would fail on a first run,
because the container runtime would create it as an empty directory before
the download could fill it.

The download only fires when the checkpoint is actually missing, so restarts
do not re-download, and an interrupted transfer resumes instead of starting
over.

**With `SUPERFAST_DOWNLOAD` unset, the container opens no outbound network
connections at all** — no telemetry, no license check, no model fetch. If the
checkpoint is not on disk where `SUPERFAST_CHECKPOINT` points, the container
says so and exits instead of reaching for the network. That default is
deliberate: a 35.9 GB transfer should not begin because someone ran
`podman run` to see what would happen.

Model weights are licensed separately from the engine by their original
authors; see the model repository for those terms.

---

## Performance

Measured on a Ryzen AI Max+ 395 (Radeon 8060S, 128 GB LPDDR5X), ROCm 7.14.0,
checkpoint `p1w4d-d2` (~6.3 bits/weight effective at decode), 262,144 context.

### Prefill

All three values were measured over the HTTP endpoint with the bundled
`sweep`, so one instrument produced them all.

| test | t/s |
|---|---|
| pp512 | 620 |
| pp2048 | 710 |
| pp32768 | **566** |

### Decode

Over the HTTP endpoint, ten prompt shapes, greedy, DFlash2 drafter:

| | mean t/s | range |
|---|---|---|
| **DFlash2** (default) | **31.71** | 20.8 – 44.2 |
| MTP | 26.88 | 19.8 – 34.2 |
| serial (no speculation) | 10.58 | — |

Aggregate throughput at 8 concurrent requests: **48.6 t/s** (4.87×).

### Read the range, not just the mean

**SUPERFAST's decode rate is a distribution, not a single number.**
Speculative decoding accepts more drafted tokens when the text is
predictable, so the same build on the same hardware does:

- **prose / chat: 20.8 – 23.5 t/s**
- **procedures: 25.6 – 38.7 t/s**
- **code / proofs: 32.7 – 44.2 t/s**

A single headline figure hides a 2× spread. Any decode number quoted from
this project — by us or anyone else — should name the prompt set that
produced it, or it is not reproducible. `bench` prints the mean; `sweep`
prints mean, standard deviation, and min–max, on purpose.

An engine without speculative decoding has a content-independent decode rate,
so it can honestly quote one number. SUPERFAST cannot.

### Performance tuning on Fedora 44 — what we tested

End-to-end numbers on the reference host (Fedora Workstation 44, engine
served by `superfast.service`, measured with
[`tools/quick-bench.py`](tools/quick-bench.py): greedy, `reasoning_effort:
low`, `max_tokens: 192`, 3 reps, stable within ±0.1%):

| test | result |
|---|---|
| prose | **23.9 t/s** |
| code | **29.5 t/s** |
| context probe (~2.2K prompt) | ~585 t/s end-to-end (prefill-dominated) |

We validated three well-known tuning levers against that baseline and then
rolled them back, because none produced a real change:

| setting tried | effect | outcome |
|---|---|---|
| `tuned-adm profile accelerator-performance` (CPU performance governor + EPP) | prose 23.90, code 29.47 | **no change** — reverted to `balanced` |
| GPU performance level `high` (force max clocks) | prose 23.90, code 29.49 | **no change** — reverted to `auto` |
| `transparent_hugepage=always` | prose 23.89, code 29.49 | **no change** — reverted to `madvise` |

Why nothing moves: batch-1 decode runs at the memory-bandwidth wall
(249 GB/s against a ~240 GB/s ceiling), and these levers change clocks or
page granularity, not bandwidth. Prefill was unchanged as well.

AMD guidance agrees with the hardware as shipped: AMD's own hands-on LLM
guide for this APU uses a **64 GB GPU-accessible allocation on a 128 GB
machine** — exactly the BIOS configuration this host already has. (AMD's
ROCm *system optimization* doc suggests a small VRAM reservation with a large
TTM/GTT limit for other workflows; switching to it would need a BIOS+reboot
change and we found no workload-based reason to try it here.) Overclocking
advice from specialists (`ppfeaturemask`/`pp_od_clk_voltage`, or UXTU on
Windows) targets clock-limited paths — it does not apply to a
bandwidth-bound decode workload and would require a kernel parameter +
reboot.

**Conclusion:** the stock Fedora 44 configuration already performs at the
practical ceiling for this engine. Re-measure any time with:

```bash
python3 tools/quick-bench.py --api http://<host>:8731
```

### A faster family of this model: Qwen3.8-Flash-Next (MoE)

The default checkpoint, Qwen3.8-27B, is a dense model. A dense model reads
every one of its parameters from memory for every token it generates, and on
this machine memory bandwidth is the hard limit: that is why generation
lands at about 24 tokens per second on prose and 29 on code, end to end.

Qwen3.8-Flash-Next belongs to the same Qwen3.8 family but uses a
mixture-of-experts design. It keeps far more parameters in total, yet for any
single token only a small subset of its experts is active. Reading fewer
weights per token means more tokens per second on the same memory bandwidth,
which is why a larger model can still be the faster model on this kind of
hardware.

The published checkpoints for the engine support this choice with three
files. The main one is the 4-bit MoE checkpoint itself. Beside it sits a
quality overlay that re-quantizes the most sensitive tensors with extra care
and measures on par with full precision for those rows; removing it costs
several percent on perplexity. The optional speed overlay adds the
speculative-decoding head, which keeps the output byte-identical and only
changes the speed.

Running Flash-Next requires the full 124 GB of unified memory as one pool,
because the checkpoint alone is about 115 GB. On this reference host that
meant setting the BIOS UMA frame buffer to its minimum so the firmware stops
reserving a fixed slice of memory for the GPU; the engine then draws what it
needs from the shared pool. This is the configuration AMD describes for
running large models on these APUs.

The measured comparison between the dense checkpoint and Flash-Next on this
exact machine will be added to this section as soon as the validation run
finishes. The dense reference figures are the ones above: 23.9 tokens per
second on prose and 29.5 on code, measured end to end on the serving
endpoint.

---

## How it compares

Published numbers from other projects running **the same model on the same
silicon**. These are *their* figures on *their* configurations, not a
head-to-head we ran. Quantization, KV-cache settings and context differ, so
read this as orientation, not as a controlled benchmark.

| | SUPERFAST | [q38rocm](https://github.com/julianmb/q38rocm) | [KyaniteLabs](https://github.com/KyaniteLabs/qwen38-27b-strix-halo) |
|---|---|---|---|
| backend | custom HIP | ROCm/RADV | llama.cpp |
| weights | ~6.3 bpw | 4.26 bpw | UD-Q4_K_XL |
| **prefill @32K** | **566 t/s** | 245 t/s | ~390 t/s |
| decode, speculated | 30.98 mean (20.8–44.2) | 30.56 – 36.04 | prose 11–24, code 29–40 |
| decode, unassisted *(diagnostic)* | 10.58 t/s | **14.02 t/s** | — |

**Where SUPERFAST wins:** prefill, by 1.4–2.3×, and end-to-end on any prompt
with real context. That is what the engine was built for.

**Where SUPERFAST loses:** unassisted decode — and that row is a diagnostic,
not a product configuration. Nobody ships serial decode; every project in
this table runs speculation by default. The gap is also not a kernel-quality
issue: decode is bandwidth-bound. q38rocm streams ~17 GB/token against our
23.5, and fewer bits is simply faster. SUPERFAST spends those bits
deliberately (see `docs/QUANT.md`): the only 4-bit tensors in our trunk are
ones somebody else calibrated, and the aggressive technique is fenced to
prefill, where it never touches token generation.

**Batch-1 decode is at the hardware wall.** 10.58 t/s × 23.51 GB/token =
249 GB/s against a measured ceiling of 240 GB/s. No kernel win is left there
for anyone; the levers left are fewer bits, better draft acceptance, and
batching.

**On the 148–163 t/s figure** circulating for llama.cpp on this hardware:
that is an ngram-repetition artifact on back-to-back identical runs, and
KyaniteLabs — whose benchmark it is — says so plainly and warns against
quoting it for chat. Their honest conversational numbers are in the table. We
think that is the right way to publish, and we have tried to match it.

---

## Benchmark it yourself

The image ships both benchmarks. No fixtures, no extra downloads, no
cooperation from us required.

```bash
# ten real prompt shapes over the HTTP endpoint — the number of record
podman run --rm --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --security-opt seccomp=unconfined --ipc=host \
  -v /path/to/models:/models:ro -v /path/to/tokenizer:/tokenizer:ro \
  ghcr.io/peonist-ai/superfast:0.1.3 bench dflash2 256 low 3

# llama-bench-shaped pp/tg sweep, to put a number next to another engine
podman run --rm ... ghcr.io/peonist-ai/superfast:0.1.3 \
  sweep -p 512,2048,8192 -n 128,256 -d dflash2,mtp -r 3
```

`sweep --json` emits machine-readable output.

**Publishing the results is expressly permitted** — no approval, no notice,
no prior review. We only ask that figures name the version and the prompt
set, for the reason above. That request is not a licensing condition.

---

## What it does

**Byte-identical speculative decoding.** Draft-then-verify only commits
tokens the full model would have produced, so output is bit-for-bit identical
to serial greedy decode. This is gated on every release across all three
drafters — measured, not asserted. Speculation here is a pure speed
optimization with no quality cost, and you can turn it off per request to
check.

**Native 262,144-token context**, with decode that barely degrades at depth.
Gated DeltaNet carries O(1) state, so 48 of 64 layers have no KV cache at
all.

**Prompt cache** — a follow-up turn on a long conversation resumes instead of
re-prefilling, worth roughly 20× on time-to-first-token at 32K. Warm answers
are byte-identical to cold ones by construction.

**Batched decode** — 8 concurrent sequences, 4.87× aggregate, each
byte-identical to running alone. **Off by default**, and it trades away
speculation when enabled; see [Configuration](#concurrency-and-the-one-trap)
before turning it on.

**OpenAI-compatible API** — `/v1/chat/completions`, `/v1/completions`,
streaming, tool calling, sampling with seeds, reasoning-effort control.

**Three selectable drafters** — `dflash2` (default), `mtp`, `serial`. Choose
per request; output is identical, only speed changes.

---

## Configuration

Everything is set by environment variable — there is no config file. The
complete list of levers, with defaults and whether each one can change
output, is in [`docs/FLAGS.md`](docs/FLAGS.md). These are the ones most
people touch:

| variable | default | what it does |
|---|---|---|
| `SUPERFAST_CHECKPOINT` | `/models/qwen3.8-27b-p1w4d-d2.hgn` | which checkpoint to load |
| `SUPERFAST_TOKENIZER` | `/tokenizer` | flat tokenizer directory |
| `SUPERFAST_API_PORT` | `8731` | the published port |
| `SUPERFAST_DRAFTER` | `2` (DFlash2) | default drafter: `0` serial, `1` MTP, `2` DFlash2 |
| `SUPERFAST_CACHE_MB` | *auto* | prompt cache budget; `0` disables |
| `SUPERFAST_MAX_TOKENS_CAP` | `65536` | largest `max_tokens` a request may ask for — over it is a **400**, never a silent truncation |
| `SUPERFAST_QUEUE_TIMEOUT` | `7200` | seconds a queued request will wait — **coupled to the cap**, see below |
| `SUPERFAST_KV_SLOTS` | `1` | concurrent resident sequences — see below |
| `SUPERFAST_SLOT_CTX` | `262144` | context each slot holds — see below |

Per-request settings — drafter, temperature, top_p, seed, reasoning effort,
tools — go in the JSON body and override the server defaults.

### The token budget covers thinking, not just the answer

This model reasons before it replies, and those tokens count against the
budget. If a budget runs out mid-thought, it does not shorten the answer — it
removes it: the reply comes back with `finish_reason: "length"`, an empty
`content`, and the partial reasoning in `reasoning_content`, which most
OpenAI clients do not display. The per-request default is **8192**, which
finished every ordinary prompt we measured with room to spare. The ceiling is
`SUPERFAST_MAX_TOKENS_CAP`.

Any of three field names works, and they mean the same thing here:
`max_completion_tokens` (current OpenAI Chat Completions),
`max_output_tokens` (OpenAI Responses), or `max_tokens` (deprecated upstream,
still widely sent). Send one, or send several as long as they agree; two
different values is a 400 rather than a guess about which you meant. `/health`
lists all three under `token_budget_aliases` and reports the default as
`max_tokens_default`.

If a reply looks empty or cut off, read `finish_reason` first: `"stop"` means
you have the whole answer, `"length"` means you ran out of budget. Pass a
larger budget, or use `"reasoning_effort": "low"` to make the model think
less.

### Concurrency, and the one trap

**By default SUPERFAST serves one request at a time with speculative decoding
on.** That is the right setting for a single user: you get about 31 t/s.

Raising `SUPERFAST_KV_SLOTS` lets several sequences stay resident at once and
raises *aggregate* throughput to about 49 t/s at 8 concurrent requests. But
**speculation and batching are currently mutually exclusive.** With more than
one slot the drafter is off, so each individual stream runs at serial speed
(~6 t/s at 8 slots). One user is much better off with the default; a shared
server with steady concurrent load is better off with slots.

**The trap:** the KV pool costs `slots × slot_ctx × 64 KiB`, so raising slots
without lowering the per-slot context multiplies the allocation. Eight slots
at the native 262,144 context asks for **137 GB** and will not fit. Keep the
product at or below the native context:

| `KV_SLOTS` | `SLOT_CTX` | pool |
|---|---|---|
| 1 | 262144 | 17.2 GB *(default)* |
| 2 | 131072 | 17.2 GB |
| 4 | 65536 | 17.2 GB |
| 8 | 32768 | 17.2 GB |
| 8 | 262144 | 137 GB — **will not fit** |

A prompt longer than `SLOT_CTX` is a hard error naming the limit. It is never
silently truncated.

### Raising the output cap

`SUPERFAST_MAX_TOKENS_CAP` and `SUPERFAST_QUEUE_TIMEOUT` are coupled and
should not be moved independently. The cap bounds how long one request can
hold the GPU; the timeout bounds how long the next client waits for it. **If
a full-length request can outlast the timeout, everyone queued behind it gets
a 503.**

At high reasoning effort decode runs around 10 t/s, so:

| cap | worst-case request | needs a timeout above |
|---|---|---|
| 4,096 | 6.8 min | 410 s |
| 16,384 | 27.3 min | 1,640 s |
| 32,768 | 54.6 min | 3,280 s |
| **65,536** *(default)* | **109.2 min** | **6,550 s**, and the default timeout is 7,200 s |

The cap is a ceiling on what a client may ask for, not a promise about
throughput. Almost nothing reaches it: the model stops on its own when the
answer is done. It is set high so that a long reasoning problem is not cut
off by server policy, and the timeout is set above it so that a client who
does ask for a full-length reply does not 503 the next one in the queue.
Lower both together if you would rather bound how long one request can hold
the GPU.

Asking for more than the cap returns a **400** naming the limit. It is never
silently truncated — but note that a truncated response and a model that
stopped on its own both end with `finish_reason: "length"`, so a client
cannot tell them apart.

### Prompt cache

`SUPERFAST_CACHE_MB` is empty by default, meaning **auto**: the engine sizes
the cache from available memory at startup. That suits a machine dedicated to
serving. Set an explicit value in MB to pin it, or `0` to disable.

One caveat if you pin it: a single full-context entry is about 18.4 GB at
262K, so a small explicit budget produces a cache that reports itself enabled
and never actually hits. The engine warns at startup when this happens.

Warm answers are byte-identical to cold ones by construction.

## Requirements

- **AMD Strix Halo (gfx1151)** — Ryzen AI Max+ 395 or equivalent. The build
  hard-rejects every other architecture; this will not run on your discrete
  GPU, and that is deliberate.
- **128 GB unified memory** recommended. The checkpoint is 35.9 GB and is
  mapped, not copied.
- **ROCm-capable kernel** with `/dev/kfd` and `/dev/dri` accessible.
- **A checkpoint and a tokenizer**, mounted at `/models` and `/tokenizer` —
  see [Get the weights](#get-the-weights). The tokenizer directory must be
  flat. The published model repository is already flat, so this only bites if
  you point at a HuggingFace *cache* snapshot, whose entries are symlinks into
  a sibling `blobs/` and dangle inside a container.

### Modes

| command | what it does |
|---|---|
| *(default)* | engine + API in one container, one published port |
| `engine` / `api` | split roles for a two-container deployment |
| `bench` | ten real prompt shapes over HTTP |
| `sweep` | pp/tg size sweep |

**The engine's token protocol has no authentication.** In the default mode it
binds loopback *inside* the container and only the API port is published. If
you split the roles, keeping the engine port unpublished is your
responsibility.

---

## Honest limits

- **One GPU target.** gfx1151 only, by construction.
- **Text only.** The model has a vision encoder; SUPERFAST does not use it.
- **Unassisted decode is not our strong suit** — see the comparison above.
- **Cold time-to-first-token at very long context is slow.** A genuinely cold
  262K prompt is a multi-minute prefill. The prompt cache makes the *second*
  turn fast; it cannot make the first one fast.
- **One default is not byte-identical to the engine's built-in one.** The
  image ships full W4A4 promotion, worth +9% prefill, against about −0.45 pt
  top-1 aggregate (better at deep context, worse in the first ~12%). It does
  not affect the guarantees above — speculation is still exact against serial
  greedy, warm cache still matches cold, batched still matches solo. Roll it
  back with one environment variable; see [`docs/FLAGS.md`](docs/FLAGS.md).
- **The comparison table is cross-published, not head-to-head.** We have not
  run the other engines ourselves on our box under matched settings. When we
  do, we will publish whatever it says.

---

## Choose a model profile

The machine runs **one model profile at a time**, and every profile serves
the same OpenAI-compatible endpoint on port 8731. Clients — scripts, apps,
AgentBridge — never change their configuration when you switch: the model
behind the endpoint is the only thing that changes. Stopping one profile
releases its memory before the next one loads, so dense 27B, the Flash-Next
MoE and any future profile do not compete for resources.

Use the switch tool on the machine:

```bash
superfast-switch status          # what is running now
superfast-switch use dense       # Qwen3.8-27B (halogen engine)
superfast-switch use flash       # Qwen3.8-Flash-Next MoE (needs its weights)
superfast-switch stop            # stop everything
```

The tool stops the current profile, starts the requested one and waits until
`/health` answers, so after `use` the endpoint is ready. The `flash` profile
refuses to start until its checkpoint has finished downloading. The measured
numbers behind each profile live in the Performance section and are updated
as new models are validated on this machine.

---

## Make it your personal assistant with AgentBridge

The machine you built is a fast and private LLM server. The last step turns
it into a personal assistant you can actually talk to.

**What AgentBridge is, in plain words.** AgentBridge is a program that runs
your own AI agents on a normal computer. You chat with it in a terminal and
it can do real work for you: reading and summarizing your documents, drafting
files, working with spreadsheets, browsing the web, sending email. Everything
runs on your own hardware and stays private. AgentBridge is self-hosted and
open source, and it follows a "bring your own model" approach: it uses
whatever LLM you point it at — and that is exactly what the SUPERFAST server
on this machine provides.

**Where it runs.** AgentBridge does not have to run on the Fedora machine.
The Fedora machine is the brain: an OpenAI-compatible API on port 8731.
Install AgentBridge on your everyday computer (Windows, Linux or macOS), add
the SUPERFAST server as its model provider, and the assistant works locally
on your computer while asking the server for intelligence. The API needs no
key on a private network.

**How to install it.** AgentBridge ships self-contained binaries, so no .NET
runtime is needed. On Windows, open PowerShell and run:

```powershell
irm https://graphenelab.it/AgentBridge/install.ps1 | iex
```

On Linux or macOS:

```bash
curl -fsSL https://graphenelab.it/AgentBridge/install.sh | bash
```

Alternatively, download the archive for your operating system from the
[download page](https://graphenelab.it/AgentBridge/download/). Then start it,
type `/setup`, open the LLM and Providers tab, add the SUPERFAST server as a
provider pointing at `http://<your-fedora-host>:8731`, and leave the API key
empty.

The official repository is [github.com/Graphene-Lab/AgentBridge](https://github.com/Graphene-Lab/AgentBridge/):
there you will find the releases, the full manual and the tools the agents can
use.

---

## License

Free for any use, including commercial. Unmodified redistribution permitted.
Benchmark publication expressly permitted. See [`LICENSE`](LICENSE.md) and
[`THIRD-PARTY-NOTICES`](THIRD-PARTY-NOTICES.md), both also at `/licenses`
inside the image.

**Model weights are not included and are not covered** by that license. They
are obtained separately and licensed by their original authors.
