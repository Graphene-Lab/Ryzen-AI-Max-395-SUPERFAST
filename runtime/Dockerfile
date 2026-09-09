# Build image for the llama.cpp ROCmFPX runtime (gfx1151 / Strix Halo).
#
# Produces llama-server (and llama-quantize/llama-bench) compiled against
# ROCm 7.2.4 for the AMD Strix Halo APU. Used by the gemma and deepseek
# profiles (GGUF files with ROCmFP4/ROCmFPX tensor types).
#
# Single stage: the final image keeps the build environment so no second
# runtime download is needed; this matters on slow links. See NOTICE.md for
# upstream credits and licenses (llama.cpp / ROCmFPX are MIT, ROCm is AMD's).
#
# Build:
#   podman build -t llama-rocmfpx:7.2.4 .
FROM registry.fedoraproject.org/fedora:43

# rocm 7.2.4 repo
RUN <<'EOF'
tee /etc/yum.repos.d/rocm.repo <<REPO
[ROCm-7.2.4]
name=ROCm7.2.4
baseurl=https://repo.radeon.com/rocm/rhel10/7.2.4/main
enabled=1
priority=50
gpgcheck=1
gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
REPO
EOF

# toolchain + ROCm dev packages
RUN dnf -y --nodocs --setopt=install_weak_deps=False \
  --exclude='*sdk*' --exclude='*samples*' --exclude='*-doc*' --exclude='*-docs*' \
  install \
  make gcc cmake lld clang clang-devel compiler-rt libcurl-devel ninja-build rdma-core-devel \
  rocm-llvm rocm-device-libs hip-runtime-amd hip-devel \
  rocblas rocblas-devel hipblas hipblas-devel rocm-cmake libomp-devel libomp \
  rocminfo radeontop \
  git-core vim sudo rsync patch \
  && dnf clean all && rm -rf /var/cache/dnf/*

ENV ROCM_PATH=/opt/rocm \
  HIP_PATH=/opt/rocm \
  HIP_CLANG_PATH=/opt/rocm/llvm/bin \
  HIP_DEVICE_LIB_PATH=/opt/rocm/amdgcn/bitcode \
  PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:$PATH

# ROCmFPX fork (llama.cpp with ROCmFP3/FP4/FP6/FP8 weight formats)
WORKDIR /opt/llama.cpp
ARG REPO=https://github.com/charlie12345/ROCmFPX.git
ARG BRANCH=main
RUN git clone -b ${BRANCH} --single-branch ${REPO} .

# GGML_HIP_FORCE_MMQ=ON is required for the ROCmFP4 MMQ kernels.
# (the upstream Dockerfile also applied a grammar patch that is not present in
# the repo; it is omitted here so the build is self-contained)
RUN git clean -xdf \
  && cmake -S . -B build \
  -DGGML_HIP=ON \
  -DGGML_VULKAN=OFF \
  -DGGML_CUDA=OFF \
  -DGGML_HIP_FORCE_MMQ=ON \
  -DCMAKE_HIP_ARCHITECTURES=gfx1151 \
  -DGPU_TARGETS=gfx1151 \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_RPC=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_EXAMPLES=ON \
  -DLLAMA_BUILD_WEBUI=OFF \
  -DLLAMA_USE_PREBUILT_WEBUI=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DGGML_BUILD_TESTS=OFF \
  -DROCM_PATH=/opt/rocm \
  -DHIP_PATH=/opt/rocm \
  -DHIP_PLATFORM=amd \
  && cmake --build build --config Release -- -j$(nproc) \
  && cmake --install build --config Release

# installed libs live in /usr/local/lib64; tell the loader about them
RUN mkdir -p /usr/local/lib64 \
  && find /opt/llama.cpp/build -type f -name 'lib*.so*' -exec cp {} /usr/local/lib64/ \; \
  && printf '/usr/local/lib64\n/usr/local/lib\n' > /etc/ld.so.conf.d/local.conf \
  && ldconfig

ENTRYPOINT ["/usr/local/bin/llama-server"]
