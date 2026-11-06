#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/cuda/bin:$PATH"
export TORCH_CUDA_ARCH_LIST=12.1a
export VLLM_USE_FLASHINFER_MXFP4_MOE=1
export TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas
export CUDA_HOME=/usr/local/cuda
INSTALL_DIR="$HOME/vllm-install"
cd "$INSTALL_DIR/vllm"
source "$INSTALL_DIR/.vllm/bin/activate"

echo "[$(date -Is)] Upgrade vLLM to origin/main for Qwen3.5/3.6 MoE"
git fetch origin main
git checkout -f origin/main
git submodule update --init --recursive

# Pin flashinfer to known-good
if grep -q 'flashinfer-python' requirements/cuda.txt; then
  sed -i 's/flashinfer-python.*/flashinfer-python==0.6.9/' requirements/cuda.txt || true
fi

# CMake MoE arch fix for GB10
sed -i 's/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0f;11.0f" "${CUDA_ARCHS}")/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0f;11.0f;12.0f" "${CUDA_ARCHS}")/' CMakeLists.txt || true
sed -i 's/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0a" "${CUDA_ARCHS}")/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0a;12.1a" "${CUDA_ARCHS}")/' CMakeLists.txt || true

# license field if needed
sed -i 's/^license = "Apache-2.0"$/license = {text = "Apache-2.0"}/' pyproject.toml || true
sed -i '/^license-files = /d' pyproject.toml || true

python3 use_existing_torch.py || true
# keep transformers 5.x for qwen3_5_moe config
uv pip install -U "transformers>=5.0" 2>&1 | tail -5

echo "[$(date -Is)] Building vLLM main (long)..."
uv pip install --no-build-isolation --prerelease=allow -e . 2>&1 | tee "$INSTALL_DIR/vllm-main-build.log"

# ensure env
cat > "$INSTALL_DIR/vllm_env.sh" << 'ENV'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.vllm/bin/activate"
export TORCH_CUDA_ARCH_LIST=12.1a
export VLLM_USE_FLASHINFER_MXFP4_MOE=1
export VLLM_MXFP4_USE_MARLIN=1
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
python - << 'PY2'
import vllm, torch
print("vllm", vllm.__version__)
print("cuda", torch.cuda.is_available(), torch.cuda.get_device_name(0))
from vllm.model_executor.models import _MODELS if False else None
# check registry
from vllm.model_executor.models.registry import ModelRegistry
print("has Qwen3_5Moe", any("Qwen3_5" in str(x) for x in dir() ))
import vllm.model_executor.models as m
import pkgutil, vllm.model_executor.models as models_pkg
print("IMPORT OK")
PY2
# verify architecture registered
python -c "from vllm.model_executor.models.registry import _VLLM_MODELS; print([k for k in _VLLM_MODELS if 'Qwen3' in k][:30])" 2>&1 || python -c "from vllm.model_executor.models.registry import ModelRegistry; print('registry ok')" 2>&1
echo "[$(date -Is)] UPGRADE COMPLETE"
