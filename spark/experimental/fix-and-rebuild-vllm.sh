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

echo "[$(date -Is)] Patching CMakeLists MoE SM100/SM120 arches for GB10"
# CUDA 13 path: include 12.0f so GB10/sm_121 intersects
sed -i 's/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0f;11.0f" "${CUDA_ARCHS}")/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0f;11.0f;12.0f" "${CUDA_ARCHS}")/' CMakeLists.txt
# older CUDA path
sed -i 's/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0a" "${CUDA_ARCHS}")/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0a;12.1a" "${CUDA_ARCHS}")/' CMakeLists.txt

echo "Verify patch:"
grep -n 'SCALED_MM_ARCHS "10.0f;11.0f' CMakeLists.txt | head -5
grep -n 'SCALED_MM_ARCHS "10.0a' CMakeLists.txt | head -5

echo "[$(date -Is)] Clean extension build and reinstall"
rm -rf build/ .deps/*/build 2>/dev/null || true
# force rebuild of extension
find . -name "_C*.so" -delete 2>/dev/null || true
find vllm -name "_C*" -delete 2>/dev/null || true

python3 use_existing_torch.py || true
uv pip install --no-build-isolation --prerelease=allow -e . --reinstall-package vllm 2>&1 | tee "$INSTALL_DIR/vllm-rebuild.log"

echo "[$(date -Is)] Verify symbols"
nm -D vllm/_C.abi3.so 2>/dev/null | grep cutlass_moe_mm_sm100 || true
python - << 'PY2'
import vllm
from vllm.platforms import current_platform
print("vllm", vllm.__version__)
print("platform", current_platform)
import torch
print("cuda", torch.cuda.is_available(), torch.cuda.get_device_name(0))
print("IMPORT OK")
PY2
echo "[$(date -Is)] REBUILD COMPLETE"
