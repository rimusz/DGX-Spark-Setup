#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/cuda/bin:$PATH"
export TORCH_CUDA_ARCH_LIST=12.1a
export VLLM_USE_FLASHINFER_MXFP4_MOE=1
export TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas
export CUDA_HOME=/usr/local/cuda
INSTALL_DIR="$HOME/vllm-install"
source "$INSTALL_DIR/.vllm/bin/activate"
cd "$INSTALL_DIR/vllm"
echo "[$(date -Is)] building vLLM..."
uv pip install --no-build-isolation --prerelease=allow -e . 2>&1 | tee "$INSTALL_DIR/vllm-build.log"
echo "[$(date -Is)] build finished"

cat > "$INSTALL_DIR/vllm_env.sh" << 'ENV'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.vllm/bin/activate"
export TORCH_CUDA_ARCH_LIST=12.1a
export VLLM_USE_FLASHINFER_MXFP4_MOE=1
CUDA_PATH=$(ls -d /usr/local/cuda* 2>/dev/null | head -1)
export TRITON_PTXAS_PATH="$CUDA_PATH/bin/ptxas"
export PATH="$CUDA_PATH/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_PATH/lib64:${LD_LIBRARY_PATH:-}"
export TIKTOKEN_CACHE_DIR="$SCRIPT_DIR/.tiktoken_cache"
mkdir -p "$TIKTOKEN_CACHE_DIR"
echo "=== vLLM Environment Active ==="
ENV
chmod +x "$INSTALL_DIR/vllm_env.sh"
source "$INSTALL_DIR/vllm_env.sh"
python -c "import torch,vllm; print(torch.__version__, vllm.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
echo "[$(date -Is)] INSTALL COMPLETE"
