#!/bin/bash
# Build localhost/superfast-vk:nemotron, the Vulkan engine the nemotron profile
# runs on: plain llama.cpp mainline, no patch series.
#
# Why a second image: ornith, ornith122 and the image generator run the
# project's fork (patch 0012), whose snapshot predates nemotron_h_moe. That
# architecture is upstream, so this image is built from upstream at a pinned
# commit and nothing is patched on top.
#
# The Dockerfile is runtime/Dockerfile.vulkan, which expects a build context
# holding src/ = the source tree. The clone lives under ~/.cache and is reused,
# so the second run only fetches.
#
# Acceptance is not "podman build returned 0". The image must carry the
# architecture, and that is checked in libllama.so, not in llama-server: in
# recent llama.cpp the server binary is a small launcher and holds no arch
# strings. The count is calibrated against an arch that must be present
# (qwen35moe), so a zero means "wrong file", not "old build".
set -euo pipefail

REPO="${SUPERFAST_NEMOTRON_REPO:-https://github.com/ggml-org/llama.cpp}"
REF="${SUPERFAST_NEMOTRON_REF:-ca89968a23a13e571a6b802a9891d22763153b61}"
SRC="${SUPERFAST_NEMOTRON_SRC:-$HOME/.cache/llama.cpp-nemotron}"
IMG="${SUPERFAST_NEMOTRON_IMAGE:-localhost/superfast-vk:nemotron}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DOCKERFILE="${SUPERFAST_NEMOTRON_DOCKERFILE:-$HERE/../runtime/Dockerfile.vulkan}"

[ -f "$DOCKERFILE" ] || { echo "missing $DOCKERFILE" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
    echo "cloning $REPO under $SRC"
    git clone --filter=blob:none "$REPO" "$SRC"
fi
# A pinned SHA is fetched directly; a branch name needs the normal fetch.
if ! git -C "$SRC" fetch --depth 1 origin "$REF" 2>/dev/null; then
    git -C "$SRC" fetch origin
fi
git -C "$SRC" checkout --detach "$REF"
echo "building from $(git -C "$SRC" log --oneline -1)"

CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/src"
tar -C "$SRC" --exclude=.git -cf - . | tar -C "$CTX/src" -xf -
cp "$DOCKERFILE" "$CTX/Dockerfile.vulkan"
podman build -f "$CTX/Dockerfile.vulkan" -t "$IMG" "$CTX"

arch_count() {  # arch_count <image> <arch>
    podman run --rm --entrypoint /bin/sh "$1" -c \
        "strings /usr/lib64/libllama.so 2>/dev/null | grep -c '$2' || true" 2>/dev/null \
        | tr -d '\r' | tail -1
}
N="$(arch_count "$IMG" nemotron_h_moe)"
CAL="$(arch_count "$IMG" qwen35moe)"
if [ "${N:-0}" -gt 0 ] && [ "${CAL:-0}" -gt 0 ]; then
    echo "built $IMG (nemotron_h_moe=$N, calibration qwen35moe=$CAL)"
else
    echo "build finished but the architecture check failed: nemotron_h_moe=${N:-0} qwen35moe=${CAL:-0}" >&2
    exit 1
fi
