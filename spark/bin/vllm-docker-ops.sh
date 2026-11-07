#!/usr/bin/env bash
# Sudoless docker helpers for Spark vLLM (35B-A3B NVFP4).
# Short name: vo  (symlink created by setup-spark.sh)
set -euo pipefail

NAME="${CONTAINER_NAME:-vllm-qwen35}"
PORT="${PORT:-8000}"
cmd="${1:-status}"

case "${cmd}" in
  status)
    echo "Commands (Qwen Docker only; vo == vllm-docker-ops.sh):"
    echo "  vo status"
    echo "  vo logs"
    echo "  vo restart"
    echo "  vo stop"
    echo "  vo start"
    echo "  vo pull"
    echo
    echo "All models (exclusive switcher):"
    echo "  sm status"
    echo "  sm start qwen          # data analysis :8000 (6 seqs / 131k)"
    echo "  sm start deepseek      # DeepSeek EXL3 :8001"
    echo "  sm start colibri       # Colibri CUDA :8003 (opt-in)"
    echo "  sm stop"
    echo "  sm pull qwen|deepseek|colibri|all"
    echo
    docker ps --filter "name=${NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    echo "---"
    curl -sf --connect-timeout 3 "http://127.0.0.1:${PORT}/v1/models" | head -c 400 || echo "(not ready)"
    echo
    echo
    ;;
  logs)
    docker logs -f "${NAME}"
    ;;
  restart)
    docker restart "${NAME}"
    ;;
  stop)
    docker rm -f "${NAME}"
    ;;
  start)
    exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vllm-qwen35-docker.sh"
    ;;
  pull)
    docker pull "${VLLM_IMAGE:-vllm/vllm-openai:nightly-aarch64}"
    ;;
  *)
    echo "Usage: $0 {status|logs|restart|stop|start|pull}"
    exit 1
    ;;
esac
