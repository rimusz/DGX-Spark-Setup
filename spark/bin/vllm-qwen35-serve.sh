#!/usr/bin/env bash
# Native vLLM serve (secondary path). Prefer vllm-qwen35-docker.sh on current Spark.
#
# Requires a GB10-capable vLLM that registers Qwen3_5MoeForConditionalGeneration
# (v0.11 eelbaz pin does not; newer source builds may fail on torch stable ABI).
# See spark/README.md "Native path notes".
set -euo pipefail

export PATH="${HOME}/.local/bin:/usr/local/cuda/bin:${PATH}"
# shellcheck disable=SC1091
source "${HOME}/vllm-install/vllm_env.sh"

export HF_XET_HIGH_PERFORMANCE=1
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-12.1a}"
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
export VLLM_USE_FLASHINFER_MXFP4_MOE="${VLLM_USE_FLASHINFER_MXFP4_MOE:-1}"
export VLLM_MXFP4_USE_MARLIN="${VLLM_MXFP4_USE_MARLIN:-1}"
export VLLM_ATTENTION_BACKEND="${VLLM_ATTENTION_BACKEND:-FLASHINFER}"

MODEL_ID="${MODEL_ID:-nvidia/Qwen3.6-35B-A3B-NVFP4}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen36-35b-a3b-nvfp4}"

exec vllm serve "${MODEL_ID}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --host 0.0.0.0 \
  --port "${PORT:-8000}" \
  --tensor-parallel-size 1 \
  --trust-remote-code \
  --quantization modelopt \
  --kv-cache-dtype fp8 \
  --attention-backend flashinfer \
  --moe-backend marlin \
  --gpu-memory-utilization "${VLLM_GPU_MEM_UTIL:-0.40}" \
  --max-model-len "${VLLM_MAX_MODEL_LEN:-262144}" \
  --max-num-seqs "${VLLM_MAX_NUM_SEQS:-4}" \
  --max-num-batched-tokens "${VLLM_MAX_NUM_BATCHED_TOKENS:-8192}" \
  --enable-chunked-prefill \
  --async-scheduling \
  --enable-prefix-caching \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3,"moe_backend":"triton"}' \
  --load-format fastsafetensors \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_xml \
  --enable-auto-tool-choice
