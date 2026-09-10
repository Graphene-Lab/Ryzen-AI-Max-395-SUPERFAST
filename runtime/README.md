# runtime — turnkey llama.cpp ROCmFPX for Strix Halo

This directory holds everything needed to obtain the runtime that serves the
GGUF profiles (Gemma-4 ROCmFP4, DeepSeek-V4-Flash ROCmFPX) on the Ryzen AI
Max+ 395. It exists so that users of the guide do not have to repeat the
"dirty work" — compiling llama.cpp against ROCm for gfx1151 — from scratch.

## What you get

- `Dockerfile` — the reproducible build of `llama-server` for gfx1151.
- `NOTICE.md` — credits and licenses of every upstream component
  (everything is MIT lineage except AMD's ROCm libraries; see the notice).
- The **prebuilt image**, published to GHCR on 2026-09-10:

  ```bash
  podman pull ghcr.io/graphene-lab/ryzen-ai-max-395-superfast:llama-rocmfpx-1
  podman tag  ghcr.io/graphene-lab/ryzen-ai-max-395-superfast:llama-rocmfpx-1 \
              llama-rocmfpx:7.2.4     # the name the profile units use
  ```

  `deploy/setup-fedora.sh` does exactly this, and builds the image locally if
  the pull fails (for example when the package is still private: GHCR makes a
  new package private, and its visibility is changed in the package settings
  on GitHub).

## Build it yourself (one time)

```bash
cd runtime
podman build -t llama-rocmfpx:7.2.4 .
```

The build takes a while (it downloads the ROCm dev toolchain and compiles
for gfx1151) but happens only once per machine.

## What is NOT here

Model weights. GGUF files (Gemma, DeepSeek and their drafters) are large and
carry their own licenses, so they are downloaded from Hugging Face during
setup, never stored or distributed from this repository.

## Use

Once the image and the weights exist, activate the profiles with the model
switch (`superfast-switch use gemma`, `superfast-switch use deepseek`), which
starts the matching systemd unit. Measured numbers for every profile are in
the main README.
