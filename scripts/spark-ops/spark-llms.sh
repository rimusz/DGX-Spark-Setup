#!/bin/bash
# spark-llms — probe DeepSeek on :8001 (LAN only).
set -euo pipefail

SPARK_LOCAL="${SPARK_LOCAL:-spark-local}"
SPARK_LAN_IP="${SPARK_LAN_IP:-}"
PORT=8001

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

base_local="http://${SPARK_LOCAL}:${PORT}/v1"
base_ip=""
if [ -n "${SPARK_LAN_IP}" ]; then
  base_ip="http://${SPARK_LAN_IP}:${PORT}/v1"
fi

echo "Spark DeepSeek (LAN only)"
echo "─────────────────────────"
echo "Probing: ${SPARK_LOCAL}${SPARK_LAN_IP:+ | ${SPARK_LAN_IP}}"
echo ""

via=""
api_id=""
if slot_live "${base_local}"; then
  via="LAN ${SPARK_LOCAL}"
  api_id="$(discover_api_model "${base_local}")"
elif [ -n "${base_ip}" ] && slot_live "${base_ip}"; then
  via="LAN ${SPARK_LAN_IP}"
  api_id="$(discover_api_model "${base_ip}")"
fi

if [ -n "${via}" ]; then
  echo "  ✅ deepseek  :${PORT}/v1  [EXL3 / SparkInfer or ds4]  via ${via}"
  if [ -n "${api_id}" ]; then
    echo "     api=${api_id}"
  fi
else
  echo "  ○  deepseek  :${PORT}/v1  (not serving)"
fi
echo "     LAN:        ${base_local}"
if [ -n "${base_ip}" ]; then
  echo "     LAN IP:     ${base_ip}"
fi
echo ""

if [ -z "${via}" ]; then
  echo "⚠️  Not serving. On Spark: sm status ; sm start deepseek"
  echo ""
fi
