#!/bin/bash
# spark-start.sh — start DeepSeek via SSH, then print LAN status
#
# Usage:
#   spark-start.sh [deepseek|deepseek-ds4]
#   spark-deepseek   (symlink → this script)
#
# Env:
#   SPARK_SSH   (default: ${SPARK_HOST:-user@spark})
#   READY_TIMEOUT_S  wait for /v1/models (default: 900)
set -euo pipefail

SPARK_SSH="${SPARK_SSH:-${SPARK_HOST:-user@spark}}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-900}"
SPARK_LOCAL="${SPARK_LOCAL:-spark-local}"
SPARK_LAN_IP="${SPARK_LAN_IP:-}"

usage() {
  cat <<EOF
Usage: spark-start.sh [deepseek|deepseek-ds4]
   or: spark-deepseek

Starts DeepSeek over SSH (sm start …), waits until ready,
then prints LAN reachability.
EOF
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

invoked="$(basename "$0")"
case "$invoked" in
  spark-deepseek) model=deepseek ;;
  *) model="${1:-deepseek}" ;;
esac
case "$model" in
  deepseek|ds|deep|"") model=deepseek; catalog="DeepSeek-V4-Flash (EXL3 0731)" ;;
  deepseek-ds4|ds4) model=deepseek-ds4; catalog="DeepSeek-V4-Flash (ds4 GGUF backup)" ;;
  *) echo "Unknown model: $model (want deepseek|deepseek-ds4)" >&2; usage >&2; exit 1 ;;
esac
port=8001

probe_url() {
  curl -sf --connect-timeout 3 "${1%/}/models" >/dev/null 2>&1
}

best_base_for_port() {
  if probe_url "http://${SPARK_LOCAL}:${port}/v1"; then
    echo "http://${SPARK_LOCAL}:${port}/v1"
    return 0
  fi
  if [ -n "${SPARK_LAN_IP}" ] && probe_url "http://${SPARK_LAN_IP}:${port}/v1"; then
    echo "http://${SPARK_LAN_IP}:${port}/v1"
    return 0
  fi
  return 1
}

echo "========================================"
echo "Starting Spark DeepSeek: ${model} (:${port}/v1 — ${catalog})"
echo "SSH: ${SPARK_SSH}  →  sm start ${model}"
echo "========================================"
echo ""

ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 \
  "${SPARK_SSH}" "bash -lc $(printf '%q' "sm start ${model}")"

echo ""
echo "Waiting for http://…:${port}/v1/models (up to ${READY_TIMEOUT_S}s)…"
ready=false
steps=$((READY_TIMEOUT_S / 3))
[ "${steps}" -lt 1 ] && steps=1
for ((i = 0; i < steps; i++)); do
  if best_base_for_port >/dev/null; then
    ready=true
    break
  fi
  sleep 3
done

echo ""
if base="$(best_base_for_port)"; then
  echo "DGX Spark DeepSeek: ✅ ${base}  (${catalog})"
elif [ "${ready}" = true ]; then
  echo "DGX Spark DeepSeek: ✅ reachable"
else
  echo "DGX Spark DeepSeek: ❌ not reachable yet"
  echo "     Check: ssh ${SPARK_SSH} 'sm status' ; curl -sf http://${SPARK_LOCAL}:${port}/v1/models"
fi
