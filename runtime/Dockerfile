# Build image for the llama.cpp ROCmFPX runtime (gfx1151 / Strix Halo).
#
# Produces llama-server (and llama-quantize/llama-bench) compiled for the
# AMD Strix Halo APU. Used by the gemma and deepseek profiles (GGUF files
# with ROCmFP4/ROCmFPX tensor types).
#
# Build:
#   podman build -t llama-rocmfpx:rocm10 .
#
# The runtime image ships upstream MIT software (llama.cpp, ROCmFPX) plus AMD
# ROCm libraries; see NOTICE.md for credits and licenses.
FROM docker.io/rocm/dev-ubuntu-24.04:10.0.0-full
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git cmake ninja-build gcc g++ libcurl4-openssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/ArtomYuan/llama.cpp-rocm.git /src
WORKDIR /src
ENV ROCM_PATH=/opt/rocm
RUN cmake -B build -DGGML_HIP=ON -DCMAKE_BUILD_TYPE=Release \
      -DAMDGPU_TARGETS=gfx1151 \
      -DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
      -DCMAKE_PREFIX_PATH=/opt/rocm/core-10.0 \
      -DLLAMA_CURL=OFF -DGGML_OPENMP=OFF \
    && cmake --build build -j $(nproc) --target llama-server llama-quantize llama-bench
ENTRYPOINT ["/src/build/bin/llama-server"]
