#!/usr/bin/env bash
#
# stop.sh — stop Colibri serve started via models/colibri/start.sh
#
# Usage:
#   ./stop.sh
#   ./stop.sh --force   (same; no prompt)
#
# Env:
#   COLIBRI_DIR   checkout (default ~/code/colibri)
#   PORT          only used for leftover-bind messaging (default 8003)
set -euo pipefail

COLIBRI_DIR="${COLIBRI_DIR:-${HOME}/code/colibri}"
PORT="${PORT:-8003}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
export PATH="${HOME}/bin:${HOME}/.local/bin:${CUDA_HOME}/bin:${PATH}"

case "${1:-}" in
  -f|--force|"")
    ;;
  -h|--help)
    echo "Usage: $0 [--force]"
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    exit 1
    ;;
esac

if [ ! -f "${COLIBRI_DIR}/c/coli" ]; then
  echo "Colibri checkout missing (${COLIBRI_DIR}) — nothing to stop."
  exit 0
fi

echo "Stopping Colibri (coli stop)…"
(cd "${COLIBRI_DIR}" && python3 c/coli stop) 2>/dev/null || true

# Best-effort: anything still bound to our OpenAI port
if curl -sf --connect-timeout 1 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
  echo "WARN: http://127.0.0.1:${PORT}/v1/models still answers after coli stop"
  echo "      Check: ss -ltnp | grep ':${PORT}' ; coli status"
else
  echo "Colibri stopped (port ${PORT} clear)."
fi
