#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/cuda/bin:$PATH"
export TORCH_CUDA_ARCH_LIST=12.1a
export VLLM_USE_FLASHINFER_MXFP4_MOE=1
export TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas
export CUDA_HOME=/usr/local/cuda
INSTALL_DIR="$HOME/vllm-install"
VLLM_VERSION="66a168a197ba214a5b70a74fa2e713c9eeb3251a"
# shellcheck disable=SC1091
source "$INSTALL_DIR/.vllm/bin/activate"

echo "[$(date -Is)] Step 5: deps (fixed apache-tvm-ffi pin)"
uv pip install xgrammar setuptools-scm "apache-tvm-ffi>=0.1.0" --prerelease=allow
echo "[$(date -Is)] deps OK"

echo "[$(date -Is)] Step 6: clone vLLM $VLLM_VERSION"
cd "$INSTALL_DIR"
if [ -d vllm/.git ]; then
  echo "existing vllm dir - fetch/checkout"
  cd vllm
  git fetch --all --tags || true
  git checkout "$VLLM_VERSION"
  git submodule update --init --recursive
else
  rm -rf vllm
  git clone --recursive https://github.com/vllm-project/vllm.git
  cd vllm
  git checkout "$VLLM_VERSION"
  git submodule update --init --recursive
fi
echo "[$(date -Is)] clone OK"

echo "[$(date -Is)] Step 7: apply fixes"
sed -i 's/^license = "Apache-2.0"$/license = {text = "Apache-2.0"}/' pyproject.toml || true
sed -i '/^license-files = /d' pyproject.toml || true
if ! grep -q 'cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0f;11.0f;12.0f"' CMakeLists.txt 2>/dev/null; then
  sed -i 's/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0f;11.0f"/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0f;11.0f;12.0f"/' CMakeLists.txt || true
  sed -i 's/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0a"/cuda_archs_loose_intersection(SCALED_MM_ARCHS "10.0a;12.1a"/' CMakeLists.txt || true
fi
rm -rf "$HOME/.cache/uv/sdists-v9/pypi/flashinfer-python" 2>/dev/null || true
python3 use_existing_torch.py
echo "[$(date -Is)] fixes OK"

echo "[$(date -Is)] Step 8: build vLLM (15-30 min)"
set +e
uv pip install --no-build-isolation --prerelease=allow -e . 2>&1 | tee "$INSTALL_DIR/vllm-build.log"
BUILD_STATUS=${PIPESTATUS[0]}
set -e
if [ "$BUILD_STATUS" -ne 0 ]; then
  if grep -qi "flashinfer.*license" "$INSTALL_DIR/vllm-build.log"; then
    echo "patching flashinfer license in cache..."
    find "$HOME/.cache/uv" -path "*flashinfer*" -name "pyproject.toml" 2>/dev/null | while read -r f; do
      sed -i 's/^license = "Apache-2.0"$/license = {text = "Apache-2.0"}/' "$f" || true
      sed -i '/^license-files = /d' "$f" || true
    done
    uv pip install --no-build-isolation --prerelease=allow -e .
  else
    echo "BUILD FAILED - see $INSTALL_DIR/vllm-build.log"
    exit 1
  fi
fi
echo "[$(date -Is)] vLLM build OK"

echo "[$(date -Is)] create vllm_env.sh"
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

# shellcheck disable=SC1091
source "$INSTALL_DIR/vllm_env.sh"
python -c "import torch,vllm; print('torch', torch.__version__, 'vllm', vllm.__version__, 'cuda', torch.cuda.is_available(), torch.cuda.get_device_name(0))"
echo "[$(date -Is)] INSTALL COMPLETE"
