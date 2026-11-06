#!/usr/bin/env bash
# Ensure Hugging Face `hf` CLI is installed under ~/.local/bin (login PATH).
# Used by setup-spark.sh and model download helpers (Qwen / Ling / sm pull).
#
# Usage:
#   ensure-hf-cli.sh           # install if missing
#   ensure-hf-cli.sh --upgrade # force upgrade via uv tool / installer
set -euo pipefail

export PATH="${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:${PATH}"

FORCE=0
case "${1:-}" in
  -u|--upgrade|--update) FORCE=1 ;;
  -h|--help)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

mkdir -p "${HOME}/.local/bin"

if [ "${FORCE}" -eq 0 ] && command -v hf >/dev/null 2>&1; then
  echo "hf CLI: $(command -v hf) ($(hf --version 2>/dev/null | head -1 || echo ok))"
  exit 0
fi

echo "→ Installing Hugging Face hf CLI → ${HOME}/.local/bin"

if command -v uv >/dev/null 2>&1; then
  # huggingface_hub ships the `hf` / `huggingface-cli` entrypoints
  uv tool install -U huggingface_hub
elif [ -x "${HOME}/.local/bin/uv" ]; then
  "${HOME}/.local/bin/uv" tool install -U huggingface_hub
else
  # Standalone installer (does not require a pre-existing Python env)
  curl -LsSf https://hf.co/cli/install.sh | bash
fi

hash -r 2>/dev/null || true
export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v hf >/dev/null 2>&1; then
  echo "ERROR: hf not on PATH after install. Try: source ~/.bashrc && which hf" >&2
  exit 1
fi

echo "✅ hf CLI: $(command -v hf) ($(hf --version 2>/dev/null | head -1 || echo ok))"
echo "   Use: hf download <org/model>   |   hf auth login   |   HF_TOKEN=… for gated repos"
