#!/usr/bin/env bash
# Prefetch nvidia/Qwen3.6-35B-A3B-NVFP4 into HF cache (avoids cold start races).
# Prefers host `hf` CLI (installed by setup-spark.sh / ensure-hf-cli.sh).
set -euo pipefail

export PATH="${HOME}/bin:${HOME}/.local/bin:${PATH}"
export HF_XET_HIGH_PERFORMANCE=1
MODEL_ID="${MODEL_ID:-nvidia/Qwen3.6-35B-A3B-NVFP4}"
HF_CACHE="${HF_CACHE:-${HOME}/.cache/huggingface}"
export HF_HOME="${HF_CACHE}"

mkdir -p "${HF_CACHE}"

# Prefer shared installer from setup-spark.sh
if [ -x "${HOME}/bin/ensure-hf-cli.sh" ]; then
  "${HOME}/bin/ensure-hf-cli.sh"
elif ! command -v hf >/dev/null 2>&1 && ! command -v huggingface-cli >/dev/null 2>&1; then
  echo "⚠️  ensure-hf-cli.sh missing — installing hf inline (run setup-spark.sh later)"
  if command -v uv >/dev/null 2>&1; then
    uv tool install -U huggingface_hub
  else
    curl -LsSf https://hf.co/cli/install.sh | bash
  fi
  export PATH="${HOME}/.local/bin:${PATH}"
fi

echo "Downloading ${MODEL_ID} → ${HF_CACHE}"
if command -v hf >/dev/null 2>&1; then
  hf download "${MODEL_ID}"
elif command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "${MODEL_ID}"
else
  echo "ERROR: hf CLI not found. Run: ~/bin/ensure-hf-cli.sh  or  bash setup-spark.sh" >&2
  exit 1
fi
echo "Model download complete"
