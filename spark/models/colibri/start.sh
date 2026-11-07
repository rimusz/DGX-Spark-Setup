#!/usr/bin/env bash
#
# start.sh — Colibri qwen36-35b (CUDA) on DGX Spark (GB10).
#
# Clones JustVugg/colibri if needed, runs non-interactive setup for
# qwen36-35b, then serves an OpenAI-compatible API on :8003 (exclusive
# with sm start qwen|deepseek).
#
# Usage:
#   PORT=8003 ./start.sh
#   ./start.sh --download-only
#
# Env:
#   COLIBRI_DIR         checkout (default ~/code/colibri)
#   COLIBRI_REPO_URL    git URL (default https://github.com/JustVugg/colibri.git)
#   COLIBRI_MODEL       setup catalog id (default qwen36-35b)
#   COLIBRI_MODEL_DIR   weight download dir (default ~/colibri-models)
#   COLIBRI_BACKEND     cuda|vulkan|cpu (default cuda)
#   PORT / HOST         listen (default 8003 / 0.0.0.0)
#   READY_TIMEOUT_S     wait for /v1/models (default 1800)
#   CUDA_HOME           (default /usr/local/cuda)
set -euo pipefail

COLIBRI_DIR="${COLIBRI_DIR:-${HOME}/code/colibri}"
COLIBRI_REPO_URL="${COLIBRI_REPO_URL:-https://github.com/JustVugg/colibri.git}"
COLIBRI_MODEL="${COLIBRI_MODEL:-qwen36-35b}"
COLIBRI_MODEL_DIR="${COLIBRI_MODEL_DIR:-${HOME}/colibri-models}"
COLIBRI_BACKEND="${COLIBRI_BACKEND:-cuda}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8003}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-1800}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
READY_URL="http://127.0.0.1:${PORT}/v1/models"
DOWNLOAD_ONLY=false

case "${1:-}" in
  --download-only|--pull-only)
    DOWNLOAD_ONLY=true
    shift
    ;;
  -h|--help)
    cat <<EOF
Usage: $0 [--download-only]

  --download-only   Clone + build/download qwen36-35b; do not serve

Env: COLIBRI_DIR COLIBRI_MODEL COLIBRI_MODEL_DIR COLIBRI_BACKEND PORT HOST CUDA_HOME
EOF
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unknown argument: $1" >&2
    echo "Usage: $0 [--download-only]" >&2
    exit 1
    ;;
esac

export PATH="${HOME}/bin:${HOME}/.local/bin:${CUDA_HOME}/bin:${PATH}"
export CUDA_HOME

# GB10 unified-memory defaults (VRAM and host RAM are one pool).
# Override any of these in the environment before calling start.sh.
export COLI_CUDA="${COLI_CUDA:-1}"
export CUDA_DENSE="${CUDA_DENSE:-1}"
export COLI_CUDA_UNIFIED="${COLI_CUDA_UNIFIED:-1}"
export CUDA_EXPERT_GB="${CUDA_EXPERT_GB:-auto}"
export PIN_GB="${PIN_GB:-all}"
export CUDA_RELEASE_HOST="${CUDA_RELEASE_HOST:-1}"
export RAM_GB="${RAM_GB:-auto}"
export PIPE="${PIPE:-1}"
export DIRECT="${DIRECT:-1}"

command -v python3 >/dev/null 2>&1 || {
  echo "FATAL: python3 is required (3.10+)" >&2
  exit 1
}
command -v git >/dev/null 2>&1 || {
  echo "FATAL: git is required" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "FATAL: curl is required" >&2
  exit 1
}
command -v make >/dev/null 2>&1 || {
  echo "FATAL: make / build-essential required to compile Colibri" >&2
  exit 1
}

if [ "${COLIBRI_BACKEND}" = "cuda" ] && ! command -v nvcc >/dev/null 2>&1; then
  echo "FATAL: nvcc not on PATH (CUDA_HOME=${CUDA_HOME}). Install toolkit or set COLIBRI_BACKEND=vulkan|cpu." >&2
  exit 1
fi

py_ok="$(
  python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1 \
    && echo yes || echo no
)"
if [ "${py_ok}" != "yes" ]; then
  echo "FATAL: Colibri needs Python 3.10+ (have: $(python3 --version 2>&1))" >&2
  exit 1
fi

ensure_checkout() {
  mkdir -p "$(dirname "${COLIBRI_DIR}")"
  if [ ! -f "${COLIBRI_DIR}/c/coli" ] && [ ! -f "${COLIBRI_DIR}/start-here.sh" ]; then
    echo "Cloning Colibri → ${COLIBRI_DIR}"
    git clone --depth 1 "${COLIBRI_REPO_URL}" "${COLIBRI_DIR}"
  elif [ -d "${COLIBRI_DIR}/.git" ]; then
    echo "Colibri checkout: ${COLIBRI_DIR}"
  else
    echo "FATAL: ${COLIBRI_DIR} exists but is not a Colibri tree" >&2
    exit 1
  fi
  if [ ! -f "${COLIBRI_DIR}/c/coli" ]; then
    echo "FATAL: missing ${COLIBRI_DIR}/c/coli" >&2
    exit 1
  fi
}

coli_cmd() {
  (cd "${COLIBRI_DIR}" && python3 c/coli "$@")
}

url_ok() {
  curl -sf --connect-timeout 2 "${READY_URL}" >/dev/null 2>&1
}

# Best-effort stop of a previous Colibri serve on this host (same setup home).
stop_existing() {
  coli_cmd stop >/dev/null 2>&1 || true
  # Stale bind on our port from a foreign process → fail early.
  if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") >/dev/null 2>&1; then
    if ! url_ok; then
      echo "FATAL: port ${PORT} is in use but not answering ${READY_URL}" >&2
      echo "       Free the port or set PORT=…" >&2
      exit 1
    fi
  fi
}

echo "========================================"
echo "Colibri ${COLIBRI_MODEL}  backend=${COLIBRI_BACKEND}"
echo "Checkout: ${COLIBRI_DIR}"
echo "Models:   ${COLIBRI_MODEL_DIR}"
echo "Listen:   ${HOST}:${PORT}/v1"
echo "========================================"

ensure_checkout
mkdir -p "${COLIBRI_MODEL_DIR}" "${HOME}/logs"

echo "==> coli setup --model ${COLIBRI_MODEL} --backend ${COLIBRI_BACKEND} (download/build; no serve)"
coli_cmd setup \
  --yes \
  --model "${COLIBRI_MODEL}" \
  --backend "${COLIBRI_BACKEND}" \
  --host "${HOST}" \
  --port "${PORT}" \
  --dir "${COLIBRI_MODEL_DIR}" \
  --no-start \
  --no-browser

if ${DOWNLOAD_ONLY}; then
  echo "✅ Colibri ${COLIBRI_MODEL} ready under ${COLIBRI_MODEL_DIR}."
  echo "   Start: sm start colibri   (or: PORT=${PORT} $0)"
  exit 0
fi

if url_ok; then
  echo "Already serving ${READY_URL}"
  curl -s "${READY_URL}" | python3 -m json.tool 2>/dev/null || true
  exit 0
fi

stop_existing

echo "==> coli start --background (GB10: UNIFIED + RELEASE_HOST)"
coli_cmd start --background --no-browser

echo "Waiting for ${READY_URL} (up to ${READY_TIMEOUT_S}s)…"
deadline=$((SECONDS + READY_TIMEOUT_S))
while (( SECONDS < deadline )); do
  if url_ok; then
    echo "✅ Colibri ready on http://0.0.0.0:${PORT}/v1"
    curl -s "${READY_URL}" | python3 -m json.tool 2>/dev/null || true
    echo "Dashboard: http://127.0.0.1:${PORT}/   (Tailscale: http://spark:${PORT}/)"
    echo "Stop: sm stop   or   (cd ${COLIBRI_DIR} && python3 c/coli stop)"
    exit 0
  fi
  # Surface hard failures from coli status --json (ignore parse/missing).
  status_json="$(coli_cmd status --json 2>/dev/null || true)"
  if [ -n "${status_json}" ]; then
    err_msg="$(
      printf '%s\n' "${status_json}" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
inst = d.get("install") or {}
srv = d.get("server") or {}
if srv.get("state") == "error" or inst.get("phase") == "error":
    print(inst.get("message") or srv.get("state") or "colibri error")
' 2>/dev/null || true
    )"
    if [ -n "${err_msg}" ]; then
      echo "FATAL: Colibri reported an error while starting: ${err_msg}" >&2
      coli_cmd logs -n 80 2>/dev/null || true
      exit 1
    fi
  fi
  sleep 3
done

echo "FATAL: timed out waiting for ${READY_URL}" >&2
coli_cmd status 2>/dev/null || true
coli_cmd logs -n 80 2>/dev/null || true
exit 1
