# SUPERFAST

![SUPERFAST logo — a speedometer](assets/superfast.gif)

**Run a high-quality open LLM on an AMD Ryzen AI Max machine: fast, and in private.**

What it runs — four open-weight models, everything below measured on this
machine:

| profile | model | speed here (prose / code) | best for |
|---|---|---|---|
| `dense` | **Qwen3.8-27B**, dense, 27B parameters | 21.0 / 26.1 t/s | the highest quality per token; quality before speed |
| `flash` | **Qwen3.8-Flash-Next**, mixture-of-experts, 125B in total, 6B active per token | 37.7 / 46.4 t/s | the default: close to the dense quality, about 1.8× the speed |
| `gemma` | **Gemma-4-26B-A4B**, 25.2B | 57.3 / 57.6 t/s | the fastest answers; its family can read images, but this profile is text only |
| `deepseek` | **DeepSeek-V4-Flash**, 284B in total, 13B active | 11.2 / 11.3 t/s | a 512K context window and hard mathematics |

![The GNOME panel menu: the four profile names from the table above, the running one marked, the orchestrator toggle below](assets/desktop-extension.png)

*The same four names, in the GNOME panel of the machine: click one to switch
profile. The filled circle marks what is running now, the entry below toggles
the small orchestrator, and the last one opens the terminal menu.*

One model at a time, on one OpenAI-compatible endpoint. On the machine itself
that endpoint is `:8731`, on loopback; from your network it is the API-key
gateway on `:8741`, and without the key there is no access at all. Switch with
one click in the GNOME panel, or with one command over SSH. No subscription,
nothing leaves the machine. The full comparison with paid models, and the
measured numbers, are further down.

New to this? Read the **[plain-language guide](docs/PLAIN-GUIDE.md)** first.
It is written for readers who are not engineers.

## What this project is

SUPERFAST is a goal, not a fixed architecture. The goal is to take an AMD
Strix Halo APU (gfx1151, for example the Ryzen AI Max+ 395) and run excellent
open LLMs on it as fast as the hardware allows, without giving up quality.

One property of this hardware makes that possible: the CPU and the GPU share
one pool of fast LPDDR5X memory. The 16 Zen 5 cores and the Radeon 8060S
graphics use the same 124 GB — the usable part of the 128 GB installed on
this machine. AMD's ROCm stack turns that shared memory into GPU compute. A
general-purpose engine cannot use all of it. A machine built for it can.

The project turns that machine into a repeatable recipe:

- a Fedora installation,
- models running in containers that carry their own ROCm,
- a small switch that selects which model is active.

Numbers that describe this machine were measured on it. Where a table in this
document quotes somebody else's figures, it says so next to the table.

### A note on names

The project is called SUPERFAST. The container images and the model
repository were published before the rename, so they still use the old name
`halogen`. The commands below use that name, because it is the name that
exists today.

A running model is called a **profile**. Only one profile runs at a time, and
every profile serves the same OpenAI-compatible endpoint on port 8731. The
tools you connect to the machine never change their configuration. Today the
machine runs four profiles, in order of size: the dense Qwen3.8-27B (27B
parameters), the Qwen3.8-Flash-Next mixture-of-experts (125B in total, 6B
active per token), Gemma-4 (25.2B) and DeepSeek-V4-Flash (284B in total) —
that is, up to a 284-billion-parameter model running entirely on the machine.
Other models can be added the same way. See
[Choose a model profile](#choose-a-model-profile).

**Why one model at a time.** This is a deliberate architecture choice, not a
limitation. A single model gets the whole machine: all of the unified memory
for its weights and its KV cache, and therefore the largest context window the
machine can hold for it — 262,144 tokens for the Qwen and Gemma profiles, and
512K for DeepSeek-V4-Flash, which is half of its 1M because the full 1M leaves
too little memory to stay stable (see
[What each profile ships](#what-each-profile-ships-context-tokens-tools)).
Running two large models at once would mean
splitting that memory, and the first thing to shrink would be the context
window — which is exactly what an agent needs most: a long window that holds
the conversation, the tool definitions, and the files being worked on. That is
also why every profile ships an agent-ready configuration: tool calling, a
large answer budget, prompt cache, and sampling defaults from the vendor.

The one companion allowed to share the machine is the small orchestrator: a
1.2B-parameter model that decodes at about 220 tokens per second and occupies
a couple of gigabytes — insignificant on a machine with 124 GB of unified
memory. It can stay resident while a large model works, and it costs that
model one to two percent of memory bandwidth. Everything else waits its turn.

### A measured starting point

On the reference machine, the dense Qwen3.8-27B profile answers a 32K prompt
with a 256-token answer faster than the fastest published numbers for the
same model on the same silicon from other runtimes:

| | prefill | decode | **total** |
|---|---|---|---|
| **SUPERFAST** dense profile (6.32 bpw) | **57.9 s** | 8.1 s | **66.0 s** |
| [KyaniteLabs](https://github.com/KyaniteLabs/qwen38-27b-strix-halo) (Q4_K_XL) | 84.0 s | 8.5 s | 92.5 s |
| [q38rocm](https://github.com/julianmb/q38rocm) (4.26 bpw) | 133.7 s | 7.8 s | 141.5 s |

That is **2.1× faster than q38rocm and 1.4× faster than KyaniteLabs** end to
end, with about 1.5× their weight precision. Most of the gain is in prefill,
and prefill is most of the wall-clock time on any prompt with real context.
Speculative decoding in this engine produces byte-identical output to serial
greedy decode: it is a speed optimization, not a quality trade, and it is
checked on every release.

**Read that table together with the memory layout.** These engine-level
numbers were measured with the 64 GB UMA carve (the older layout of this
machine). The current layout uses a 1 GB UMA carve, which the large MoE
checkpoints require; in that layout the same dense profile measures about 12%
lower (21.0 t/s prose, 26.1 t/s code — see the
[measured profiles](#performance-tuning-on-fedora-44--what-we-tested)). The
comparison above is still the right one for the engine itself, because the
other projects were measured under comparable settings.

If you do not have the machine yet, [build it step by
step](#set-up-a-new-machine). If you already have it, pick a model with
`superfast-switch` (see [Choose a model profile](#choose-a-model-profile)).

---

## Set up a new machine

You need a Linux machine before you start. Follow these steps in order; this
is the path we used on a Ryzen AI Max+ 395.

**The whole journey, in order.** Each step links to its section below.

1. Install Fedora Workstation 44 and enable SSH — [step 1](#1-install-fedora-workstation-44-recommended).
2. Connect to the machine over SSH — [step 2](#2-connect-to-the-machine-over-ssh-optional-but-recommended).
3. Run the setup script: it downloads the model and starts the engine — [step 3](#3-configure-the-machine-for-superfast).
4. Download the weights and learn the API — [Get the weights](#get-the-weights).
5. Measure and compare the speed — [Performance](#performance).
6. Point your coding agent at the machine — [Recommended client configuration](#recommended-client-configuration-qwen-code-or-any-agentic-client).
7. Turn the machine into your personal assistant — [AgentBridge](#make-it-your-personal-assistant-with-agentbridge).

### 1. Install Fedora Workstation 44 (recommended)

This is the distribution we recommend. The reasons:

- **It is current.** Fedora 44 is the latest stable release (April 2026) and
  receives updates into 2027. It has the newest stable kernel and Mesa. That
  matters here: support for a new AMD APU like Strix Halo (gfx1151) comes
  from the upstream kernel and Mesa, not from patches added by a
  distribution.
- **ROCm comes from Fedora itself.** AMD's installer (`amdgpu-install`)
  targets Ubuntu and Red Hat families, not Fedora. Fedora packages the open
  ROCm stack in its official repositories instead, so you install it with
  `dnf` and updates arrive with the release. No third-party repositories.
- **It is a normal, well-known desktop.** Fedora Workstation is the same
  GNOME desktop used on millions of machines, with a simple installer
  (Anaconda) that offers disk encryption and automatic partitioning.

Steps:

1. Download the **Fedora Workstation 44** ISO (x86_64) from
   [getfedora.org](https://getfedora.org).
2. Write it to a USB stick with [Fedora Media Writer](https://fedoraproject.org/workstation/download),
   or with any USB writer you trust.
3. Boot the machine from the USB stick. In the installer, choose your disk,
   decide whether to encrypt it, create your user account, and pick a
   hostname.
4. Reboot into the installed system, open a terminal, and enable SSH, so that
   the rest of the setup can run from your PC:

   ```bash
   sudo dnf install -y openssh-server
   sudo systemctl enable --now sshd
   ```

Remember the user name you created: you need it in step 2.

### 2. Connect to the machine over SSH (optional, but recommended)

If the machine has no keyboard or monitor, do all the configuration from your
PC over SSH.

**Option A — with Pi Easy Connect (you only need an Ethernet cable).**
[Pi Easy Connect](https://github.com/Graphene-Lab/pi-easy-connect) shares the
Windows PC's internet connection with the machine over a direct Ethernet
cable (Windows ICS) and opens SSH for you. It works with any Linux machine
that has a network port.

1. Connect an Ethernet cable between the PC and the machine.
2. Run `.\pi-easy-connect.ps1 -SshUser <your-fedora-username>`.
3. You land in the machine's shell, with internet on the `192.168.137.x`
   subnet.

The ICS lease can change at each reboot. To make the address fixed, set it
once on the machine (the subnet of the direct cable):

```bash
nmcli con mod "Wired connection 1" ipv4.method manual \
  ipv4.addresses 192.168.137.100/24 \
  ipv4.gateway 192.168.137.1 \
  ipv4.dns "192.168.137.1 1.1.1.1"
nmcli con up "Wired connection 1"
```

Then connect with `.\pi-easy-connect.ps1 -StaticIp 192.168.137.100 -SshUser
<your-fedora-username>`.

**Option B — plain SSH over your normal network.** Put the machine on your
LAN (DHCP is fine at the start) and run `ssh <your-fedora-username>@<machine-ip>`
from any computer on the same network. If SSH times out, open the port on the
machine:

```bash
sudo firewall-cmd --add-service=ssh --permanent
sudo firewall-cmd --reload
```

### 3. Configure the machine for SUPERFAST

A fresh Fedora install is almost enough, because the SUPERFAST image carries
its own ROCm user-space. The machine needs:

- a kernel whose amdgpu driver exposes `/dev/kfd` and `/dev/dri` for gfx1151 —
  a stock Fedora 44 already does,
- a container runtime (Podman or Docker),
- your user in the `video` and `render` groups,
- disk space for the model checkpoints — see
  [Get the weights](#get-the-weights).

All of the above is validated on a Ryzen AI Max+ 395 running Fedora
Workstation 44. There are two ways to get there:

- **Automated:** `bash deploy/setup-fedora.sh` takes a fresh machine to a
  running SUPERFAST service: system update, SSH, GPU groups, auto-suspend off,
  the kernel memory parameters, checkpoint download with exact-offset resume,
  and the engine installed as `superfast.service`, waiting for `/health`. On a
  fresh machine the **first run stops on purpose** after adding your user to
  the GPU groups: that change only applies to a new session, so it prints
  "log out, log back in, then run this script again" instead of failing ten
  minutes later with a container that cannot reach the GPU. The second run
  finishes the job. Add more profiles with `PROFILES`:

  ```bash
  # dense (default) is prepared alone
  bash deploy/setup-fedora.sh

  # the whole set: two engine profiles, two GGUF profiles, the small router
  PROFILES="dense flash gemma deepseek small" bash deploy/setup-fedora.sh
  ```

  The weights of the extra profiles are fetched by one systemd service per
  profile, so the script returns instead of waiting hours for them, the
  transfers resume after a reboot, and each file is checked against the
  SHA-256 published by Hugging Face before it is used. Gemma, DeepSeek and the
  orchestrator also need the GGUF runtime image, which the script builds when
  it is not present on the machine yet.
- **Step by step:** every phase of the script is a command that was run and
  verified on the reference machine, in order. Read the script with
  `less deploy/setup-fedora.sh` if you prefer to do it by hand; it is
  commented phase by phase. The chronological log we kept while building the
  machine is not published, because it contains host-specific details.

Things we learned on the reference machine:

- **No ROCm on the host.** AMD's `amdgpu-install` does not target Fedora, and
  it is not needed: the image bundles ROCm (see `THIRD-PARTY-NOTICES`).
- **Slow or unstable link?** Do not use `hf download` for the big files. Its
  transport can stall, and its resume starts over because the server changes
  the file tag between runs. Use the `curl -C -` loop in
  `deploy/setup-fedora.sh` instead: it resumes at the exact byte offset and
  loses nothing. `hf download` is fine on a fast link, for the smaller files.
- **BIOS memory split.** Set the UMA frame buffer to its minimum in the
  firmware, so that the whole unified memory is one pool. The large
  checkpoints need it.
- **Two kernel parameters, not one.** The GPU can only use part of the shared
  memory unless you raise both limits, and the allocatable size is the
  **smaller** of the two:
  `amdgpu.gttsize=118784` (116 GiB) and `ttm.pages_limit=31457280`
  (120 GiB, counted in 4 KiB pages). Both must be on the kernel command line,
  because the driver fixes the pool size when it loads. With the defaults,
  only about 62 GiB are usable, which is not enough for the largest
  checkpoints. Measured proof: the default `ttm.pages_limit` of 16309919
  pages × 4096 bytes = 63710 MiB, which is exactly the amount the GPU
  runtime reported. The setup script applies both, with a reboot.
- **Disk encryption is a choice, and it has a cost.** The installer offers
  encryption, and the reference machine does *not* use it. If you enable it,
  every reboot stops at the passphrase prompt on the console, so a machine
  without a keyboard cannot reboot on its own. TPM2 auto-unlock is a possible
  future option.
- **SELinux stays Enforcing.** Passing `/dev/kfd` and `/dev/dri` into
  rootless Podman works without changes.
- **The engine runs as a systemd user service** (`superfast.service`): it
  starts at boot, restarts on failure, and serves the OpenAI-compatible API
  on port 8731.

---

## Get the weights

Images contain the engine, not the weights: the dense image is 3.5 GB of
engine, and its checkpoint is 35.9 GB. Each profile keeps its weights in its
own directory, and the setup script and the switch know those paths.

| profile | weights directory | files (size in bytes) | source |
|---|---|---|---|
| dense | `~/superfast-models` | `qwen3.8-27b-p1w4d-d2.hgn` (35,865,565,184) + `tokenizer/` | HF `peonist-ai/halogen-qwen3.8-27b` |
| flash | `~/superfast-flash` | `qwen38-flash-next-w4b.hgn` (124,068,083,904), `…overlay.hgn` (2,477,677,120), `…overlay-speed.hgn` (2,383,306,048) + `tokenizer/` | HF `peonist-ai/halogen-qwen3.8-flash-next` |
| gemma | `~/gemma-models` | `gemma-4-26B-A4B-it-Q4_0_ROCMFP4_COHERENT.gguf` (14,439,364,064), `mtp-gemma-4-26B-A4B-it-Q8_0.gguf` (461,766,816) | HF `kingjones777/Gemma-4-26B-A4B-it-ROCmFP4-GGUF` |
| deepseek | `~/deepseek-models` | `…ROCMFPx-Strix-Lean-2.58bpw.gguf` (91,547,243,200), `…DSpark-draft-4.25bpw.gguf` (10,897,111,840) | HF `otheru/DeepSeek-V4-Flash-Strix-Halo-GGUF` |
| orchestrator | `~/small-models` | `LFM2.5-350M-Q4_K_M.gguf` (229,312,224), `LFM2.5-1.2B-Thinking-ToMoE-Q4_K_M.gguf` (730,898,432) | HF `LiquidAI/LFM2.5-350M-GGUF` and `Nichonauta/LFM2.5-1.2B-Thinking-ToMoE-GGUF` |

Two things the table does not show. The `gemma` and `deepseek` profiles need a
second runtime, the GGUF server image built from
[`runtime/`](runtime/README.md). It is published by this repository's workflow
as `ghcr.io/graphene-lab/superfast-runtime:llama-rocmfpx-1`, and the setup
script pulls it and tags it as `llama-rocmfpx:7.2.4`. It is public, so no login
is needed; if the pull fails (no network, or you prefer to build it yourself)
the script builds it from `runtime/` instead. And neither speculative head in
the table works in our
stack today: the Gemma MTP file needs a draft-context flag this runtime build
rejects, and the DeepSeek DSpark file is built for another runtime (`unknown
model architecture`). The measured Gemma and DeepSeek numbers are therefore
without speculation.

For the dense profile, download the checkpoint once and mount it:

```bash
pip install -U "huggingface_hub[cli]"
hf download peonist-ai/halogen-qwen3.8-27b \
  --local-dir ~/superfast-models
```

That repository holds both the `.hgn` checkpoint and **a flat tokenizer
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
  ghcr.io/peonist-ai/halogen:0.1.3
```

This manual run is optional: `superfast-switch use dense` starts the same
profile as a managed service. On Docker instead of Podman, replace
`--group-add keep-groups` with `--group-add video --group-add render`;
`keep-groups` is a Podman keyword that Docker cannot resolve.

> **Check what you downloaded.** Hugging Face publishes a SHA-256 for every
> weight file, and it is worth comparing it before you trust the file. A
> truncated or wrongly assembled download can still load and quietly be the
> wrong model — that happened to us during development, which is why every
> weight used here is checked.
>
> ```bash
> sha256sum ~/superfast-models/qwen3.8-27b-p1w4d-d2.hgn
> # compare with the LFS SHA-256 shown on the file's page on Hugging Face
> ```
>
> The small orchestrator models were checked this way, and both match the
> published sums:
> `LFM2.5-350M-Q4_K_M.gguf` → `7e6f72643caafc9a68256686638c4d7916f2cec76d1df478d4c3ddcd95a6aed4`,
> `LFM2.5-1.2B-Thinking-ToMoE-Q4_K_M.gguf` → `6f071c4f5893ca93a265613a0009f4db745bc79b50808ab1ce9a8821caf511d0`.
> The big files were checked the same way; these are the values that matched
> Hugging Face exactly:
> `qwen38-flash-next-w4b.hgn` → `9c116bbc01f77b7a15464c1a124eb3325b286089b8a2a6f2856c9b246a235bd6`,
> `qwen38-flash-next-w4b.overlay.hgn` → `737d6bdaef274d3cc22de5bc265b390b89db5fb1e709f58db75287fdc35bb276`,
> `qwen38-flash-next-w4b.overlay-speed.hgn` → `113d77358107549fa22e06643ae3a524908aa7ea011afaebec69fc5f1991c370`,
> `DeepSeek-V4-Flash-0731-Abliterated-ROCMFPx-Strix-Lean-2.58bpw.gguf` → `a936e0a514385c8ae964c0f42263a4314a34fbc6efea9d9aced5320f320a3d54`.
> The DeepSeek speculative drafter has its own published sum
> (`1a01c80eceae302bcc1d70836759ee97974d7983c5084ef43f6ef772a8970ae6`); our
> first copy of it was damaged because two downloads wrote the same file, so
> the downloader now takes a lock and checks the sum before renaming the file.

### Or let SUPERFAST fetch the weights for you

If you do not want to download separately, set `HALOGEN_DOWNLOAD` and the
container fetches the weights on the first start:

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --security-opt seccomp=unconfined --ipc=host \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-27b \
  -e HALOGEN_TOKENIZER=/models/tokenizer \
  -v ~/superfast-models:/models \
  ghcr.io/peonist-ai/halogen:0.1.3
```

Two differences from the manual route. The models volume is mounted
**read-write**, because the download writes into it. And there is only *one*
mount: the download brings the tokenizer with it, so `HALOGEN_TOKENIZER`
points inside `/models` instead of at a second volume. Mounting
`~/superfast-models/tokenizer` here would fail on a first run, because the
container runtime would create it as an empty directory before the download
could fill it.

The download starts only when the checkpoint is missing, so a restart does
not download it again, and an interrupted transfer resumes.

**With `HALOGEN_DOWNLOAD` unset, the container opens no outbound network
connection at all** — no telemetry, no license check, no model fetch. If the
checkpoint is not on disk where `HALOGEN_CHECKPOINT` points, the container
says so and exits instead of reaching for the network. That default is
deliberate: a 35.9 GB transfer should not start because someone ran
`podman run` to see what happens.

Model weights are licensed separately from the engine, by their original
authors; see the model repository for those terms.

---

## Performance

> **Which machine produced these numbers.** The engine-level figures in this
> section (prefill, decode distribution, the comparison table) come from the
> reference machine *before* it moved to the UMA 1 GB layout, and from the
> engine's own `bench`/`sweep` tools. The profile table further down uses the
> current layout and a different tool. Do not compare the two line by line:
> in the current layout the dense profile measures about 12% lower (see
> [A measured starting point](#a-measured-starting-point)).

Measured on a Ryzen AI Max+ 395 (Radeon 8060S, 128 GB LPDDR5X), ROCm 7.14.0,
checkpoint `p1w4d-d2` (~6.3 bits per weight effective at decode), 262,144
context.

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

### Read the range, not only the mean

**The decode rate of this engine is a range, not one number.** Speculative
decoding accepts more drafted tokens when the text is predictable, so the
same build on the same hardware does:

- **prose / chat: 20.8 – 23.5 t/s**
- **procedures: 25.6 – 38.7 t/s**
- **code / proofs: 32.7 – 44.2 t/s**

A single headline number hides a factor of two. A decode number from this
project — quoted by us or by anyone else — should name the prompt set that
produced it, or it cannot be reproduced. `bench` prints the mean; `sweep`
prints the mean, the standard deviation and the min–max, for this reason.

An engine without speculative decoding has a decode rate that does not depend
on the text, so it can quote a single number. This engine cannot.

### Performance tuning on Fedora 44 — what we tested

Measured profiles on the reference host (2026-09-10, Fedora 44, the same
memory layout for every row: BIOS UMA 1 GB, unified pool,
[`tools/quick-bench.py`](tools/quick-bench.py), greedy, `reasoning_effort:
low`, `max_tokens: 192`, 3 reps; repeatable within about ±2% when nothing else
is running on the machine; the Gemma-4 row uses a 512-token budget — see its
note):

| profile | runtime | prose | code | context probe (~2.2K) |
|---|---|---|---|---|
| Qwen3.8-27B dense, p1w4d-d2 (~6.3 bpw) | halogen engine | **21.0 t/s** | **26.1 t/s** | ~528 t/s |
| Gemma-4-26B-A4B it, Q4_0 ROCmFP4 | llama-rocmfpx | **57.3 t/s** | **57.6 t/s** | ~1527 t/s |
| Qwen3.8-Flash-Next MoE w4b | halogen-flash | **37.7 t/s** | **46.4 t/s** | ~709 t/s |
| DeepSeek-V4-Flash ROCmFPX (~2.6 bpw) | llama-rocmfpx | **11.2 t/s** | **11.3 t/s** | ~163 t/s |

DeepSeek-V4-Flash deserves its own note, because it needed a change to the
machine itself. The weights are 91.5 GB, of which the runtime wanted about
86.9 GB in one single GPU allocation. With the default kernel settings the
GPU path can claim only about 62 GiB, so the load failed with
`cudaMalloc failed: out of memory`. The memory was physically there — the
machine has 124 GB in one pool — but the driver caps how much of it the GPU
may use. Two values define that cap, and the allocatable size is the smaller
of the two:

| parameter | default | set to | meaning |
|---|---|---|---|
| `amdgpu.gttsize` | auto (half of RAM) | `118784` | GTT aperture, in MiB (116 GiB) |
| `ttm.pages_limit` | 16309919 pages | `31457280` | TTM limit, in 4 KiB pages (120 GiB) |

Evidence for "the smaller of the two": with the default `ttm.pages_limit`,
16309919 pages × 4096 bytes = 63710 MiB, and the GPU runtime reported
exactly 63710 MiB of usable device memory. Raising only `amdgpu.gttsize` is
not enough; raising `ttm.pages_limit` at runtime is not enough either,
because the driver fixes the pool size when it loads. Both parameters must be
on the kernel command line, followed by a reboot:

```bash
sudo grubby --update-kernel=ALL --args="amdgpu.gttsize=118784 ttm.pages_limit=31457280"
sudo reboot
```

With both applied, the profile loads. Keeping part of the model's experts on
the CPU was tried as a workaround before that, and it failed even for
sub-gigabyte buffers under memory pressure, so it is not a substitute here.

The DeepSeek profile is the slowest of the four, and that is expected: it has
about 284 billion parameters, and even at ~2.6 bits per weight it reads far
more per token than the 27B dense model. The row above is a 192-token budget;
measured with a 512-token budget it is 10.9 t/s on prose and 11.0 on code, so
the numbers agree within about two percent across three independent runs.
Two things lower it in practice, both measured:

- **Long generations decode more slowly, but less than it first looked.** With
  the profile at its full 1M context a 1024-token request ran at 7.2 t/s; at
  the shipped 512K the same request finishes in 101 s, which is 10.1 t/s. That
  earlier figure was measured while the machine was starved of memory, not as
  a property of the model.
- **Two requests at once are each slower** (one of two concurrent 512-token
  requests measured 6.4 t/s), because this profile serves four slots in
  parallel. One client at a time gets the fast number.

One caveat, the same as Gemma-4: this model reasons at length. With a
192-token budget, a 512-token budget and a 1024-token budget, every request we
measured spent the **whole** budget on reasoning and returned an empty
`content` with `finish_reason: "length"` (the 1024-token one produced 7020
characters of reasoning). Give clients a large `max_tokens`, and read
`finish_reason` before concluding that the model failed. If you want short
answers, this is not the profile for that.

This profile has **no speculative decoding** in our stack, and we tried. The
model ships a DSpark drafter (the 10.9 GB file in the table above), we
downloaded it and its SHA-256 verifies, but the file is built for the Ember
runtime: when our llama.cpp build is given it, it stops with
`unknown model architecture: 'deepseek4-dflash-draft'`. So the numbers above
are what the profile gives without speculation, and there is no flag we can
add today that changes that.

Two notes on the dense row. Its numbers are **23.9/29.5 t/s under the old
BIOS with a 64 GB GPU carve**; moving to UMA 1 GB (which the large MoE
checkpoints need, and which matches AMD's guidance for large models) costs
the dense profile about 12%, because its weights now live in the shared
system pool. Every A/B on this machine is therefore measured in the same
memory layout. And the Gemma row is **without its MTP drafter** (the
speculative head): we keep it disabled until the draft-context flag is
resolved in the runtime, and the few percent it adds are not included.

Where the weights live is the one placement lever that matters: the dense
profile is ~12% faster when its weights sit in the GPU carve instead of the
shared pool, because decode is limited by DRAM bandwidth, and this APU has a
single LPDDR5X bus (there is no closer cache or HBM to move to). Inside a
region, small levers change nothing: on Gemma-4 ROCmFP4, `llama-bench`
reports pp512 ~1480 t/s and tg128 **60.6 t/s** (the publisher's own ceiling)
with default settings, and thread counts or batch sizes move those numbers by
less than 1%. N-gram self-speculation changes nothing either (measured:
prose 51.5 against 52.2 without it).

How the profiles behave, beyond speed: both answer the same probes correctly
when they have enough budget — a logic riddle, arithmetic and a code-bug
question all came back right. They differ in *how*. The dense Qwen profile
answers briefly and directly (a few reasoning tokens). Gemma-4 reasons at
length before answering and needs a generous `max_tokens`: with a 192-token
budget its answers came back empty, because all the budget went into
thinking. That is why the Gemma row above uses a 512-token budget. Cutting
Gemma's thinking short also hurts accuracy, not only style: with thinking
effectively disabled it answered the arithmetic probe wrongly (65 instead of
67). The practical rule for clients: dense Qwen suits tight budgets and quick
turns; Gemma-4 needs room to think but stays correct, and its raw decode is
much faster.

We also tested three well-known tuning levers against the dense baseline and
rolled them back, because none of them changed anything:

| setting tried | effect | outcome |
|---|---|---|
| `tuned-adm profile accelerator-performance` (CPU performance governor + EPP) | prose 23.90, code 29.47 (old layout) | **no change** — reverted to `balanced` |
| GPU performance level `high` (force maximum clocks) | prose 23.90, code 29.49 | **no change** — reverted to `auto` |
| `transparent_hugepage=always` | prose 23.89, code 29.49 | **no change** — reverted to `madvise` |

Why nothing moved: batch-1 decode runs at the memory-bandwidth wall
(249 GB/s against a ceiling of about 240 GB/s), and these levers change
clocks or page granularity, not bandwidth. Prefill did not change either.
Overclocking advice from specialists (`ppfeaturemask`/`pp_od_clk_voltage`, or
UXTU on Windows) targets clock-limited paths. It does not apply to a
bandwidth-limited decode workload, and it would need a kernel parameter and a
reboot.

Context depth and the KV cache were measured on Gemma-4: decode ran at 56.1
tokens per second on a 442-token prompt, 50.0 on 1,325 tokens and 46.0 on
1,761 tokens with the default f16 KV cache. Switching to a quantized q8_0 KV
cache was four to six percent *slower* at those depths, so the default stays.
The fork's FP4/TURBO cache types were not accepted by this runtime build (the
server refused to start), so they are a candidate for a future runtime
revision, not a setting we ship.

**Conclusion:** the stock Fedora 44 configuration already performs at the
practical ceiling for this machine. Real gains come from choosing the right
profile (MoE/FP4 for speed, dense for precision), not from tuning knobs.
You can re-measure any profile at any time with:

```bash
python3 tools/quick-bench.py --api http://<host>:8731
```

### A faster family of this model: Qwen3.8-Flash-Next (MoE)

The default checkpoint, Qwen3.8-27B, is a dense model. A dense model reads
every parameter from memory for every token it generates, and on this machine
memory bandwidth is the hard limit. That is why generation lands at about 24
tokens per second on prose and 29 on code, end to end.

Qwen3.8-Flash-Next belongs to the same family but uses a mixture-of-experts
design. It holds far more parameters in total, but for each single token only
a small subset of its experts is active. Reading fewer weights per token
means more tokens per second on the same memory bandwidth. This is why a
larger model can be the faster model on this kind of hardware.

The published checkpoints for the engine support this with three files. The
main one is the 4-bit MoE checkpoint. Beside it there is a quality overlay,
which re-quantizes the most sensitive tensors with extra care and measures on
par with full precision for those rows; removing it costs several percent on
perplexity. The third file, the optional speed arm, is a different trade: it
swaps that calibration for a quantization that decodes about two percent
faster.

Running Flash-Next needs the full 124 GB of unified memory as one pool,
because the checkpoint alone is about 115 GB. On the reference host that meant
setting the BIOS UMA frame buffer to its minimum, so that the firmware stops
reserving a fixed slice of memory for the GPU; the engine then draws what it
needs from the shared pool. This is the configuration AMD describes for large
models on these APUs.

The measured comparison between the dense checkpoint and Flash-Next on this
machine is in the table above: Flash-Next answers at **37.7 tokens per second
on prose and 46.4 on code** end to end, against 21.0 and 26.1 for the dense
profile in the same memory layout — about **1.8 times faster** — while using
45 GB of memory instead of 36, and holding a 262,144-token context. Its cold
load from disk to a healthy endpoint took about forty seconds.

**Speculative decoding was already on, and the reading that said otherwise was
wrong.** The MTP head lives in the checkpoint and the engine drafts with it by
default, with no configuration. `/health` used to report
`drafter_weights_loaded: false` on every build of the server, this profile's
included: it was a reporting bug, not a fact, and the server's 0.5.6 changelog
documents the fix. The numbers above are therefore measured **with**
speculation. The same release line also made long prompts prefill faster: on
this machine, moving from the shipped 0.5.2 to 0.5.6 raised prefill from 1,097
to 1,180 tokens per second at an 8K prompt and from 1,239 to 1,339 at 32K
(byte-identical output), while decode stayed where it was.

---

## How it compares

Published numbers from other projects running **the same model on the same
silicon**. These are *their* figures on *their* configurations, not a
head-to-head run by us. Quantization, KV-cache settings and context differ,
so use the table as a rough guide, not as a controlled comparison.

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
not a product configuration. No project in this table uses serial decode in
production; every one of them runs speculation by default. The gap is also
not a kernel-quality issue: decode is bandwidth-limited. q38rocm streams
about 17 GB per token against our 23.5, and fewer bits is simply faster.
SUPERFAST spends those bits deliberately (see
[`docs/QUANT.md`](docs/QUANT.md)): the only 4-bit tensors in our trunk are
ones calibrated by somebody else, and the aggressive technique is fenced to
prefill, where it never touches token generation.

**Batch-1 decode is at the hardware wall.** 10.58 t/s × 23.51 GB per token =
249 GB/s against a measured ceiling of 240 GB/s. No kernel win is left there
for anyone; what is left is fewer bits, better draft acceptance, and
batching.

**About the 148–163 t/s figure** that circulates for llama.cpp on this
hardware: it is an artifact of n-gram repetition on back-to-back identical
runs, and KyaniteLabs — whose benchmark it is — says so, and warns against
quoting it. We think that is the right way to publish, and we have tried to
match it.

---

## Benchmark it yourself

The image ships both benchmarks. There are no fixtures to prepare, no extra
download, and nothing you have to ask us for.

```bash
# ten real prompt shapes over the HTTP endpoint — the reference number
podman run --rm --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --security-opt seccomp=unconfined --ipc=host \
  -v /path/to/models:/models:ro -v /path/to/tokenizer:/tokenizer:ro \
  ghcr.io/peonist-ai/halogen:0.1.3 bench dflash2 256 low 3

# llama-bench-shaped pp/tg sweep, to put a number next to another engine
podman run --rm ... ghcr.io/peonist-ai/halogen:0.1.3 \
  sweep -p 512,2048,8192 -n 128,256 -d dflash2,mtp -r 3
```

`sweep --json` produces machine-readable output.

**Publishing the results is expressly permitted** — no approval, no notice, no
review. We only ask that figures name the version and the prompt set, for the
reason given above. That request is not a licensing condition.

---

## What every profile inherits from the engine

All profiles run on one of two purpose-built engines: the Qwen profiles on the
halogen engine (a dense build and a Flash-Next build), the Gemma, DeepSeek and
orchestrator profiles on the ROCmFPX llama.cpp runtime. The properties below
belong to the Qwen engines; `/health` reports what the running profile
supports. Every engine setting is named `HALOGEN_*` — the `SUPERFAST_*` names
belong to this project's own tools, and
[`docs/FLAGS.md`](docs/FLAGS.md) says which is which.

**Byte-identical speculative decoding.** Draft-then-verify commits only the
tokens the full model would have produced, so the output is bit-for-bit
identical to serial greedy decode. This is checked on every release, for all
three drafters — measured, not asserted. Speculation here is a pure speed
optimization with no quality cost, and you can turn it off per request to
check.

**Native 262,144-token context**, with decode that barely degrades at depth.
Gated DeltaNet carries O(1) state, so 48 of 64 layers have no KV cache at all.

**Prompt cache** — a follow-up turn in a long conversation resumes instead of
re-prefilling, worth roughly 20× on time-to-first-token at 32K. Byte-identity
of a warm answer depends on the profile, and the engine says which: the dense
profile aligns its snapshots and its log states "warm decode is BITWISE
identical to cold", while the Flash-Next profile keeps the KV in place and
reports the opposite on purpose ("a warm answer is NOT bitwise the cold one").
Both resume the conversation; only the dense profile promises byte-identity.

**Batched decode** — several sequences decoded together, each byte-identical
to running alone. The dense engine serves one request at a time by default
(`HALOGEN_KV_SLOTS=1`) and reaches 8 concurrent sequences at 4.87× aggregate
when you raise it; the Flash-Next engine ships 4 slots over one shared KV
pool. Batching trades away speculation for the streams that are not alone —
see [Concurrency](#concurrency-and-the-one-trap) before changing it.

**OpenAI-compatible API** — `/v1/chat/completions`, `/v1/completions`,
streaming, tool calling, sampling with seeds, reasoning-effort control.

**Selectable drafters** — the dense engine has three (`dflash2` by default,
plus `mtp` and `serial`), the Flash-Next engine two (`mtp` by default, plus
`serial`). Choose per request; the output is identical, only the speed changes.

---

## Configuration

Everything is set by environment variable; there is no configuration file.
The complete list, with defaults and whether each one can change the output,
is in [`docs/FLAGS.md`](docs/FLAGS.md). These are the ones most people touch.
The tables below describe the dense profile; every other profile image ships
its own tuned defaults and reports them through `/health`.

| variable | default | what it does |
|---|---|---|
| `HALOGEN_CHECKPOINT` | `/models/qwen3.8-27b-p1w4d-d2.hgn` | which checkpoint to load |
| `HALOGEN_TOKENIZER` | `/tokenizer` | flat tokenizer directory |
| `HALOGEN_API_PORT` | `8731` | the published port |
| `HALOGEN_DRAFTER` | `2` (DFlash2, dense) | default drafter: `0` serial, `1` MTP, `2` DFlash2 |
| `HALOGEN_MAX_TOKENS_CAP` | `65536` | largest `max_tokens` a request may ask for — above it is a **400**, never a silent truncation |
| `HALOGEN_QUEUE_TIMEOUT` | `7200` (dense), `3600` (flash) | seconds a queued request will wait — **coupled to the cap**, see below |
| `HALOGEN_CACHE_ENTRIES` | `8` (flash) | conversations whose resumable state the prompt cache keeps — see [Many agents at once](#many-agents-at-once) |
| `HALOGEN_KV_SLOTS` | `4` (flash) | concurrent resident sequences — see below |
| `HALOGEN_CTX` | `262144` (flash) | the most context one request may use — see below |
| `HALOGEN_KV_POOL_POSITIONS` | `2 × HALOGEN_CTX` (flash) | positions resident across **all** conversations — see below |

The prefix is part of the name: the engines read `HALOGEN_*`, while
`SUPERFAST_*` belongs to this project's own tools (the installer, the switch,
the TUI, the gateway, the benchmarks) and to the client's `envKey`. **An engine
setting written as `SUPERFAST_*` is read by nobody** — neither image contains
that string, so the engine keeps its default and says nothing. The complete
list, with which image reads what, is in [`docs/FLAGS.md`](docs/FLAGS.md).

Per-request settings — drafter, temperature, top_p, seed, reasoning effort,
tools — go in the JSON body and override the server defaults.

### The token budget covers thinking, not only the answer

This model reasons before it replies, and those tokens count against the
budget. If the budget runs out in the middle of the reasoning, it does not
shorten the answer: it removes it. The reply comes back with
`finish_reason: "length"`, an empty `content`, and the partial reasoning in
`reasoning_content`, which most OpenAI clients do not display. The
per-request default is **8192**, which finished every ordinary prompt we
measured with room to spare. The ceiling is `HALOGEN_MAX_TOKENS_CAP`.

Three field names work, and they mean the same thing here:
`max_completion_tokens` (current OpenAI Chat Completions),
`max_output_tokens` (OpenAI Responses), or `max_tokens` (deprecated upstream,
but still widely sent). Send one, or send several as long as they agree; two
different values return a 400 instead of a guess about which one you meant.
`/health` lists all three under `token_budget_aliases` and reports the
default as `max_tokens_default`.

If a reply looks empty or cut short, read `finish_reason` first: `"stop"`
means you have the whole answer, `"length"` means you ran out of budget. Pass
a larger budget, or use `"reasoning_effort": "low"` to make the model think
less.

### Concurrency, and the one trap

The two Qwen profiles run different engines, and they handle concurrency
differently.

**The dense profile serves one request at a time, with speculative decoding
on** — about 31 t/s, which is the right setting for a single user. Its engine
does read `HALOGEN_KV_SLOTS` and `HALOGEN_SLOT_CTX` (the names are in the
shipped binary; the entrypoint does not forward them, so pass them with `-e`),
and each slot then owns a private KV cache. **The trap is the product:**
`slots × slot_ctx × 64 KiB`, so raising the slots without lowering the
per-slot context multiplies the allocation. Eight slots at the native 262,144
context asks for **137 GB** and will not fit. Keep the product at or below the
native context:

| `HALOGEN_KV_SLOTS` | `HALOGEN_SLOT_CTX` | pool |
|---|---|---|
| 1 | 262144 | 17.2 GB *(default)* |
| 2 | 131072 | 17.2 GB |
| 4 | 65536 | 17.2 GB |
| 8 | 32768 | 17.2 GB |
| 8 | 262144 | 137 GB — **will not fit** |

A prompt longer than `HALOGEN_SLOT_CTX` is a hard error naming the limit. It is
never silently truncated.

**The Flash-Next profile serves four sequences at once from one shared KV
pool**, so its sizes are settings rather than a product.
`HALOGEN_KV_POOL_POSITIONS` is how many attention positions are resident
across *all* conversations; each request reserves `prompt + max_tokens` of it,
and one that does not fit **waits**. The image default is twice the context,
524,288 — two full-length conversations, or four at 131K. The pool must be at
least `HALOGEN_CTX`, or the engine refuses it (`at least --ctx 262144, a
multiple of 256, at most 16777216`), and a larger one is silently shrunk at
startup unless `HALOGEN_KV_POOL_FIT=0`. The unit in `deploy/profiles/` ships a
1,048,576-position pool for exactly that reason, with `HALOGEN_MAX_TOK=16384`
— the prefill arena, which has to halve for a pool that size to fit. See
[Many agents at once](#many-agents-at-once) for the measurements and for how
to put the image defaults back.

On both engines the drafter speculates only while a stream is alone: with
several streams live, decode is batched instead. That is why a single user
gets the fastest numbers, and why parallel agents each run slower than one
agent would.

### Raising the output cap

`HALOGEN_MAX_TOKENS_CAP` and `HALOGEN_QUEUE_TIMEOUT` are coupled and
should not be moved independently. The cap bounds how long one request can
hold the GPU; the timeout bounds how long the next client waits for it. **If
a full-length request can outlast the timeout, everyone queued behind it gets
a 503.**

At high reasoning effort decode runs at around 10 t/s, so:

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
does ask for a full-length reply does not 503 the next request in the queue.
Lower both together if you would rather bound how long one request can hold
the GPU.

Asking for more than the cap returns a **400** naming the limit. It is never
silently truncated — but note that a truncated response and a model that
stopped on its own both end with `finish_reason: "length"`, so a client
cannot tell them apart.

### Prompt cache

Both engines cache the prompt, and both key the cache on **the token prefix
itself**. There is no per-conversation key to send: `prompt_cache_key`, the
field OpenAI's API accepts for this purpose, is accepted here and deliberately
ignored for exactly that reason — a client cannot name a conversation, because
the prefix already is the name. The front-end's source says so in one line:
"the prefix cache keys on the PREFIX already".

- **Dense:** `HALOGEN_CACHE_ALIGN=2048` aligns the snapshots, and that value is
  what makes a warm answer byte-identical to a cold one. `HALOGEN_CACHE_MB` is
  empty by default, which means **auto** — the engine sizes the cache from the
  available memory at startup. Pin it only with a value large enough to matter:
  a single full-context entry is about 18.4 GB at 262K, so a small explicit
  budget produces a cache that reports itself enabled and never hits.
- **Flash-Next:** the KV stays where it is and each cached conversation costs
  ~111 MiB of O(1) state, counted by `HALOGEN_CACHE_ENTRIES`. The image ships
  **8**, and the Flash-Next unit raises it to 32 so a client that opens
  subagents has headroom. Warm answers are **not** byte-identical here —
  `/health` reports `bitwise_identical_to_cold: false` — because the engine
  snapshots at every request end instead of on an aligned boundary.

### Many agents at once

A coding agent that opens subagents runs several conversations at the same
time, each with its own history. What the subagents share — the system prompt,
the tool definitions — is computed once, because the cache is per-prefix. What
they do not share is not shared, and then two numbers decide whether a turn
takes a second or a minute:

1. **How many positions stay resident across all conversations.** Each request
   reserves its prompt plus its `max_tokens`, so four agents carrying 90,000
   tokens of history with a 65,536-token answer budget reserve about 622,000
   positions between them. The image's default pool holds 524,288: the working
   set does not fit, and the engine has to drop what it cannot keep.
2. **How many conversations the cache can keep resumable at once.** The image
   ships 8 (`HALOGEN_CACHE_ENTRIES`), which is enough for one user and a few
   subagents; the unit raises it to 32 for a fleet.

Both show up in the engine's own log. From a real session, before this was
changed:

```
serve_api: mtp 356 tok | prompt 120102 (30408 cached), prefill 71.20s
serve_api: mtp 478 tok | prompt 123293 (120097 cached), prefill  4.65s
```

Only the shared system prompt (30,408 tokens) was still cached; the
conversation's own 90,000 tokens had to be prefilled again, which is the 71
seconds. The next line is the same conversation one turn later, once its KV
was back in place: 4.65 seconds.

The Flash-Next unit now ships a pool of 1,048,576 positions,
`HALOGEN_KV_POOL_FIT=0`, an arena of 16384 and `HALOGEN_CACHE_ENTRIES=32`.
Measured on the reference host with four agents asking **at the same time**,
each carrying 139,541 tokens of history and `max_tokens: 8192` — 560,000
positions of KV between them, more than the 524,288 the image's pool holds:

| four concurrent agents, 139.5K tokens each | image defaults, pool 524288 | this unit, pool 1048576 |
|---|---|---|
| first turn, all four | 533.8 s | 419.2 s |
| follow-up turn, all four | 229.5 s | **2.2 s** |
| tokens served from cache, per agent | 139,534 for two of four; **21 and 0 for the other two** | **139,534 for all four** |
| prefill of the follow-up, per agent | 0.44 s twice, then 119.53 s and 108.53 s | 0.44 s four times |

So on the defaults two of the four agents pay for their whole history again,
and none does with the larger pool. That is the same failure the real session
above shows at 120K, and it is what the pool is for: 524,288 positions is
about four conversations of 131,072 tokens, which is why this went unnoticed
— four agents at 90,000 tokens are 360,000 positions and fit — and why it
starts to hurt on longer sessions.

The engine prints the cache it armed at startup — `prompt cache ON,
resume-anywhere (8 entries, …)` on the image defaults, `(32 entries, …)` from
this unit, 111 MiB each at the native context. `/cache` counts something
narrower than that allowance: the snapshots currently stored and their
per-entry size, which is why it can report `entries: 1, cap_bytes: 116 MB` on
a machine that is allowed eight — read the startup line, not that field, for
the number of entries.

Four things to know if you tune it:

- **The client has nothing to send.** Keep the prefix stable instead: the
  system prompt, the tool definitions and the order of the messages identical
  across turns, with volatile content (the clock, command output) at the end. A
  subagent whose system prompt differs from its siblings' shares nothing with
  them and starts cold by construction — that is expected, not a bug.
- **The sizes are one budget, not four knobs.** A 1,048,576-position pool fits
  only with the prefill arena at 16384, and the engine enforces the
  relationships (pool at least the context, arena at most 32768).
- **A bigger pool costs memory the model also wants.** 1,048,576 positions is
  ~29.3 GiB against ~14.9 GiB for the default, measured with 72 GB still
  available and the model resident. If you would rather keep the memory,
  786432 (three full-length conversations) also starts and needs no arena
  change.
- **Do not reach for the disk.** `HALOGEN_CACHE_FILE` exists, but only with
  `HALOGEN_CACHE_INPLACE=0`, where each entry copies the whole KV (~26 KiB per
  position, ~6.5 GB at the native context). On this machine the host RAM is the
  same pool the GPU allocates from, so a disk tier gives back memory you
  already have and pays NVMe reads for it. Raising the pool and the entry count
  is what pays.

To go back to the image defaults, delete the six `-e HALOGEN_*` lines from the
`ExecStart` in `~/.config/systemd/user/superfast-flash.service` and run
`systemctl --user daemon-reload && systemctl --user restart superfast-flash`;
the engine then sizes everything itself, including the pool. To keep the fix
but use less memory, set `HALOGEN_KV_POOL_POSITIONS=786432` and drop
`HALOGEN_MAX_TOK` so the arena returns to 32768.

---

## Published artifacts

Everything this project publishes or uses, in one place. This repository is the
entry point: the images it owns are built and pushed by
[`.github/workflows/publish-runtime.yml`](.github/workflows/publish-runtime.yml),
so they are connected to this repository and appear in its Packages section.

| artifact | registry | what it is |
|---|---|---|
| `ghcr.io/graphene-lab/superfast-runtime:llama-rocmfpx-1` | GHCR (ours) | the GGUF runtime: llama.cpp with the ROCmFPX fork, built for gfx1151. Needed by the `gemma`, `deepseek` and orchestrator profiles |
| `ghcr.io/peonist-ai/halogen:0.1.3` | GHCR (upstream) | the engine that serves the dense Qwen3.8-27B profile |
| `ghcr.io/peonist-ai/halogen-flash-server:0.5.6` | GHCR (upstream) | the engine that serves the Flash-Next MoE profile |
| `peonist-ai/halogen-qwen3.8-27b` | Hugging Face | the dense checkpoint and its tokenizer |
| `peonist-ai/halogen-qwen3.8-flash-next` | Hugging Face | the MoE checkpoint and both overlays |
| `kingjones777/Gemma-4-26B-A4B-it-ROCmFP4-GGUF` | Hugging Face | the Gemma-4 weights used by the `gemma` profile |
| `otheru/DeepSeek-V4-Flash-Strix-Halo-GGUF` | Hugging Face | the DeepSeek-V4-Flash weights used by the `deepseek` profile |
| `LiquidAI/LFM2.5-350M-GGUF`, `Nichonauta/LFM2.5-1.2B-Thinking-ToMoE-GGUF` | Hugging Face | the small models used by the orchestrator |

Pull the runtime image the way the profile units expect it:

```bash
podman pull ghcr.io/graphene-lab/superfast-runtime:llama-rocmfpx-1
podman tag  ghcr.io/graphene-lab/superfast-runtime:llama-rocmfpx-1 \
            llama-rocmfpx:7.2.4
```

The pull is about 4.2 GB (the image takes 11.2 GB unpacked). The package is
public, so no login is needed; `deploy/setup-fedora.sh` does this by itself,
and falls back to building from [`runtime/`](runtime/README.md) when the pull
fails. Why the package is not named after the repository: a package pushed by
hand is not connected to the repository, GitHub refuses to change its
visibility through the API in that state, and the workflow's own token cannot
push to it either — a package created by the workflow is connected from the
start. [`runtime/README.md`](runtime/README.md) has the full explanation.

The weights are **not** in the images. They are fetched from Hugging Face by
the downloader in [`deploy/profiles/`](deploy/profiles/README.md), which
checks each file against the SHA-256 published there before using it. The
images contain the engines only.

Nothing in this project is redistributed under a licence that forbids it; the
credits and the licences of every upstream component are in
[`THIRD-PARTY-NOTICES`](THIRD-PARTY-NOTICES.md) and inside the images at
`/licenses`. Model weights keep their own licences, from their authors.

## Requirements

- **AMD Strix Halo (gfx1151)** — Ryzen AI Max+ 395 or equivalent. The build
  refuses every other architecture; this will not run on a discrete GPU, and
  that is deliberate.
- **128 GB unified memory** recommended. The checkpoint is 35.9 GB and is
  mapped, not copied.
- **A ROCm-capable kernel** with `/dev/kfd` and `/dev/dri` accessible, plus
  the two kernel parameters described in
  [step 3](#3-configure-the-machine-for-superfast) for the largest models.
- **A checkpoint and a tokenizer**, mounted at `/models` and `/tokenizer` —
  see [Get the weights](#get-the-weights). The tokenizer directory must be
  flat. The published model repository is already flat; this only matters if
  you point at a HuggingFace *cache* snapshot, whose entries are symlinks into
  a sibling `blobs/` directory and dangle inside a container.

In practice the memory is comfortable: with the Gemma profile loaded, the host
reported about 18 GB in use and 106 GB available; with the much larger
Flash-Next checkpoint resident, 45 GB in use and 78 GB available. Both were
measured. The switch still runs one profile at a time by design, so the big
models never compete. The orchestrator is the one auxiliary that is allowed
to share.

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
- **Unassisted decode is not our strong point** — see the comparison above.
- **Cold time-to-first-token at very long context is slow.** A genuinely cold
  262K prompt is a multi-minute prefill. The prompt cache makes the *second*
  turn fast; it cannot make the first one fast.
- **One default is not byte-identical to the engine's built-in one.** The
  image ships full W4A4 promotion, worth +9% prefill, against about −0.45 pt
  top-1 aggregate (better at deep context, worse in the first ~12%). It does
  not affect the guarantees above: speculation is still exact against serial
  greedy, warm cache still matches cold, batched still matches solo. Roll it
  back with one environment variable; see
  [`docs/FLAGS.md`](docs/FLAGS.md).
- **The comparison table is cross-published, not head-to-head.** We have not
  run the other engines ourselves on our box under matched settings. When we
  do, we will publish whatever it says.

---

## How good are the models: benchmarks and community

The machine can run different model families, and choosing well means
comparing quality, not only speed. The numbers below come from the official
model cards of the two families this machine targets: the dense Qwen3.8-27B
and the Gemma-4-26B-A4B MoE (the variant behind the Gemma ROCmFP4 files).
They are the vendors' own measurements on the instruction-tuned versions.

| benchmark | Qwen3.8-27B (dense) | Gemma-4-26B-A4B (MoE) |
|---|---|---|
| LiveCodeBench v6 | **90.3** | 77.1 |
| GPQA Diamond | **89.2** | 82.3 |
| Humanity's Last Exam | **30.8** | 8.7 |
| SWE-bench Pro | **61.7** | not published |
| Terminal-Bench 2.1 | **73.0** | not published |
| MMLU Pro | not published | 82.6 |
| AIME 2026 | not published | 88.3 |
| active parameters | 27 B (all) | 3.8 B (of 25.2 B) |
| context | 262,144 tokens | 256,000 tokens |
| license | Apache-2.0 | Apache-2.0 |

On the shared benchmarks, Qwen3.8-27B leads on coding and reasoning. Gemma-4-26B-A4B
is an Apache-2.0 MoE built for speed: it activates only a few billion
parameters per token, which is why its publishers report it running "almost
as fast as a 4B model" while carrying far more knowledge. Its family also
reads images, though this profile is text only. The two roles are
complementary: Qwen is the quality-first brain, Gemma the fast, permissive
option.

What the community says follows the same pattern. Third-party write-ups and
developer tests consistently report that Qwen models win on formal benchmarks,
but that the gap narrows in real local usage on constrained hardware, and
Reddit threads sometimes rank models differently from leaderboards. So treat
any single leaderboard as orientation, not as truth. All figures above are
vendor-reported, and no benchmark answers the question that matters most for
your own use: how the model behaves on your documents and in your language.
The "-it" Gemma repository names Italian, but neither vendor publishes
Italian-specific quality numbers, so that claim stays unverified until it is
measured here.

The community reputation of Qwen3.8-27B matches those numbers. Reviews and
headlines describe it as a "frontier-level model that runs on home PC
hardware", with agentic and coding results that rival paid frontier models on
key benchmarks, while staying small enough for a single consumer GPU or an
APU like this one. The same sources add the qualifiers we already stated: the
numbers are the vendor's own, cloud models still win where raw knowledge or
very long reasoning matter, and the model takes its time to think. What is
remarkable is the combination: capabilities that a few years ago needed a
paid cloud API now run locally, privately, with no subscription.

What this means for the machine: the dense and Flash-Next Qwen profiles are
the quality-first defaults, running on the purpose-built engine at high
precision. Gemma-4 and DeepSeek-V4-Flash are the speed-oriented profiles;
their measured numbers are in the table above.

### How they compare with paid models (public numbers)

The four models this machine runs are open-weight models, and their vendors
publish benchmark tables that include paid frontier models as columns. Those
tables are the best available answer to the question this project cares
about: how close is a model you run yourself to a model you rent. **The
numbers in this section are not measured by us.** They come from the vendors'
own model cards and from published comparisons, and they carry the caveats at
the end of the section.

First, the sizes, because these profiles are not the same class of model:

| profile | total parameters | active per token | context | speed here | role |
|---|---|---|---|---|---|
| DeepSeek-V4-Flash | **284B** | 13B | 1M | 11.2 t/s | the largest model the machine runs |
| Qwen3.8-Flash-Next | **125B** model, plus a 51B n-gram drafter table (not weights) | 6B | 262K | 37.7–46.4 t/s | the largest Qwen profile, and the fastest of the large ones |
| Qwen3.8-27B dense | **27B** | 27B (all) | 262K | 21.0–26.1 t/s | the precision-first profile |
| Gemma-4-26B-A4B | 25.2B | 3.8B | 256K | 57.3–57.6 t/s | the small, fast profile |

*The context column is what the model supports. The window this project
actually serves is in
[What each profile ships](#what-each-profile-ships-context-tokens-tools) — for
DeepSeek it is 512K rather than 1M, and the reason is measured.*

So the Qwen model compared most often, the dense 27B, is the **smaller** of
the two Qwen profiles this machine runs: beside it there is Flash-Next, a
125B-parameter mixture-of-experts that is both larger and, on Qwen's own
card, ahead on most rows. Both are compared below.

**Read the model names carefully.** These families have similar names, and
the numbers below are for the exact models this machine runs:

| what we run here | what it is | what it is **not** |
|---|---|---|
| Qwen3.8-27B dense (~6.3 bpw) | Qwen3.8-27B, dense, 27B parameters, 262K context | not Qwen3.6-27B, not Qwen3.7-Plus |
| Qwen3.8-Flash-Next w4b | Qwen3.8-Flash-Next MoE, 125B total / 6B active, 512 experts, 262K context | not Qwen3-Flash, not another "Flash" |
| DeepSeek-V4-Flash 2.58 bpw | DeepSeek-V4-Flash, 284B total / 13B active, 1M context | not DeepSeek-V3.2, not DeepSeek-V4-Pro |
| Gemma-4-26B-A4B ROCmFP4 | Gemma 4 26B A4B MoE, 25.2B total / 3.8B active, 128 experts (8 active), 256K context | not Gemma 3 27B, not Gemma 4 31B |

#### Qwen3.8-27B (the dense profile, the smaller of the two Qwen models)

Collected from Artificial Analysis indices, vendor reports and BrainBench.

| benchmark | Qwen3.8-27B (local) | paid model in the same range | note |
|---|---|---|---|
| Artificial Analysis Intelligence Index | **52** | GPT-5.6 Luna (52), DeepSeek V4 Flash | same band |
| Artificial Analysis Agentic Index | **51** | GPT-5.6 Terra, Claude Opus 4.8 | Qwen3.8-27B is ahead of both |
| SWE-bench Pro (agentic coding) | **61.7** | Claude Opus 4.6 Max (53.4) | ahead of Anthropic's model by 8.3 points |
| BrainBench-llama (accuracy) | **80.0%** (IQ3_XXS) / 78.0% (Q4_K_S) | Claude Opus 4.6 with thinking (80.3%) | almost level with the top Claude |
| AIME 2026 (mathematics) | **29/30 (96.7%)** | Claude Opus 4.6 (96.7%) | level; GPT-5.4 xhigh scores higher (99.2%) |
| LiveCodeBench v6 | **90.3** | — | self-reported by Alibaba |

Qwen's own model card puts the same model next to Claude Opus 4.6 Max, which
is one of the paid frontier models, on the same harness:

| benchmark | Qwen3.8-27B | Claude Opus 4.6 Max |
|---|---|---|
| Terminal-Bench 2.1 | 73.0 | **78.2** |
| SWE-bench Pro | **61.7** | 53.4 |
| DeepSWE 1.1 | **42.2** | not published |
| QwenSWEBench (in-house) | **79.0** | 63.8 |
| CoWorkBench (long office work) | **70.7** | 68.2 |
| IFBench (instruction following) | **79.5** | 62.5 |
| GPQA Diamond | 89.2 | **91.3** |
| HLE (hard multidisciplinary) | 30.8 | **40.0** |
| LiveCodeBench v6 | **90.3** | 88.8 |

The same card also lists the larger Qwen profile this machine runs (Flash-Next,
125B total), and there Flash-Next is ahead of the 27B on most rows. The next
subsection covers it.

**Where it is strong.** Agentic coding and instruction following: it is ahead
of Claude Opus 4.6 Max on SWE-bench Pro, DeepSWE 1.1, CoWorkBench and
IFBench, and it answers faster than the paid models compared here (about
190 ms to the first token, against about 1.4 s for GPT-5.6 Luna).

**Where it is weaker.** Terminal work and the hardest knowledge questions:
Claude Opus 4.6 Max is ahead on Terminal-Bench 2.1, GPQA Diamond and HLE.
Most of the figures are also **self-reported by Alibaba**, and full
independent evaluations are still missing. The model is slower overall and
more verbose: it generates many more reasoning tokens than the paid models
here, which shows in everyday use. On BrainBench it scores 80.0%, clearly
above GPT-5.4 (74.0%) and GPT-4o (39.7%), but that is one benchmark on one
quantized build.

#### Qwen3.8-Flash-Next (the largest Qwen profile, and the fastest of the large ones)

This is the **larger** of the two Qwen models this machine runs: 125B
parameters in total against 27B for the dense profile, with 6B active per
token thanks to the mixture-of-experts design, which is also why it is much
faster here (37.7–46.4 t/s against 21.0–26.1). The same vendor card compares
it against Claude Opus 4.6 Max, and on several rows it is the strongest model
in that table:

| benchmark | Qwen3.8-Flash-Next | Claude Opus 4.6 Max |
|---|---|---|
| SWE-bench Pro (agentic coding) | **62.5** | 53.4 |
| SWE-bench Multilingual | **81.0** | 77.5 |
| DeepSWE 1.1 | **58.7** | not published |
| NL2Repo-Bench (repo-level code) | **48.1** | 47.6 |
| CoWorkBench (long office work) | **73.9** | 68.2 |
| JobBench (professional tasks) | **55.7** | 36.6 |
| Toolathlon Verified (tool use) | **73.5** | not published |
| IFBench (instruction following) | **81.3** | 62.5 |
| GPQA Diamond | **91.7** | 91.3 |
| HLE (hard multidisciplinary) | 35.9 | **40.0** |
| LiveCodeBench v6 | **91.9** | 88.8 |

In short: on this card the fast profile beats the paid frontier model on
almost every coding, agent and instruction row, and stays close on the
hardest knowledge rows. Remember that this is the profile that runs at
37.7–46.4 tokens per second on this machine, three times the speed of the
dense profile.

#### DeepSeek-V4-Flash (the 284B profile)

DeepSeek's card reports the paid frontier models as comparison columns (their
scores, as reported by DeepSeek). V4-Flash in its top reasoning mode:

| benchmark | DeepSeek-V4-Flash (Max) | Claude Opus 4.6 Max | GPT-5.4 xHigh | Gemini-3.1-Pro High |
|---|---|---|---|---|
| MMLU-Pro | 86.2 | 89.1 | 87.5 | **91.0** |
| GPQA Diamond | 88.1 | 91.3 | 93.0 | **94.3** |
| HLE | 34.8 | 40.0 | 39.8 | **44.4** |
| LiveCodeBench | 91.6 | 88.8 | — | **91.7** |
| HMMT 2026 Feb (mathematics) | 94.8 | 96.2 | **97.7** | 94.7 |
| IMOAnswerBench | 88.4 | 75.3 | **91.4** | 81.0 |
| Terminal Bench 2.0 | 56.9 | 65.4 | **75.1** | 68.5 |
| SWE Verified (resolved) | 79.0 | **80.8** | — | 80.6 |
| SWE Pro (resolved) | 52.6 | 57.3 | **57.7** | 54.2 |
| BrowseComp | 73.2 | 83.7 | 82.7 | **85.9** |
| Toolathlon | 47.8 | 47.2 | **54.6** | 48.8 |
| MRCR 1M (long context) | 78.7 | **92.9** | — | 76.3 |

This is the profile to be honest about: it is a 284B-parameter model that
does not reach the paid frontier on knowledge, browsing or terminal work, and
on this machine it is also the slowest of the four (11.2 t/s). It is worth
running for what it is good at — long context, mathematics, and a 1M-token
window — and it is remarkable that a model of this size fits and runs on an
APU at all.

#### Gemma-4-26B-A4B (the small fast profile)

Google publishes no comparison with paid models for this one, so the paid
values below come from the other tables in this section (same benchmarks,
their published scores). Gemma 4 26B A4B, from Google's card:

| benchmark | Gemma 4 26B A4B | Claude Opus 4.6 Max | GPT-5.4 xHigh | Gemini-3.1-Pro High |
|---|---|---|---|---|
| MMLU-Pro | 82.6 | 89.1 | 87.5 | **91.0** |
| GPQA Diamond | 82.3 | 91.3 | 93.0 | **94.3** |
| LiveCodeBench v6 | 77.1 | 88.8 | — | **91.7** |
| AIME 2026 (no tools) | 88.3 | *these tables report HMMT 2026 instead: 96.2* | *97.7* | *94.7* |
| HLE (no tools) | 8.7 | 40.0 | 39.8 | **44.4** |
| MRCR v2, 8 needles, 128K | 44.1 | not published | not published | not published |

The AIME row is not a like-for-like comparison: Gemma's card reports AIME
2026, the paid columns in the other tables report HMMT 2026. Both are
competition mathematics, not the same exam, so read that row as an
indication only.

It is the smallest and fastest profile (57 t/s here), and it is clearly a
step below the paid frontier on the hardest benchmarks, while staying useful
for everyday work. It is also the only profile of the four whose model family
reads images; the vision part is not enabled in our profile.

#### What to keep in mind

1. **These are vendor-reported numbers**, and each vendor evaluates its own
   model. The paid-model columns in the Qwen tables were produced by Qwen;
   the paid-model columns in the DeepSeek table are DeepSeek's report of
   other vendors' published scores. Independent evaluation is thinner than
   the tables suggest.
2. **Harnesses differ.** Qwen states that all rows were measured with the
   Claude Code harness, except the Claude Opus 4.6 Max row, where the vendor's
   own officially published score is used. Small differences between two
   models mean little; the pattern across many rows means more.
3. **Our builds are quantized; the benchmarks are not.** These cards measure
   the full-precision models (FP8 or BF16). This machine runs 4-bit-class
   quantizations (dense ~6.3 bpw, Flash-Next w4b, DeepSeek 2.58 bpw, Gemma
   ROCmFP4 Q4_0), so the quality here is close to the tables, not identical.
   The measured effect on our own machine: the Flash-Next quality overlay is
   worth several percent of perplexity and we always mount it.
4. **Quality is the model's; the speed is the machine's.** A 27B dense model
   at 21 tokens per second and a 125B MoE at 38–46 tokens per second are the
   numbers this project contributes. Measure yours with
   [`tools/quick-bench.py`](tools/quick-bench.py).
5. **One sentence:** two of the four profiles match or beat the paid frontier
   model on most coding and agent tasks in these tables (the dense 27B and
   the Flash-Next MoE), one is strong in long context and mathematics
   (DeepSeek-V4-Flash), and one is a fast, small and useful model (Gemma 4)
   — all of them running locally, with no subscription and no data leaving
   the machine.

---

### Defaults we ship, and why (in plain words)

Thinking is not free, and more of it is not automatically better. A model
that reasons for a long time can spend its whole budget "thinking" and never
get around to answering. That is not a hypothetical case: Qwen3.8-27B, when a
request does not say otherwise, uses the vendor's highest reasoning setting,
and that default is the documented cause of long thinking loops and empty
replies (upstream issue QwenLM/Qwen3.8#216; in one measured case the model
spent over twenty-two thousand thinking tokens to produce three thousand
tokens of answer, roughly seven times the useful work).

The defaults shipped here are therefore deliberate:

- **Chat and coding on Qwen3.8-27B:** reasoning effort `low` — the setting this
  project's measurements send per request, and what the recommended client
  configuration sends too. Use `medium` for genuinely hard problems, and turn
  thinking off for trivial requests, but always leave an answer budget large
  enough that thinking cannot eat it.
- **DeepSeek-V4-Flash:** the vendor recommends `temperature 1.0`,
  `top_p 0.95` and maximum reasoning effort for code agents. Be aware of what
  the machine does and does not do here: the profile passes no sampling flags,
  so `/props` reports only `n_ctx` and the client decides (see
  [Recommended client configuration](#recommended-client-configuration-qwen-code-or-any-agentic-client)).
  Its thinking phase ignores sampling settings anyway, so lowering the
  temperature does not calm the reasoning loop. It also needs a large answer
  budget: with 192 and with 512 tokens, every request we measured spent the
  whole budget on reasoning.
- **Gemma-4:** it thinks a lot, so give it a generous token budget. With a
  two-hundred-token limit its answers came back empty in our tests, which is
  why its measured row uses 512 tokens.
- **The orchestrator:** short answers only. It exists to make a fast decision
  (a 24-token routing answer took about 130 ms), so do not give it a long
  thinking budget.
- **Context windows** are set to the largest value that stays stable on this
  machine: 262,144 tokens for dense, flash and Gemma-4, and 524,288 for
  DeepSeek — the measured table is in
  [What each profile ships](#what-each-profile-ships-context-tokens-tools). A
  bigger window is not free: the KV cache grows with it and shares the same
  memory pool as the model.

The rule in one sentence: give a model just enough thinking for the task, an
answer budget large enough that thinking cannot consume it, and the sampling
values its vendor recommends — sent by the client, since that is where they
belong — then measure, as we did.

## The orchestrator: a small, fast model that hands work to the right specialist

This profile does not appear in the comparison table, because it does not
compete with the big models. It has a different job.

An orchestrator decides what has to be done and who should do it: it reads a
request, splits it into parts, sends each part to the right specialist model
or tool, and assembles the answers. In the literature the same idea appears
under several names, used almost interchangeably: orchestrator, router,
dispatcher, supervisor, planner, controller, and Anthropic's "lead agent" in
its orchestrator-worker design. A lighter variant is the "semantic router",
which decides with vector similarity instead of a full model call.

The point of giving this job to a *small* model is efficiency, not
intelligence. Routing, classifying, choosing a tool and planning a short
sequence of steps are simple tasks. A 350M-to-1.5B model does them in
milliseconds. Doing them with a big model means paying the big model's memory
bandwidth for work that does not need it. The numbers on this machine make
that clear: the dense 27B profile reads about 23.5 GB for every token it
generates, while a 1.2B model at 4-bit reads under 1 GB. The orchestrator can
therefore run all the time, answer immediately, and cost the specialist model
barely 1–2% of its bandwidth when both are resident.

The pattern is old and familiar: a conductor does not play the violin better
than the musicians; the work is deciding who plays when, and keeping the
piece together. The same shape appears in offices, where the person
coordinating the work produces less than the specialists but decides who does
what.

A second job for the orchestrator is reactive control: home automation, IoT
devices and voice front-ends. In these settings almost nothing needs
reasoning. A speech-to-text program turns "turn on the kitchen light" into
text, and something has to map that text to a switch, a scene or a short
series of steps. Most of those procedures are semi-deterministic — a flow
diagram with a few branches, not a problem to solve from scratch — and what
matters is latency and availability, not depth. A small model does the mapping
in milliseconds, is always resident, and never competes with a specialist
model that is busy thinking elsewhere. Using a large model for this work is
slow and expensive, like using a missile to drive a nail: it works, but with
far more power than the job needs.

Two boundaries keep the design honest. First, where a procedure is fully
deterministic, ordinary code is cheaper and faster than any model: the
orchestrator is useful in the unclear cases — understanding what the user
meant, filling in a missing detail, choosing between a few known flows — and
as soon as the flow is known, plain logic should run it. The strongest designs
put rules first and the model behind them: a keyword table answers most
commands in well under a millisecond, and the model handles the rest. Second,
actions that matter — locks, alarms, appliances — need guardrails: the model
should choose from a list of allowed commands instead of producing free text,
anything irreversible should ask for confirmation, and a deterministic
fallback should keep working when the model is unavailable.

Beyond routing and reactive control, the same role covers adjacent jobs:
choosing the model tier for a request; rewriting or expanding a search query
before retrieval; summarizing a long conversation before handing it to the
specialist; running cheap guardrails such as moderation, personal-data checks
or prompt-injection detection in front of the expensive model; making a
first-pass judgement of the specialist's answer; and starting or coordinating
subagents. All of them are short, cheap decisions, where a large model's
latency is pure waste.

This is how production systems are built, not an invention of this project.
Anthropic describes an orchestrator-worker design in which a lead agent plans,
starts three to five specialized subagents in parallel, and combines their
findings. Frameworks encode the same split: LangGraph's supervisor pattern,
vLLM's semantic router, the aurelio-labs semantic router, and the
model-router/cascade ideas (RouteLLM, FrugalGPT) that send each request to
the cheapest model that can handle it. Vendors of commercial routers claim
70–90% cost reductions and 2–3× faster median responses from this split;
those are marketing numbers, but the mechanism is real, and it is why the
pattern is everywhere in agentic stacks.

On this machine the plan is concrete, and it is measured. A small Liquid
LFM2.5 model becomes a resident orchestrator on its own port, while the dense,
Flash-Next or DeepSeek profile stays on the main endpoint for the work that
needs a big model. Clients keep talking to the same address; the orchestrator
decides whether the request is simple enough to answer itself or worth waking
the specialist.

| small model | decode (llama-bench tg128) | end-to-end generation | prefill (pp512) | short routing answer |
|---|---|---|---|---|
| LFM2.5-350M Q4_K_M | **465 t/s** | — | 21,280 t/s | — |
| LFM2.5-1.2B Thinking Q4_K_M | **216 t/s** | **204 t/s** | 8,182 t/s | **0.130 s** for 24 tokens |

Those numbers answer the question the section opened with: a small local model
comfortably exceeds two hundred tokens per second on this machine, and a
routing decision comes back in about a tenth of a second, which is the
latency a voice or home-automation front-end needs. Tuning was checked rather
than assumed: on the 1.2B model, thread counts of 8 and 16 and alternative
batch sizes all landed within 0.2% of the defaults, so the defaults are what
is shipped. Both files were verified byte-for-byte against the official
Hugging Face SHA-256 sums before use.

Co-residency was measured, not assumed. With the small model resident but
idle, the large model's throughput did not change beyond noise (prose 56.5
against 55.6 t/s, code 57.6 against 57.6). While the orchestrator was actively
generating in parallel, prose dipped by at most about three percent (53.9
t/s) and code was unaffected. That is the real price of keeping a dispatcher
ready: almost nothing while it waits, a few percent while it works.

The orchestrator has its own systemd unit and is toggled with
`superfast-switch orchestrator on|off`, so enabling it never disturbs the
active profile. Its numbers stay out of the comparison table, which is about
the specialist models.

---

## Choose a model profile

The machine runs **one model profile at a time**, and every profile serves the
same OpenAI-compatible endpoint on port 8731. Clients — scripts, apps,
AgentBridge — never change their configuration when you switch: only the
model behind the endpoint changes. Stopping one profile releases its memory
before the next one loads, so the dense 27B, the Flash-Next MoE and any future
profile do not compete for resources.

The setup script ([`deploy/setup-fedora.sh`](deploy/setup-fedora.sh), phases
8–10) installs everything: the profile units, the switch itself into
`~/.local/bin/superfast-switch`, the TUI, the API-key gateway and the GNOME
panel. Which profiles it prepares depends on `PROFILES` (see
[step 3](#3-configure-the-machine-for-superfast)); the units live in
[`deploy/profiles/`](deploy/profiles/README.md) and stay stopped until the
switch starts them. If you only want the switch on a machine that is already
configured:

```bash
cp tools/superfast-switch.sh ~/.local/bin/superfast-switch
chmod +x ~/.local/bin/superfast-switch
```

Use the switch on the machine:

```bash
superfast-switch status          # what is running now
superfast-switch list            # available profiles
superfast-switch use dense       # Qwen3.8-27B (halogen engine)
superfast-switch use flash       # Qwen3.8-Flash-Next MoE
superfast-switch use gemma       # Gemma-4-26B-A4B ROCmFP4
superfast-switch use deepseek    # DeepSeek-V4-Flash ROCmFPX
superfast-switch stop            # stop everything
superfast-switch api-key on      # require the API key from the LAN (:8741)
superfast-switch api-key status  # is the gateway on, is a key set
```

The tool stops the current profile, starts the requested one and waits until
`/health` answers with **200**, so when `use` returns, the endpoint is ready.
This matters for the GGUF profiles: a llama.cpp server binds its port at once
and answers 503 while it loads, so the switch waits for the load to finish (a
minute or two for the large checkpoints) instead of reporting early. A profile
also refuses to start until its weights are complete, and the `deepseek`
profile additionally needs the kernel parameters described in
[step 3](#3-configure-the-machine-for-superfast): until you apply them, the
switch refuses to start it and says so. The measured numbers behind each
profile live in [Performance](#performance) and are updated as new models are
validated on this machine.

### What each profile ships: context, tokens, tools

The context window is the reason this machine runs one model at a time (see
[A note on names](#a-note-on-names)), so every profile is configured at the
largest window its model supports on this hardware. Measured on the
reference machine:

| profile | context | memory in use while serving | notes |
|---|---|---|---|
| Qwen3.8-27B dense | 262,144 | ~36 GB | the engine's native maximum, one slot holds the whole window |
| Qwen3.8-Flash-Next | 262,144 | ~45 GB | native maximum, and the fastest of the large profiles |
| Gemma-4-26B-A4B | 262,144 | ~23 GB | its native 256K; its sliding-window attention keeps the KV cache small |
| DeepSeek-V4-Flash | 524,288 | ~102 GB | half of the model's native 1M, and the largest window that stays stable here — see below |

Three properties that matter when a program uses this machine as its model:

- **The KV cache is shared by the four server slots** (`kv_unified`), so one
  session can use the whole window; four sessions share the same window
  instead of getting one each.
- **Tool calling works on every profile.** The GGUF profiles run with
  `--jinja`, so the model's own chat template handles tools. Verified on
  Gemma-4: asked for a tool call, and the answer was a proper `tool_calls`
  reply with the right arguments (`get_time({"city":"Rome"})`). On
  DeepSeek-V4-Flash the flag is accepted and the template loads; a
  1024-token tool request was spent entirely on reasoning, which is the trap
  described in the next point, so give it a large budget.
- **Give the thinking profiles room.** Gemma-4 and DeepSeek-V4-Flash spend
  their whole budget on reasoning when the budget is small — measured at 192,
  512 and 1024 tokens — so a client should send a large `max_tokens` with
  them, or the answer comes back empty with `finish_reason: "length"`.

Why DeepSeek ships 512K and not its full 1M: both were measured. At 1M the
machine has about 7 GB of free memory left, and long generations then stall —
an 8192-token request stopped after 5668 tokens and burned 14 CPU cores for 25
minutes without producing anything, observed twice. At 512K the same profile
uses ~102 GB, keeps ~21 GB free, and a 1024-token generation finishes in 101
seconds at 10.1 t/s. If this machine is to run nothing else, `-c 1048576` in
`~/.config/systemd/user/deepseek.service` restores the full window.

### Recommended client configuration (Qwen Code, or any agentic client)

A coding agent sends a large system prompt, the tool definitions and the files
it is working on, and then asks for long answers. Any OpenAI-compatible client
works, and the settings that matter are these — they come from the
measurements above, not from taste. Every profile binds port 8731 to loopback,
so from another machine the base URL is the API-key gateway,
`http://<machine-ip>:8741/v1`, with `Authorization: Bearer <key>`; the setup
script opens 8741 in the firewall and keeps 8731 closed. Local tools on the
machine itself use `http://127.0.0.1:8731/v1` with no key.

| setting | what to do |
|---|---|
| model name | read it from `/health` (`"model"`). It changes with the active profile: `halogen-qwen3.8-flash-next`, `halogen-qwen3.8-27b`, `gemma-4-26b-a4b`, `deepseek-v4-flash` |
| context window | set it to what the profile serves — 262,144 for the three, 524,288 for DeepSeek. Never larger: the server refuses, because the window is allocated memory, not a preference |
| answer budget | **16,384 to 32,768 for coding**, not 8,192. The budget covers the reasoning tokens as well, so a small one truncates a turn that thinks and then writes a file |
| sampling | on the Qwen profiles leave it alone: the engine's default is greedy, which is what a coding agent wants, and it says so in `/health` ("greedy at temperature 0 (the default)"). On the Gemma and DeepSeek profiles the server declares **no** sampling default — `/props` reports only `n_ctx` — so the client has to choose (greedy is what we measured with) |
| reasoning effort | on the Qwen profiles send `reasoning_effort` per request (`low` for chat and code, `medium` for hard problems): the vendor default over-thinks and that is the documented cause of long thinking loops. The GGUF profiles ignore the field |

Two limits that only show up in long agentic sessions:

- **The client caps a streamed answer at 15 minutes by default** (Qwen Code:
  `QWEN_STREAM_MAX_LIFETIME_MS`). Converted to tokens on this hardware, 15
  minutes is about 19,000 tokens on dense, 41,000 on flash and 10,000 on
  DeepSeek. Either keep the answer budget inside those numbers or raise that
  limit, otherwise a long turn is cut mid-answer even though the server is
  fine.
- **Keep the prefix stable, especially with subagents.** Every turn re-sends
  the conversation, and the server reuses what it computed before: the prompt
  cache is keyed on the prompt itself, so there is no cache key to send. It
  only works while the beginning of the prompt does not change — keep the
  system prompt and the tool definitions identical across turns, and put
  volatile content (the clock, command output) at the end. Two consequences
  when an agent opens subagents: each subagent carries its own history, so
  only what it shares with its siblings is free, and the machine keeps warm
  only what fits its KV pool while it decodes at most as many conversations at
  once as the profile has slots (4 on Flash-Next) — see
  [Many agents at once](#many-agents-at-once). Qwen Code shows the cache work
  in `/stats`.

A working entry for Qwen Code (`~/.qwen/settings.json`), the flash profile,
tuned for coding:

```json
{
  "id": "halogen-qwen3.8-flash-next",
  "name": "[SUPERFAST] flash profile (MoE 125B) - coding",
  "baseUrl": "http://<machine-ip>:8741/v1",
  "envKey": "SUPERFAST_API_KEY",
  "generationConfig": {
    "timeout": 900000,
    "streamIdleTimeoutMs": 600000,
    "maxRetries": 1,
    "contextWindowSize": 262144,
    "extra_body": { "reasoning_effort": "low" },
    "samplingParams": { "max_tokens": 32768 }
  }
}
```

Repeat it once per profile, changing `id`, `name` and `contextWindowSize`
(524,288 for DeepSeek), and dropping `extra_body` on Gemma and DeepSeek, which
ignore it. `envKey` names an environment variable, not the key itself: point it
at the gateway key, read with `superfast-switch api-key show`, and set it with
`setx SUPERFAST_API_KEY <key>` on Windows or `export SUPERFAST_API_KEY=<key>`
elsewhere. When the client runs on the machine itself, use
`http://127.0.0.1:8731/v1` and any placeholder value, because loopback needs no
key. Qwen Code re-reads `modelProviders` edits without a restart.

The stream limit is not a per-provider field, so it goes in the environment of
whatever starts the client (on Windows, `setx`, then a new terminal):

```bash
export QWEN_STREAM_MAX_LIFETIME_MS=1800000    # 30 minutes
```

For another client the rules are the same: point it at
`http://<machine-ip>:8741/v1` with the `Authorization: Bearer <key>` header
(or `http://127.0.0.1:8731/v1` on the machine itself, no key), use the model
name from `/health`, send tools enabled and a large output budget, keep the
context at what the server allocates, and do not send sampling parameters the
server already applies.

The auxiliary orchestrator is toggled separately, because it runs *alongside*
the active profile instead of replacing it:

```bash
superfast-switch orchestrator on      # start the small router model (:8732)
superfast-switch orchestrator off     # stop it
superfast-switch orchestrator status  # is it running?
```

It is off by default and costs the specialist model one to two percent of
memory bandwidth when enabled. Its two model files live in `~/small-models`
(see the table in [Get the weights](#get-the-weights)); the setup script
installs its systemd unit when those files are present, and the unit stays
stopped until you switch it on.

The same controls exist in two friendlier forms. On the desktop, a small GNOME
panel menu (`gnome-shell-extension/`) shows what is serving and lets you switch
model, toggle the orchestrator, and turn the API key on or off (set, copy or
clear it) with a click. In a terminal — including over SSH — `superfast-tui`
offers a minimal menu plus simple commands (`status`, `use`, `orchestrator`,
`api-key`, `help`), and `superfast-switch` is the same set for scripts.

### Locking it down (API key)

Networking is off by default and switched on with a key. Every profile binds
port 8731 to **loopback** on the machine, so nothing on your network can reach
a model directly. The only way in from the network is the gateway on port
8741, and it answers a request only when it carries the key. Without the key
there is no access at all — this is not "open, but also has a key".

Turn it on and read the key (this also starts the gateway):

```bash
superfast-switch api-key on        # generates a key if none exists, starts the gateway
superfast-switch api-key show      # print the key, to paste into a client
```

Clients then send one of these, and a request without it is refused with 401:

```
Authorization: Bearer <key>
X-API-Key: <key>
```

The commands live in `superfast-switch` and are mirrored in `superfast-tui`
and in the GNOME menu:

| command | what it does |
|---|---|
| `superfast-switch api-key status` | is the key set, and is the gateway running |
| `superfast-switch api-key on` | start the gateway; the key is required from now on |
| `superfast-switch api-key off` | stop the gateway: **no access from the network at all** |
| `superfast-switch api-key show` | print the key |
| `superfast-switch api-key set [key]` | set the given key, or generate one, and turn the gateway on |
| `superfast-switch api-key clear` | remove the key and stop the gateway |

"Off" means remote access is off, not "open without a key": with the gateway
stopped, only the machine itself can reach a model. The key lives at
`~/.config/superfast/api.key` (mode 600) and the gateway is
`superfast-gateway.service`. The setup script opens 8741 in the firewall and
keeps 8731 closed; if you ever open 8731 yourself, you have exposed the models
with no key again.

**Roadmap: other model families.** A second runtime is already in use —
llama.cpp with the ROCmFPX fork, which serves GGUF models with AMD's FP4
tensor types. One such runtime can host several profiles, because a profile
is only a weight folder plus a systemd unit. Gemma-4-26B-A4B and
DeepSeek-V4-Flash are the two families validated on it so far. Nothing enters
the switch before it is measured on this exact machine and its numbers are
published here.

---

## Make it your personal assistant with AgentBridge

The machine you built is a fast, private LLM server. The last step turns it
into a personal assistant you can talk to.

**What AgentBridge is, in plain words.** AgentBridge is a program that runs
your own AI agents on a normal computer. You chat with it in a terminal, and
it can do real work for you: reading and summarizing your documents, drafting
files, working with spreadsheets, browsing the web, sending email. Everything
runs on your own hardware and stays private. AgentBridge is self-hosted and
open source, and it follows a "bring your own model" approach: it uses
whatever LLM you point it at — which is what the SUPERFAST server provides.

**Where it runs.** AgentBridge does not have to run on the Fedora machine.
The Fedora machine is the brain: an OpenAI-compatible API. Install AgentBridge
on your everyday computer (Windows, Linux or macOS), add the SUPERFAST server
as its model provider, and the assistant works locally on your computer while
asking the server for intelligence. From another machine the provider points
at port 8741 and sends the API key; on the machine itself, port 8731 needs no
key.

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
provider pointing at `http://<your-fedora-host>:8741`, and paste the API key
(read it on the machine with `superfast-switch api-key show`). On the machine
itself the provider can point at `http://127.0.0.1:8731` with no key.

A worked example, measured from the desktop PC to the machine over the direct
cable (the health check answered in about six milliseconds):

```bash
# on the machine: choose a profile and read the model name it reports
superfast-switch use gemma
curl -s localhost:8731/health         # -> "model":"gemma-4-26b-a4b"
```

From any computer on the network, the OpenAI-compatible endpoint is the
key-protected gateway, `http://<machine-ip>:8741`, and the model name is
whatever `/health` reports — `gemma-4-26b-a4b`, `deepseek-v4-flash` or the
Qwen name, depending on the active profile. One caution learned the hard way:
give the model a generous `max_tokens`. In our own test, a 256-token budget
was consumed entirely by Gemma's reasoning phase and the answer came back
empty; 1,024 tokens produced a normal reply. The gateway requires the key
(`Authorization: Bearer <key>`); on the machine itself use
`http://127.0.0.1:8731` with no key.

The official repository is
[github.com/Graphene-Lab/AgentBridge](https://github.com/Graphene-Lab/AgentBridge/):
there you will find the releases, the full manual and the tools the agents can
use.

---

## Why this matters

A few years ago, this level of quality required a paid API and sent your
questions to someone else's datacenter. A model that rivals paid frontier
services while running entirely on a machine you own changes the economics:
no subscription, no usage caps, and nothing leaves your home. That is the
deeper point of this project: models this good are what make independence
possible. It is also why this field moves so quickly — every user who stops
renting intelligence and runs it locally is a cost that the large datacenter
build-outs find harder to justify.

---

## License

Free for any use, including commercial. Unmodified redistribution permitted.
Benchmark publication expressly permitted. See [`LICENSE`](LICENSE.md) and
[`THIRD-PARTY-NOTICES`](THIRD-PARTY-NOTICES.md), both also at `/licenses`
inside the image.

**Model weights are not included and are not covered** by that license. They
are obtained separately and are licensed by their original authors.
