#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/cuda/bin:$PATH"
export TORCH_CUDA_ARCH_LIST=12.1a
export CUDA_HOME=/usr/local/cuda
cd "$HOME"
echo "[$(date -Is)] Starting vLLM native install to $HOME/vllm-install"
curl -fsSL https://raw.githubusercontent.com/eelbaz/dgx-spark-vllm-setup/main/install.sh \
  | bash -s -- --install-dir "$HOME/vllm-install"
echo "[$(date -Is)] Install finished OK"
# quick import check
# shellcheck disable=SC1091
source "$HOME/vllm-install/vllm_env.sh"
python -c "import torch,vllm; print(torch.__version__, torch.version.cuda, vllm.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
echo "[$(date -Is)] Verification OK"
