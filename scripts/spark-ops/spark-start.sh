#!/bin/bash
# spark-start.sh — start one Spark model via SSH, then print status (status-stack style)
#
# Usage:
#   spark-start.sh qwen|deepseek|ling
#   spark-qwen / spark-deepseek / spark-ling   (aliases → this script)
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
Usage: spark-start.sh qwen|deepseek|ling
   or: spark-qwen | spark-deepseek | spark-ling

Starts the exclusive Spark model over SSH (sm start …), waits until ready,
then prints DGX Spark reachability + System (status-stack style).
EOF
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

# Support argv and symlink names: spark-qwen / spark-deepseek / spark-ling
invoked="$(basename "$0")"
case "$invoked" in
  spark-qwen) model=qwen ;;
  spark-deepseek) model=deepseek ;;
  spark-ling) model=ling ;;
  *) model="${1:-}" ;;
esac
case "$model" in
  qwen|q) model=qwen; port=8000; catalog="nvidia/Qwen3.6-35B-A3B-NVFP4" ;;
  deepseek|ds|deep) model=deepseek; port=8001; catalog="DeepSeek-V4-Flash (EXL3 0731)" ;;
  deepseek-ds4|ds4) model=deepseek-ds4; port=8001; catalog="DeepSeek-V4-Flash (ds4 GGUF backup)" ;;
  ling|l) model=ling; port=8002; catalog="inclusionAI/Ling-3.0-flash-int4" ;;
  "") usage; exit 0 ;;
  *) echo "Unknown model: $model (want qwen|deepseek|deepseek-ds4|ling)" >&2; usage >&2; exit 1 ;;
esac

spark_catalog_model() {
  case "$1" in
    8000|qwen) echo "nvidia/Qwen3.6-35B-A3B-NVFP4" ;;
    8001|deepseek) echo "DeepSeek-V4-Flash (EXL3 0731)" ;;
    8002|ling) echo "inclusionAI/Ling-3.0-flash-int4" ;;
    *) echo "?" ;;
  esac
}

probe_url() {
  local base="$1"
  curl -sf --connect-timeout 3 "${base%/}/models" >/dev/null 2>&1
}

# Prefer LAN spark-local, then SPARK_LAN_IP
best_base_for_port() {
  local p="$1"
  if probe_url "http://${SPARK_LOCAL}:${p}/v1"; then
    echo "http://${SPARK_LOCAL}:${p}/v1"
    return 0
  fi
  if [ -n "${SPARK_LAN_IP}" ] && probe_url "http://${SPARK_LAN_IP}:${p}/v1"; then
    echo "http://${SPARK_LAN_IP}:${p}/v1"
    return 0
  fi
  return 1
}

via_for_host() {
  case "$1" in
    spark-local|192.*|10.*|172.*) echo "LAN" ;;
    *.local) echo "mDNS" ;;
    *) echo "LAN" ;;
  esac
}

print_system() {
  local out
  out=$(
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "${SPARK_SSH}" bash -s 2>/dev/null <<'REMOTE'
set +e
host=$(hostname -s 2>/dev/null || hostname)
arch=$(uname -m)
kern=$(uname -r | cut -d- -f1)
if [ -r /proc/loadavg ]; then
  load=$(cut -d' ' -f1-3 /proc/loadavg)
else
  load=$(uptime 2>/dev/null | sed -n 's/.*load average[s]*: //p')
fi
if command -v free >/dev/null 2>&1; then
  mem=$(free -b | awk '/^Mem:/{printf "%.1fGi used / %.1fGi total (%.0f%%); available %.1fGi", $3/2^30, $2/2^30, 100*$3/$2, $7/2^30}')
else
  mem="n/a"
fi
gpu="n/a"
if command -v nvidia-smi >/dev/null 2>&1; then
  gname=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | sed 's/^ *//')
  gutil=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
  if [ -n "$gname" ]; then
    if echo "$gname" | grep -qi 'GB10'; then
      gpu="${gname} (util ${gutil:-?}%; unified mem — see available)"
    else
      gpu="${gname} (util ${gutil:-?}%)"
    fi
  fi
fi
disk=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s used / %s (%s)", $3, $2, $5}')
if command -v uptime >/dev/null 2>&1; then
  uptime_s=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /;s/, *[0-9]* user.*//')
else
  uptime_s="n/a"
fi
printf 'host=%s\n' "$host"
printf 'cpu=%s kernel %s; load %s\n' "$arch" "$kern" "$load"
printf 'memory=%s\n' "${mem:-n/a}"
printf 'gpu=%s\n' "${gpu:-n/a}"
printf 'disk=%s\n' "${disk:-n/a}"
printf 'uptime=%s\n' "${uptime_s:-n/a}"
REMOTE
  ) || true

  if [ -z "${out}" ]; then
    echo "  System: (unreachable via ssh ${SPARK_SSH})"
    return 1
  fi
  echo "  System:"
  while IFS= read -r line; do
    case "${line}" in
      host=*) echo "    Host: ${line#host=}" ;;
      cpu=*) echo "    CPU: ${line#cpu=}" ;;
      memory=*) echo "    Memory: ${line#memory=}" ;;
      gpu=*) echo "    GPU: ${line#gpu=}" ;;
      disk=*) echo "    Disk: ${line#disk=}" ;;
      uptime=*) echo "    Uptime: ${line#uptime=}" ;;
    esac
  done <<< "${out}"
}

print_status() {
  echo ""
  echo "DGX Spark (LLM inference):"
  local base host_part via live_label live_catalog
  if base="$(best_base_for_port "$port")"; then
    host_part="${base#http://}"
    host_part="${host_part%%:*}"
    via="$(via_for_host "$host_part")"
    live_label="$model"
    live_catalog="$(spark_catalog_model "$port")"
    echo "  ✅ Reachable on ${host_part}:${port} (via ${via}, ${live_label}, model=${live_catalog})"
  else
    echo "  ❌ Not reachable on :${port} yet (started ${model}; still loading?)"
    echo "     Check: ssh ${SPARK_SSH} 'sm status' ; curl -sf http://${SPARK_LOCAL}:${port}/v1/models"
  fi
  print_system || true
}

echo "========================================"
echo "Starting Spark model: ${model} (:${port}/v1 — ${catalog})"
echo "SSH: ${SPARK_SSH}  →  sm start ${model}"
echo "========================================"
echo ""

# Stream start (can take many minutes on cold weight load)
ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 \
  "${SPARK_SSH}" "bash -lc $(printf '%q' "sm start ${model}")"

echo ""
echo "Waiting for http://…:${port}/v1/models (up to ${READY_TIMEOUT_S}s)…"
ready=false
steps=$((READY_TIMEOUT_S / 3))
[ "${steps}" -lt 1 ] && steps=1
for ((i = 0; i < steps; i++)); do
  if best_base_for_port "$port" >/dev/null; then
    ready=true
    break
  fi
  sleep 3
done

if ! $ready; then
  echo "⚠️  Timed out waiting for :${port} — printing status anyway"
fi

print_status
