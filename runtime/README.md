# runtime — turnkey llama.cpp ROCmFPX for Strix Halo

This directory holds everything needed to obtain the runtime that serves the
GGUF profiles (Gemma-4 ROCmFP4, DeepSeek-V4-Flash ROCmFPX) on the Ryzen AI
Max+ 395. It exists so that users of the guide do not have to repeat the
"dirty work" — compiling llama.cpp against ROCm for gfx1151 — from scratch.

## What you get

- `Dockerfile` — the reproducible build of `llama-server` for gfx1151.
- `NOTICE.md` — credits and licenses of every upstream component
  (everything is MIT lineage except AMD's ROCm libraries; see the notice).
- The **prebuilt image**, published to GHCR by this repository's workflow
  ([`.github/workflows/publish-runtime.yml`](../.github/workflows/publish-runtime.yml)):

  ```bash
  podman pull ghcr.io/graphene-lab/superfast-runtime:llama-rocmfpx-1
  podman tag  ghcr.io/graphene-lab/superfast-runtime:llama-rocmfpx-1 \
              llama-rocmfpx:7.2.4     # the name the profile units use
  ```

  The package is called `superfast-runtime` and not the repository's own name
  for a reason worth knowing: a package pushed by hand from a local machine is
  not connected to the repository, GitHub then refuses to change its
  visibility through the API, and the workflow's own token cannot push to it
  either (`denied: permission_denied: read_package`). A package created by a
  workflow of this repository is connected from the start.
  `deploy/setup-fedora.sh` does the pull-and-tag above, and builds the image
  locally if no published copy can be pulled.

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
