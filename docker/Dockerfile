# syntax=docker/dockerfile:1.12
# llama.cpp llama-server (CPU build) with a quantized Qwen2.5 1.5B Instruct model baked in.

# Base image pinned by tag and digest (llama.cpp build b11429, linux/amd64 + arm64 index).
FROM ghcr.io/ggml-org/llama.cpp:server-b11429@sha256:2f8ebc2dde83c4bd7e5c6d61efa57965e0d5a79d29802c246c4593740d9c04c1

# Model pinned to a Hugging Face commit; the build fails if the sha256 doesn't match.
# Qwen2.5-1.5B-Instruct, Q4_K_M quantization, ~1.1 GB, Apache-2.0 license.
# Create /models first: if ADD creates it, --chmod=444 also applies to the directory,
# dropping the execute bit so the non-root user can't open the file inside.
RUN mkdir -p -m 755 /models
ARG MODEL_URL=https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf
ADD --checksum=sha256:6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e \
    --chmod=444 ${MODEL_URL} /models/model.gguf

# Run as a non-root user; the server only needs to read the model.
USER 65532:65532

EXPOSE 8080

# Entrypoint (/app/llama-server) comes from the base image.
#   --metrics      exposes Prometheus metrics on /metrics
#   --parallel 2   two request slots per pod; extra requests queue ("deferred" in metrics)
#   --ctx-size     total context, split across slots (2048 tokens each)
CMD ["--model", "/models/model.gguf", \
     "--alias", "qwen2.5-1.5b-instruct", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--metrics", \
     "--parallel", "2", \
     "--ctx-size", "4096"]
