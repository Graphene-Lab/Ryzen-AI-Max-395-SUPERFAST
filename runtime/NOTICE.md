# Credits and licenses

This project publishes, for the Ryzen AI Max+ 395 (Strix Halo, gfx1151)
machine, containers and binaries built from the upstream projects below.
All credits stay with their authors. The MIT license requires that this
notice accompany any distribution of the built software, so it is shipped
inside the runtime image at `/NOTICE.md` and in this repository.

| Component | Upstream | License |
|---|---|---|
| llama.cpp (`llama-server`, …) | ggml-org/llama.cpp | MIT — Copyright (c) 2023-2026 The ggml authors |
| ROCmFPX (ROCmFP4/FPX tensor kernels) | charlie12345/ROCmFPX | MIT — Copyright (c) 2023-2026 The ggml authors |
| llama.cpp-rocm fork (gfx1151 + vision) | ArtomYuan/llama.cpp-rocm | MIT-derived — see upstream `THIRD_PARTY_NOTICES.md` |
| ROCm libraries inside the image | AMD | Per ROCm component licenses (see `/opt/rocm/share/doc` in the image) |
| Gemma-4-26B-A4B-it (weights — not bundled) | Google | Apache-2.0; downloaded from Hugging Face at setup time |
| DeepSeek-V4-Flash ROCmFPX (weights — not bundled) | otheru on Hugging Face (base: DeepSeek) | Weights are downloaded at setup time and are **not** redistributed here; the upstream/base licenses apply |

**Model weights are never part of this repository.** Profiles download them
from Hugging Face during setup (see the main README), which keeps every
license where it belongs: weights under their own terms, and the runtime we
compile under the MIT terms acknowledged above.
