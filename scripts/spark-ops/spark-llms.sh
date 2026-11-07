#!/bin/bash
# spark-llms — probe Qwen :8000, DeepSeek :8001, Colibri :8003 (LAN only).
set -euo pipefail

SPARK_LOCAL="${SPARK_LOCAL:-spark-local}"
SPARK_LAN_IP="${SPARK_LAN_IP:-}"

slot_live() {
  curl -sf --connect-timeout 3 "${1%/}/models" >/dev/null 2>&1
}

discover_api_model() {
  curl -sf --connect-timeout 3 "${1%/}/models" 2>/dev/null \
    | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    data = d.get("data") or []
    if data:
        print(data[0].get("id") or "")
except Exception:
    pass
' 2>/dev/null || true
}

probe_slot() {
  local name="$1" port="$2" engine="$3"
  local base_local="http://${SPARK_LOCAL}:${port}/v1"
  local base_ip=""
  if [ -n "${SPARK_LAN_IP}" ]; then
    base_ip="http://${SPARK_LAN_IP}:${port}/v1"
  fi

  local via="" api_id=""
  if slot_live "${base_local}"; then
    via="LAN ${SPARK_LOCAL}"
    api_id="$(discover_api_model "${base_local}")"
  elif [ -n "${base_ip}" ] && slot_live "${base_ip}"; then
    via="LAN ${SPARK_LAN_IP}"
    api_id="$(discover_api_model "${base_ip}")"
  fi

  if [ -n "${via}" ]; then
    echo "  ✅ ${name}  :${port}/v1  [${engine}]  via ${via}"
    if [ -n "${api_id}" ]; then
      echo "     api=${api_id}"
    fi
  else
    echo "  ○  ${name}  :${port}/v1  [${engine}]  (not serving)"
  fi
  echo "     LAN:        ${base_local}"
  if [ -n "${base_ip}" ]; then
    echo "     LAN IP:     ${base_ip}"
  fi
  echo ""

  if [ -n "${via}" ]; then
    return 0
  fi
  return 1
}

echo "Spark LLMs (LAN only — one at a time)"
echo "─────────────────────────────────────"
echo "Probing: ${SPARK_LOCAL}${SPARK_LAN_IP:+ | ${SPARK_LAN_IP}}"
echo ""

any=0
probe_slot qwen 8000 "vLLM / data analysis 6·131k" && any=1 || true
probe_slot deepseek 8001 "EXL3 / SparkInfer or ds4" && any=1 || true
probe_slot colibri 8003 "Colibri CUDA qwen36-35b" && any=1 || true

if [ "${any}" -eq 0 ]; then
  echo "⚠️  No model serving. On Spark: sm status ; sm start qwen|deepseek|colibri"
  echo ""
fi
