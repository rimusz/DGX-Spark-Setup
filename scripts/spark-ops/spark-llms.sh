#!/bin/bash
# spark-llms — quick probe of all three Spark model slots
# Shows which model is serving, with LAN (spark-local) and Tailscale URLs.
# Model names match sm / spark-model catalog (e.g. nvidia/Qwen3.6-35B-A3B-NVFP4).
# Prefer spark-local (/etc/hosts → YOUR_LAN_IP) for LAN clients; avoid mDNS AAAA.
set -euo pipefail

SPARK_LOCAL="${SPARK_LOCAL:-spark-local}"
SPARK_TS="${SPARK_TS:-spark}"
SPARK_MDNS="${SPARK_MDNS:-spark.local}"
# Optional: also show/probe mDNS (often slow / IPv6-first). Set SPARK_PROBE_MDNS=1
SPARK_PROBE_MDNS="${SPARK_PROBE_MDNS:-0}"

# Same catalog as spark/bin/spark-model.sh model_id_for
catalog_model() {
    case "$1" in
        qwen)     echo "nvidia/Qwen3.6-35B-A3B-NVFP4" ;;
        deepseek) echo "DeepSeek-V4-Flash (EXL3 0731)" ;;
        ling)     echo "inclusionAI/Ling-3.0-flash-int4" ;;
        *)        echo "?" ;;
    esac
}

slot_live() {
    local base="$1"
    curl -sf --connect-timeout 3 "${base%/}/models" >/dev/null 2>&1
}

# Print served api id when live (best-effort)
discover_api_model() {
    local base="$1"
    curl -sf --connect-timeout 3 "${base%/}/models" 2>/dev/null \
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

engine_for() {
    case "$1" in
        qwen)     echo "vLLM Docker" ;;
        deepseek) echo "EXL3 / SparkInfer" ;;
        ling)     echo "SGLang Docker" ;;
        *)        echo "?" ;;
    esac
}

echo "Spark LLM Slots"
echo "───────────────"
echo "Probing: LAN ${SPARK_LOCAL}  |  Tailscale: ${SPARK_TS}"
if [ "$SPARK_PROBE_MDNS" = "1" ]; then
    echo "         (+ mDNS ${SPARK_MDNS})"
fi
echo ""

any_live=false

probe_one() {
    local slot="$1" port="$2"
    local base_local="http://${SPARK_LOCAL}:${port}/v1"
    local base_ts="http://${SPARK_TS}:${port}/v1"
    local base_mdns="http://${SPARK_MDNS}:${port}/v1"
    local catalog engine via api_id=""

    catalog="$(catalog_model "$slot")"
    engine="$(engine_for "$slot")"

    if slot_live "$base_local"; then
        via="LAN ${SPARK_LOCAL}"
        api_id="$(discover_api_model "$base_local")"
        any_live=true
    elif slot_live "$base_ts"; then
        via="Tailscale ${SPARK_TS}"
        api_id="$(discover_api_model "$base_ts")"
        any_live=true
    elif [ "$SPARK_PROBE_MDNS" = "1" ] && slot_live "$base_mdns"; then
        via="mDNS ${SPARK_MDNS}"
        api_id="$(discover_api_model "$base_mdns")"
        any_live=true
    else
        via=""
    fi

    if [ -n "$via" ]; then
        echo "  ✅ ${slot}  :${port}/v1  model=${catalog}  [${engine}]  via ${via}"
        if [ -n "$api_id" ] && [ "$api_id" != "$catalog" ]; then
            echo "     api=${api_id}"
        fi
    else
        echo "  ○  ${slot}  :${port}/v1  model=${catalog}  [${engine}]  (not serving)"
    fi
    echo "     LAN:        ${base_local}   ← LAN clients (after Local Network allowlist if needed)"
    echo "     Tailscale:  ${base_ts}"
    if [ "$SPARK_PROBE_MDNS" = "1" ]; then
        echo "     mDNS:       ${base_mdns}"
    fi
    echo ""
}

probe_one "qwen"     8000
probe_one "deepseek" 8001
probe_one "ling"     8002

if ! $any_live; then
    echo "⚠️  No model serving.  On Spark: sm status ; sm start qwen"
    echo ""
fi
