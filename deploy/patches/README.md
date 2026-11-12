# Patches applied on top of the engine source

The engine is not vendored in this repository: `deploy/build-vulkan-image.sh`
clones `pugant/strix-nebulosa` (branch `qwen4exp-conv-ring-slots`) and builds
`localhost/superfast-vk:patch0012` from it. These files are the changes that
exist **only** here, applied to that tree before the build.

## `vulkan-prefill-20261112.patch`

Port of the delta-net prefill work from
[`Nathanw1014/llama.cpp`](https://github.com/Nathanw1014/llama.cpp) into our
tree: a tiled-transpose kernel for the dim-0 concat whose source is transposed
(`vulkan-concat-transpose`, commit `1440613`) and the fused silu/mul
(`vulkan-fuse-silu-mul`, commit `ed809a4`). The third fix of that group,
`vulkan-mmid-scale-epilogue`, is **not** included: it depends on the
`vulkan-mmid-rowlists` prepass our tree does not have.

Apply it to a copy of the source, then build with that copy:

```sh
cp -a ~/.cache/strix-nebulosa ~/.cache/strix-prefill
git -C ~/.cache/strix-prefill apply -p1 --directory=rocmfpx deploy/patches/vulkan-prefill-20261112.patch
SUPERFAST_VK_SRC=$HOME/.cache/strix-prefill \
SUPERFAST_VK_IMAGE=localhost/superfast-vk:prefill \
SUPERFAST_VK_PULL=localhost/nonexistent:none \
    bash deploy/build-vulkan-image.sh
```

`SUPERFAST_VK_PULL` has to point at something that cannot be pulled: otherwise
the script tags the published image over the one it is supposed to build. And
the script's `git fetch --depth 1` + `reset --hard` wipes local changes when
`$SRC/rocmfpx` exists, so the patched copy is built through a copy of the script
with those two lines removed (see the note in `docs/PREFILL.md`).

The tiled concat is **opt-in at runtime**, behind `GGML_VK_CONCAT_TRANSPOSE=1`,
so the same image can be measured with and without it. The units now pass
`-e GGML_VK_CONCAT_TRANSPOSE=1`, so production runs it; the tag
`localhost/superfast-vk:patch0012` points at the patched image, and the previous
one is kept as `patch0012-base` (retag it back and restart to roll the patch out).

Measured on 2026-11-12, 35B, cold cache, same prompt, one binary. Side port with
a 96K window:

| prompt | patch off | patch on | delta |
|---|---|---|---|
| 9,916 tok | 1,199 tok/s | 1,243 tok/s | +3.7% |
| 39,617 tok | 995 tok/s | 1,025 tok/s | +3.0% |
| 64,016 tok | 823 tok/s | 831 tok/s | +1.0% |

And on the production configuration (262K window, MTP, vision, gateway), the
same unit restarted with and without the variable:

| prompt | patch off | patch on | delta |
|---|---|---|---|
| 9,916 tok | 1,016 tok/s | 1,040 tok/s | +2.4% |
| 39,617 tok | 884 tok/s | 897 tok/s | +1.5% |
| 64,016 tok | 728 tok/s | 726 tok/s | 0% |

The OFF column of that second table is also the bigger lever: a 262K window costs
about 12% of prefill at the same depth compared with 96K.

Generated text is identical with the flag on and off (375 bytes, same 16 lines,
temperature 0), which is the check that matters: the concat feeds the delta-net
state, so a wrong transpose would corrupt the answer instead of slowing it.

**Changing a unit's flags needs `systemctl --user restart <unit>`.**
`superfast-switch use <profile>` does nothing when that profile is already
loaded, and the container keeps the old arguments; the proof that a flag took is
`podman inspect <container> --format '{{.Config.Env}}'`.
