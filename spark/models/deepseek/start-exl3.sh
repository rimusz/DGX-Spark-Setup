#!/usr/bin/env bash
#
# start-exl3.sh — EXL3 / SparkInfer DeepSeek-V4-Flash-0731 on :8001.
#
# Wraps ~/code/dsv4-exl3/start.sh (clone of
# rimusz/DeepSeek-v4-Flash-One-DGX-Spark — 8 concurrent seqs / 256k / :8001).
# GGUF backup remains models/deepseek/start.sh (sm start deepseek-ds4).
#
# Usage:
#   PORT=8001 ./start-exl3.sh
#   ./start-exl3.sh --no-wait
#
# Env:
#   EXL3_DIR         recipe checkout (default ~/code/dsv4-exl3)
#   PORT             SERVING_PORT (default 8001)
#   MAX_NUM_SEQS     concurrent slots (default 8)
#   MAX_MODEL_LEN    context tokens (default 256000)
#   DSPARK_TOKENS    speculative draft depth (default 5; engine floor is K5)
#   MAX_NUM_BATCHED_TOKENS  leave 8224 (b12x workspace lock)
#   AUTO_DOWNLOAD    default 0 once TP1 manifest exists
#   ABLATE           default 0
set -euo pipefail

EXL3_DIR="${EXL3_DIR:-${HOME}/code/dsv4-exl3}"
EXL3_REPO_URL="${EXL3_REPO_URL:-https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark.git}"
PORT="${PORT:-8001}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-256000}"
DSPARK_TOKENS="${DSPARK_TOKENS:-5}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8224}"
# Decode graphs: rows ≈ seqs * (k+1) → 8,16,48 at defaults.
if [ -z "${MAX_CUDAGRAPH_CAPTURE_SIZE:-}" ]; then
  MAX_CUDAGRAPH_CAPTURE_SIZE=$((MAX_NUM_SEQS * (DSPARK_TOKENS + 1)))
fi
if [ -z "${CUDAGRAPH_CAPTURE_SIZES:-}" ]; then
  CUDAGRAPH_CAPTURE_SIZES="${MAX_NUM_SEQS},$((MAX_NUM_SEQS * 2)),${MAX_CUDAGRAPH_CAPTURE_SIZE}"
fi
AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-0}"
ABLATE="${ABLATE:-0}"
READY_URL="http://127.0.0.1:${PORT}/v1/models"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-7200}"

if [ ! -x "${EXL3_DIR}/start.sh" ]; then
  echo "error: ${EXL3_DIR}/start.sh missing" >&2
  echo "Clone: git clone --depth 1 ${EXL3_REPO_URL} ~/code/dsv4-exl3" >&2
  echo "Then:  cd ~/code/dsv4-exl3 && ./download.sh" >&2
  echo "Or:    sm pull deepseek" >&2
  exit 1
fi

if [ ! -f "${EXL3_DIR}/data/tp1/rank-sliced-tp1-manifest.json" ] && [ "${AUTO_DOWNLOAD}" = "0" ]; then
  echo "error: TP1 checkpoint missing at ${EXL3_DIR}/data/tp1" >&2
  echo "Run: cd ${EXL3_DIR} && ./download.sh" >&2
  echo "Or:  sm pull deepseek" >&2
  exit 1
fi

# Older checkouts may still hardcode DSPARK_TOKENS: "5" — prefer env.
if grep -q 'DSPARK_TOKENS: "5"' "${EXL3_DIR}/start.sh" 2>/dev/null; then
  sed -i 's/DSPARK_TOKENS: "5"/DSPARK_TOKENS: "${DSPARK_TOKENS:-5}"/' "${EXL3_DIR}/start.sh"
fi

cd "${EXL3_DIR}"
echo "==> EXL3 DeepSeek on :${PORT}  dir=${EXL3_DIR}"
echo "    seqs=${MAX_NUM_SEQS}  max_len=${MAX_MODEL_LEN}  dspark_tokens=${DSPARK_TOKENS}  graphs=${CUDAGRAPH_CAPTURE_SIZES}  ABLATE=${ABLATE}"
SERVING_PORT="${PORT}" AUTO_DOWNLOAD="${AUTO_DOWNLOAD}" ABLATE="${ABLATE}" \
  MAX_NUM_SEQS="${MAX_NUM_SEQS}" MAX_MODEL_LEN="${MAX_MODEL_LEN}" \
  MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS}" \
  DSPARK_TOKENS="${DSPARK_TOKENS}" \
  MAX_CUDAGRAPH_CAPTURE_SIZE="${MAX_CUDAGRAPH_CAPTURE_SIZE}" \
  CUDAGRAPH_CAPTURE_SIZES="${CUDAGRAPH_CAPTURE_SIZES}" \
  ./start.sh "$@"

# start.sh already waits unless --no-wait; extra probe for sm.
if [[ " $* " == *" --no-wait "* ]]; then
  exit 0
fi
if curl -sf --connect-timeout 3 "${READY_URL}" >/dev/null; then
  echo "EXL3 is up on http://0.0.0.0:${PORT}/v1 (probe ${READY_URL})"
  curl -s "${READY_URL}" | python3 -m json.tool 2>/dev/null || true
  exit 0
fi
echo "warning: ${READY_URL} not ready after start.sh (waited up to ${READY_TIMEOUT_S}s inside launcher)" >&2
exit 1
