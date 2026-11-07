# superfast — Third-Party Notices

The containers this project ships redistribute the components below. Each is
governed by its own license, whose text lives inside the image at the path
given. Where any of these conflicts with the superfast EULA, **the license of
the component governs that component.**

| image | base | what it adds |
|---|---|---|
| `ghcr.io/graphene-lab/superfast-runtime:llama-rocmfpx-1`, tagged locally as `llama-rocmfpx:7.2.4` | Fedora 43 | ROCm **7.2.4** runtime and libraries, plus the ROCmFPX build of llama.cpp |
| `localhost/superfast-vk` (`patch0012`, `nemotron`) | Fedora 43 | llama.cpp built against Vulkan/radv |

## llama.cpp

Redistributed as `libllama.so` plus the `llama-server` binary. Licensed **MIT**
(© the ggml authors); the ROCmFPX and Vulkan builds are forks of the same
tree. The license text is in `/usr/share/licenses/` inside each image.

## AMD ROCm (runtime image only)

Redistributed from AMD's ROCm **7.2.4** packages: the HSA runtime, the HIP
runtime, `amd_comgr`, hipBLAS, hipBLASLt and hipcc. These carry AMD's own
licenses (MIT, and Apache-2.0 WITH LLVM-exception for the LLVM-derived parts),
and each package ships its text inside the image:

| component | license text in image |
| --- | --- |
| `amd_comgr` | `/opt/rocm/share/doc/amd_comgr/LICENSE.txt` |
| `hip` | `/opt/rocm/share/doc/hip/` |
| `hipblas`, `hipblas-common`, `hipblaslt` | `/opt/rocm/share/doc/<name>/` |
| ROCm runtime and libraries (RPMs) | `rpm -qa --qf '%{NAME} %{LICENSE}\n'` inside the image |

## Fedora base

The Fedora 43 userland in both images is distributed under the licenses Fedora
records per package; the full set is queryable inside the image with
`rpm -qa --qf '%{NAME} %{LICENSE}\n'`.

The Vulkan engine image additionally loads the **radv** Vulkan driver and the
**Mesa** stack from the Fedora base, licensed MIT.
