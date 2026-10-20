#!/bin/bash
# Build localhost/superfast-flash-vk:1, the Vulkan engine used by the flash
# profile (llama.cpp + --ple-disk).
#
# The Dockerfile alone is not enough: the build needs the ROCmFPX source
# snapshot, which is not vendored in this repository. The script therefore
# clones the strix-nebulosa lab (about 194 MB) under ~/.cache and reuses it on
# the next run.
#
# Called by deploy/setup-fedora.sh when VULKAN_FLASH=1 (the default), and safe
# to run on its own.
set -euo pipefail

REPO="${SUPERFAST_VK_REPO:-https://github.com/pugant/strix-nebulosa}"
SRC="${SUPERFAST_VK_SRC:-$HOME/.cache/strix-nebulosa}"
IMG="${SUPERFAST_VK_IMAGE:-localhost/superfast-flash-vk:1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DOCKERFILE="${SUPERFAST_VK_DOCKERFILE:-$HERE/../runtime/Dockerfile.vulkan}"

[ -f "$DOCKERFILE" ] || { echo "missing $DOCKERFILE" >&2; exit 1; }

# The image is published in the project's package: pull it and skip the clone
# and the build. The build is the fallback when the pull fails (no network).
PUBLISHED="${SUPERFAST_VK_PULL:-ghcr.io/graphene-lab/ryzen-ai-max-395-superfast:flash-vk-1}"
if podman pull "$PUBLISHED" >/dev/null 2>&1; then
    podman tag "$PUBLISHED" "$IMG"
    echo "pulled $PUBLISHED as $IMG"
    exit 0
fi
echo "could not pull $PUBLISHED; building instead"

if [ ! -d "$SRC/rocmfpx" ]; then
    echo "cloning $REPO into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 "$REPO" "$SRC"
else
    git -C "$SRC" fetch --depth 1 origin main
    git -C "$SRC" reset --hard origin/main
fi

CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/src"
cp -a "$SRC/rocmfpx/." "$CTX/src/"
cp "$DOCKERFILE" "$CTX/Dockerfile"

echo "building $IMG from $(du -sh "$CTX" | cut -f1) of source"
podman build -t "$IMG" "$CTX"
echo "built $IMG"
