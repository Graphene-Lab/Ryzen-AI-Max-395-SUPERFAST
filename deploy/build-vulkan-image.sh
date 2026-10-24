#!/bin/bash
# Build localhost/superfast-vk:patch0012, the Vulkan engine used by every GGUF
# profile (llama.cpp + --ple-disk + patch 0012).
#
# The Dockerfile alone is not enough: the build needs the ROCmFPX source
# snapshot, which is not vendored in this repository. The script therefore
# clones the strix-nebulosa lab (about 194 MB) under ~/.cache and reuses it on
# the next run.
#
# patch 0012 lives on the qwen4exp-conv-ring-slots branch, and the units pass
# --reasoning and --spec-mtp-strict-qwen, which only exist from that patch on.
# A build without them would start and then fail on the first request, so the
# script checks the binary before declaring the image ready.
#
# Called by deploy/setup-fedora.sh when VULKAN_FLASH=1 (the default), and safe
# to run on its own.
set -euo pipefail

REPO="${SUPERFAST_VK_REPO:-https://github.com/pugant/strix-nebulosa}"
REF="${SUPERFAST_VK_REF:-qwen4exp-conv-ring-slots}"
SRC="${SUPERFAST_VK_SRC:-$HOME/.cache/strix-nebulosa}"
IMG="${SUPERFAST_VK_IMAGE:-localhost/superfast-vk:patch0012}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DOCKERFILE="${SUPERFAST_VK_DOCKERFILE:-$HERE/../runtime/Dockerfile.vulkan}"

[ -f "$DOCKERFILE" ] || { echo "missing $DOCKERFILE" >&2; exit 1; }

has_patch0012() {
    podman run --rm --entrypoint /usr/bin/llama-server "$1" --help 2>&1 \
        | grep -q -- '--reasoning'
}

# The image is published in the project's package: pull it and skip the clone
# and the build. The build is the fallback when the pull fails or when the
# published image predates patch 0012.
PUBLISHED="${SUPERFAST_VK_PULL:-ghcr.io/graphene-lab/ryzen-ai-max-395-superfast:flash-vk-1}"
if podman pull "$PUBLISHED" >/dev/null 2>&1; then
    if has_patch0012 "$PUBLISHED"; then
        podman tag "$PUBLISHED" "$IMG"
        echo "pulled $PUBLISHED as $IMG"
        exit 0
    fi
    echo "$PUBLISHED predates patch 0012; building $REF instead"
else
    echo "could not pull $PUBLISHED; building instead"
fi

if [ ! -d "$SRC/rocmfpx" ]; then
    echo "cloning $REPO ($REF) into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --branch "$REF" "$REPO" "$SRC"
else
    git -C "$SRC" fetch --depth 1 origin "$REF"
    git -C "$SRC" reset --hard FETCH_HEAD
fi

CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/src"
cp -a "$SRC/rocmfpx/." "$CTX/src/"
cp "$DOCKERFILE" "$CTX/Dockerfile"

echo "building $IMG from $(du -sh "$CTX" | cut -f1) of source"
podman build -t "$IMG" "$CTX"

if ! has_patch0012 "$IMG"; then
    echo "the image was built but its llama-server has no --reasoning:" >&2
    echo "the units for ornith and flash would start and fail on the first request." >&2
    exit 1
fi
echo "built $IMG with patch 0012"
