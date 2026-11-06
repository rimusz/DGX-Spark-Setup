#!/usr/bin/env bash
# Production path: OpenAI-compatible vLLM for nvidia/Qwen3.6-35B-A3B-NVFP4 on DGX Spark.
# Sudoless when user is in the docker group.
#
# Lessons applied from MiaAI-Lab/Qwen3.6-27B-NVFP4-DFlash-DGX-Spark:
#   - nightly-aarch64 image tag, host network/ipc, readiness poll
#   - CUTE_DSL_ARCH=sm_121a, Triton + HF cache mounts, HF_TOKEN passthrough
#   - --served-model-name for a stable API model id
#
# Our 35B-A3B MoE flags follow NVIDIA model card (modelopt, fp8 KV, marlin, flashinfer, MTP-3).
set -euo pipefail

MODEL_ID="${MODEL_ID:-nvidia/Qwen3.6-35B-A3B-NVFP4}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen36-35b-a3b-nvfp4}"
IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:nightly-aarch64}"
NAME="${CONTAINER_NAME:-vllm-qwen35}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
HF_CACHE="${HF_CACHE:-${HOME}/.cache/huggingface}"
TRITON_CACHE="${TRITON_CACHE:-${HOME}/.cache/triton}"
READY_URL="http://127.0.0.1:${PORT}/v1/models"
LOG_FILE="${LOG_FILE:-${HOME}/logs/vllm-qwen35.docker.log}"

# Load HF token from host file if not already in env (never commit tokens to git)
if [ -z "${HF_TOKEN:-}" ] && [ -f "${HOME}/.hf_env" ]; then
  # shellcheck disable=SC1091
  . "${HOME}/.hf_env"
fi
if [ -z "${HF_TOKEN:-}" ] && [ -f "${HOME}/.cache/huggingface/token" ]; then
  HF_TOKEN="$(tr -d ' \n' < "${HOME}/.cache/huggingface/token")"
  export HF_TOKEN
fi
export HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-${HF_TOKEN:-}}"

command -v docker >/dev/null 2>&1 || { echo "docker not on PATH"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl not on PATH"; exit 1; }

if ! docker info >/dev/null 2>&1; then
  echo "Cannot talk to Docker. Add user to docker group:"
  echo "  sudo usermod -aG docker \"\$USER\" && newgrp docker"
  exit 1
fi

mkdir -p "${HF_CACHE}" "${TRITON_CACHE}" "$(dirname "${LOG_FILE}")"

# Best-effort: stop native unit if someone started it
if systemctl is-active --quiet vllm-qwen35 2>/dev/null; then
  echo "Note: system unit vllm-qwen35 is active — prefer: sudo systemctl stop vllm-qwen35"
fi

if docker ps --format '{{.Names}}' | grep -qx "${NAME}"; then
  echo "Container ${NAME} already running."
  curl -sf "${READY_URL}" >/dev/null && echo "Ready: ${READY_URL}" || echo "Still loading — docker logs -f ${NAME}"
  exit 0
fi

docker rm -f "${NAME}" 2>/dev/null || true

echo "Pulling ${IMAGE}..."
docker pull "${IMAGE}"

echo "Starting ${NAME} for ${MODEL_ID} on ${HOST}:${PORT}"
docker run -d \
  --name "${NAME}" \
  --restart unless-stopped \
  --gpus all \
  --network host \
  --ipc host \
  --privileged \
  -e VLLM_TARGET_DEVICE=cuda \
  -e VLLM_FLOAT32_MATMUL_PRECISION=high \
  -e CUTE_DSL_ARCH=sm_121a \
  -e HF_HOME=/root/.cache/huggingface \
  -e TRITON_CACHE_DIR=/root/.triton \
  -e HF_XET_HIGH_PERFORMANCE=1 \
  -e VLLM_USE_FLASHINFER_MXFP4_MOE=1 \
  -e VLLM_MXFP4_USE_MARLIN=1 \
  -e VLLM_ATTENTION_BACKEND=FLASHINFER \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -e HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-${HF_TOKEN:-}}" \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  -v "${TRITON_CACHE}:/root/.triton" \
  "${IMAGE}" \
  "${MODEL_ID}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --host "${HOST}" \
  --port "${PORT}" \
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
  --enable-auto-tool-choice \
  >/dev/null

echo "Spawned ${NAME} ($(docker inspect -f '{{.Id}}' "${NAME}" | cut -c1-12))"
echo "Waiting for ${READY_URL} ..."
for i in $(seq 1 180); do
  if curl -fsS --connect-timeout 2 "${READY_URL}" >/dev/null 2>&1; then
    echo "vLLM is ready"
    echo "OpenAI base URL: http://${HOST}:${PORT}/v1"
    echo "Model id:        ${SERVED_MODEL_NAME}"
    echo "Logs:            docker logs -f ${NAME}"
    exit 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "${NAME}"; then
    echo "Container exited before ready. Last logs:"
    docker logs --tail 80 "${NAME}" 2>&1 || true
    exit 1
  fi
  if (( i % 6 == 0 )); then
    echo "  still loading... (${i}/180)"
  fi
  sleep 5
done

echo "Timed out waiting for readiness. Logs:"
docker logs --tail 100 "${NAME}" 2>&1 || true
exit 1
