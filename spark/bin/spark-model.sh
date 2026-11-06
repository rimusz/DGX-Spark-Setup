#!/usr/bin/env bash
# Exclusive multi-model switcher for DGX Spark (one active server at a time).
#
# Models share ~128 GB unified memory — do NOT run two heavy servers together.
#
#   sm status                 (sm == spark-model)
#   sm stop
#   sm start qwen|deepseek|ling|deepseek-ds4
#   sm pull qwen|deepseek|ling|deepseek-ds4|all
#   sm download …                      # alias of pull
#
# Ports (OpenAI base = http://spark:<port>/v1):
#   qwen         → 8000  (vLLM Docker)     model id: qwen36-35b-a3b-nvfp4 / HF id
#   deepseek     → 8001  (EXL3 / SparkInfer)  DeepSeek-V4-Flash-0731
#   deepseek-ds4 → 8001  (ds4-server GGUF)    backup of the same 0731 family
#   ling         → 8002  (SGLang Docker)   inclusionAI/Ling-3.0-flash-int4
#
# Upstream wrappers:
#   DeepSeek default: rimusz/DeepSeek-v4-Flash-One-DGX-Spark (EXL3, 8/256k/:8001)
#   DeepSeek backup:  Entrpi/ds4-on-spark (GGUF in ~/gguf)
#   Ling:             MiaAI-Lab/Ling-3.0-Flash-SGLang-DGX-Spark
set -euo pipefail

export PATH="${HOME}/bin:${HOME}/.local/bin:${PATH}"

# Hugging Face token for pulls (host file; not in git)
if [ -z "${HF_TOKEN:-}" ] && [ -f "${HOME}/.hf_env" ]; then
  # shellcheck disable=SC1091
  . "${HOME}/.hf_env"
fi
if [ -z "${HF_TOKEN:-}" ] && [ -f "${HOME}/.cache/huggingface/token" ]; then
  HF_TOKEN="$(tr -d ' \n' < "${HOME}/.cache/huggingface/token")"
  export HF_TOKEN
fi
export HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-${HF_TOKEN:-}}"

REPO_SPARK="${SPARK_REPO_DIR:-${HOME}/DGX-Spark-Setup/spark}"
if [ ! -d "${REPO_SPARK}/models" ]; then
  # fall back to script-relative tree when invoked from a git checkout
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -d "${HERE}/../models" ]; then
    REPO_SPARK="$(cd "${HERE}/.." && pwd)"
  fi
fi

MODELS_DIR="${REPO_SPARK}/models"
RUNTIME_DIR="${HOME}/.spark-models"
mkdir -p "${RUNTIME_DIR}/deepseek" "${RUNTIME_DIR}/ling" "${HOME}/logs"

# Entrpi ds4-on-spark installer default (512k). Override with CTX=… if needed.
DS4_CTX="${CTX:-524288}"
EXL3_DIR="${EXL3_DIR:-${HOME}/code/dsv4-exl3}"
EXL3_REPO_URL="${EXL3_REPO_URL:-https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark.git}"
AUTOSTART_FILE="${HOME}/.config/spark-models/autostart"

arm_autostart() {
  mkdir -p "$(dirname "${AUTOSTART_FILE}")"
  printf '%s\n' "$1" > "${AUTOSTART_FILE}"
}

disarm_autostart() {
  rm -f "${AUTOSTART_FILE}" "${HOME}/.config/ds4/autostart"
}

autostart_model() {
  if [ -f "${AUTOSTART_FILE}" ]; then
    tr -d '[:space:]' < "${AUTOSTART_FILE}"
  elif [ -f "${HOME}/.config/ds4/autostart" ]; then
    echo deepseek
  fi
}

cmd="${1:-status}"
arg="${2:-}"

port_for() {
  case "$1" in
    qwen) echo 8000 ;;
    deepseek) echo 8001 ;;
    ling) echo 8002 ;;
    *) return 1 ;;
  esac
}

# Human-readable byte size (e.g. 12.4 GiB)
human_bytes() {
  local b="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B --format='%.1f' "${b}" 2>/dev/null && return 0
  fi
  awk -v b="${b}" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " ")
    s = b + 0
    i = 1
    while (s >= 1024 && i < 5) { s /= 1024; i++ }
    printf "%.1f %s\n", s, u[i]
  }'
}

# Print Docker image size before pull (local if present, else registry).
# Prefer compressed layer size for pulls; fall back to local unpacked Size.
docker_image_size_report() {
  local image="$1"
  local label="${2:-Image}"
  local bytes="" src=""

  # 1) Local image (unpacked on disk)
  if docker image inspect "${image}" >/dev/null 2>&1; then
    bytes=$(docker image inspect "${image}" --format '{{.Size}}' 2>/dev/null || true)
    src="local (unpacked)"
  fi

  # 2) crane (best for registry compressed size on arm64)
  if command -v crane >/dev/null 2>&1; then
    local crane_b=""
    crane_b=$(crane manifest --platform linux/arm64 "${image}" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    layers = d.get("layers") or []
    if layers:
        print(sum(int(l.get("size") or 0) for l in layers))
except Exception:
    pass
' 2>/dev/null || true)
    if [ -z "${crane_b}" ] || [ "${crane_b}" = "0" ]; then
      crane_b=$(crane manifest "${image}" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    layers = d.get("layers") or []
    if layers:
        print(sum(int(l.get("size") or 0) for l in layers))
except Exception:
    pass
' 2>/dev/null || true)
    fi
    if [ -n "${crane_b}" ] && [ "${crane_b}" != "0" ]; then
      bytes="${crane_b}"
      src="registry (compressed layers)"
    fi
  fi

  # 3) docker manifest inspect (no crane): resolve arm64 platform digest → layer sum
  if [ -z "${bytes}" ] || [ "${bytes}" = "0" ]; then
    bytes=$(
      IMG="${image}" docker manifest inspect "${image}" 2>/dev/null | IMG="${image}" python3 -c '
import json, sys, subprocess, os
img = os.environ.get("IMG", "")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

def layers_size(m):
    return sum(int(l.get("size") or 0) for l in (m.get("layers") or []))

if d.get("layers"):
    print(layers_size(d))
    sys.exit(0)

manifests = d.get("manifests") or []
pick = None
for m in manifests:
    p = m.get("platform") or {}
    if p.get("os") == "linux" and p.get("architecture") in ("arm64", "aarch64"):
        pick = m
        break
if pick is None and manifests:
    pick = manifests[0]
if not pick:
    sys.exit(0)
digest = pick.get("digest") or ""
name = img.split("@")[0]
last = name.rsplit("/", 1)[-1]
if ":" in last:
    name = name.rsplit(":", 1)[0]
if digest:
    r = subprocess.run(
        ["docker", "manifest", "inspect", f"{name}@{digest}"],
        capture_output=True, text=True,
    )
    if r.returncode == 0:
        try:
            m = json.loads(r.stdout)
            if m.get("layers"):
                print(layers_size(m))
                sys.exit(0)
        except Exception:
            pass
print(int(pick.get("size") or 0) or "")
' 2>/dev/null || true
    )
    if [ -n "${bytes}" ] && [ "${bytes}" != "0" ]; then
      src="registry (compressed layers, arm64 if available)"
    fi
  fi

  if [ -n "${bytes}" ] && [ "${bytes}" != "0" ]; then
    echo "${label}: ${image}"
    echo "  Size:  $(human_bytes "${bytes}")  [${src:-unknown}]"
  else
    echo "${label}: ${image}"
    echo "  Size:  (unknown before pull — will show after docker pull)"
  fi
}

# Catalog model id (shown even when not serving)
model_id_for() {
  case "$1" in
    qwen) echo "nvidia/Qwen3.6-35B-A3B-NVFP4" ;;
    deepseek) echo "DeepSeek-V4-Flash (EXL3 0731)" ;;
    ling) echo "inclusionAI/Ling-3.0-flash-int4" ;;
    *) echo "?" ;;
  esac
}

# Short engine label for status
engine_for() {
  case "$1" in
    qwen) echo "vLLM Docker" ;;
    deepseek)
      if pgrep -x ds4-server >/dev/null 2>&1; then
        echo "ds4-server (backup)"
      else
        echo "EXL3 / SparkInfer"
      fi
      ;;
    ling) echo "SGLang Docker" ;;
    *) echo "?" ;;
  esac
}

url_ok() {
  local port="$1"
  curl -sf --connect-timeout 2 "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1
}

stop_qwen() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'vllm-qwen35'; then
    echo "Stopping Qwen (vllm-qwen35)..."
    docker rm -f vllm-qwen35 >/dev/null 2>&1 || true
  fi
}

stop_ling() {
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'ling-3.0-flash-int4'; then
    echo "Stopping Ling (ling-3.0-flash-int4)..."
    # MiaAI stop.sh prompts; use force path
    (cd "${RUNTIME_DIR}/ling" && PORT=8002 CONTAINER_NAME=ling-3.0-flash-int4 \
      bash "${MODELS_DIR}/ling/stop.sh" --force) 2>/dev/null \
      || docker rm -f ling-3.0-flash-int4 >/dev/null 2>&1 || true
  fi
}

stop_exl3() {
  local names
  names="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E 'deepseek-v4-flash' || true)"
  if [ -z "${names}" ]; then
    return 0
  fi
  echo "Stopping DeepSeek (EXL3 Docker)..."
  if [ -x "${EXL3_DIR}/start.sh" ]; then
    (cd "${EXL3_DIR}" && ./start.sh stop) 2>/dev/null || true
  fi
  # leftover trial on :8888 or compose recreate
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E 'deepseek-v4-flash' \
    | while read -r n; do docker rm -f "${n}" >/dev/null 2>&1 || true; done
}

stop_deepseek() {
  stop_exl3
  if pgrep -x ds4-server >/dev/null 2>&1; then
    echo "Stopping DeepSeek (ds4-server backup)..."
    PORT=8001 bash "${MODELS_DIR}/deepseek/stop.sh" 2>/dev/null || pkill -x ds4-server || true
    PORT=8888 bash "${MODELS_DIR}/deepseek/stop.sh" 2>/dev/null || true
  fi
}

stop_all() {
  disarm_autostart
  stop_qwen
  stop_ling
  stop_deepseek
  # native unit if ever started
  systemctl is-active --quiet vllm-qwen35 2>/dev/null && echo "Note: native vllm-qwen35 unit active — sudo systemctl stop vllm-qwen35"
  echo "All heavy model servers stopped (best-effort)."
}

status_one() {
  local name="$1" port catalog live
  port="$(port_for "$name")"
  catalog="$(model_id_for "$name")"
  if url_ok "$port"; then
    # Display catalog HF-style name (same as idle). API id can differ (path / short slug).
    live="$(curl -sf --connect-timeout 2 "http://127.0.0.1:${port}/v1/models" \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("data",[{}])[0].get("id","") or "")' 2>/dev/null || true)"
    if [ -n "${live}" ] && [ "${live}" != "${catalog}" ]; then
      echo "  ✅ ${name}  :${port}/v1  model=${catalog}  api=${live}  [$(engine_for "$name")]"
    else
      echo "  ✅ ${name}  :${port}/v1  model=${catalog}  [$(engine_for "$name")]"
    fi
  else
    echo "  ○  ${name}  :${port}/v1  model=${catalog}  [$(engine_for "$name")]  (not serving)"
  fi
}

do_status() {
  echo "========================================"
  echo "Spark Models Management"
  echo "========================================"
  echo
  print_mem
  echo
  docker_rows="$(docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | head -10 || true)"
  if [ -n "${docker_rows}" ]; then
    echo "Docker:"
    printf '  %-20s %-24s %s\n' "NAME" "STATUS" "IMAGE"
    while IFS=$'\t' read -r n s i; do
      [ -n "${n}" ] || continue
      printf '  %-20s %-24s %s\n' "${n}" "${s}" "${i}"
    done <<< "${docker_rows}"
  else
    echo "Docker: (no containers)"
  fi
  if pgrep -x ds4-server >/dev/null 2>&1; then
    echo "ds4-server: running"
  fi
  _as="$(autostart_model || true)"
  if [ -n "${_as}" ]; then
    echo "Reboot autostart: ${_as}  (last sm start; sm stop clears)"
  else
    echo "Reboot autostart: off"
  fi
  echo
  echo "DGX Spark models (exclusive GPU/RAM — only one should be ✅):"
  status_one qwen
  status_one deepseek
  status_one ling
  echo
  echo "URLs:"
  echo "  Qwen     → http://spark:8000/v1"
  echo "  DeepSeek → http://spark:8001/v1"
  echo "  Ling     → http://spark:8002/v1"
  echo
  echo "Commands:"
  echo "  sm start qwen"
  echo "  sm start deepseek            # EXL3 (default)"
  echo "  sm start deepseek-ds4        # GGUF backup"
  echo "  sm start ling"
  echo "  sm stop"
  echo "  sm pull qwen|deepseek|ling|all"
  echo "  vo status|logs|restart|stop|start|pull   # Qwen Docker only"
}

# Host memory (GB10 = CPU+GPU share one pool; nvidia-smi VRAM columns are N/A)
print_mem() {
  if ! command -v free >/dev/null 2>&1; then
    return 0
  fi
  # free -b Mem line: total used free shared buff/cache available
  # shellcheck disable=SC2207
  local fields
  fields=($(free -b 2>/dev/null | awk '/^Mem:/{print $2,$3,$4,$6,$7}'))
  if [ "${#fields[@]}" -lt 5 ]; then
    free -h 2>/dev/null | awk 'NR==1 || /^Mem:/' | sed 's/^/  /'
    return 0
  fi
  human() {
    awk -v b="$1" 'BEGIN{printf "%.1fGi", b/1024/1024/1024}'
  }
  local total used free_b cache avail
  total="$(human "${fields[0]}")"
  used="$(human "${fields[1]}")"
  free_b="$(human "${fields[2]}")"
  cache="$(human "${fields[3]}")"
  avail="$(human "${fields[4]}")"
  echo "Memory (unified — GB10: CPU + GPU share this pool, not separate VRAM):"
  printf '  %-12s %8s  %s\n' "total" "${total}" "physical RAM size of the pool"
  printf '  %-12s %8s  %s\n' "used" "${used}" "actively held by apps (vLLM weights/KV, OS, …)"
  printf '  %-12s %8s  %s\n' "free" "${free_b}" "truly idle pages (often small while cache is large)"
  printf '  %-12s %8s  %s\n' "buff/cache" "${cache}" "kernel cache (HF files, page cache) — reclaimable under pressure"
  printf '  %-12s %8s  %s\n' "available" "${avail}" "estimate free+reclaimable — room left for another model / growth"
  echo "  (On Spark, watch available before sm start; MoE + long context needs tens of GiB free.)"
}

ensure_models_dir() {
  if [ ! -f "${MODELS_DIR}/deepseek/start.sh" ] \
    || [ ! -f "${MODELS_DIR}/deepseek/start-exl3.sh" ] \
    || [ ! -f "${MODELS_DIR}/ling/start.sh" ]; then
    echo "Missing vendored scripts under ${MODELS_DIR}"
    echo "Sync repo: rsync setup-spark.sh + spark/ to ~/DGX-Spark-Setup/ then bash setup-spark.sh"
    exit 1
  fi
}

start_qwen() {
  stop_all
  echo "Starting Qwen (vLLM Docker) on :8000 ..."
  if [ -x "${HOME}/bin/vllm-qwen35-docker.sh" ]; then
    PORT=8000 "${HOME}/bin/vllm-qwen35-docker.sh"
  else
    bash "${REPO_SPARK}/bin/vllm-qwen35-docker.sh"
  fi
  arm_autostart qwen
}

start_deepseek() {
  start_deepseek_exl3 "$@"
}

start_deepseek_exl3() {
  ensure_models_dir
  stop_all
  echo "Starting DeepSeek-V4-Flash EXL3 (SparkInfer) on :8001 ..."
  echo "Recipe: ${EXL3_DIR}  (GGUF backup: sm start deepseek-ds4)"
  echo "client profile: MAX_NUM_SEQS=${MAX_NUM_SEQS:-8}  MAX_MODEL_LEN=${MAX_MODEL_LEN:-256000}  DSPARK_TOKENS=${DSPARK_TOKENS:-5}"
  local rc=0
  PORT=8001 AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-0}" ABLATE="${ABLATE:-0}" \
    MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}" MAX_MODEL_LEN="${MAX_MODEL_LEN:-256000}" \
    DSPARK_TOKENS="${DSPARK_TOKENS:-5}" \
    bash "${MODELS_DIR}/deepseek/start-exl3.sh" "$@"
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    arm_autostart deepseek
  fi
  return "${rc}"
}

start_deepseek_ds4() {
  ensure_models_dir
  stop_all
  echo "Starting DeepSeek-V4-Flash (ds4-server GGUF backup) on :8001  CTX=${DS4_CTX} ..."
  echo "Log: ~/ds4-server.log   weights: ~/gguf   source: ~/code/ds4"
  echo "Bind: 0.0.0.0:8001  Disk KV: ${KV_DISK_DIR:-~/ds4-kv}"
  cd "${RUNTIME_DIR}/deepseek"
  local rc=0
  set +o pipefail
  PORT=8001 HOST="${HOST:-0.0.0.0}" CTX="${DS4_CTX}" \
    KV_DISK_DIR="${KV_DISK_DIR-${HOME}/ds4-kv}" \
    KV_DISK_SPACE_MB="${KV_DISK_SPACE_MB:-8192}" \
    bash "${MODELS_DIR}/deepseek/start.sh" "$@" 2>&1 | _filter_ds4_noise
  rc=${PIPESTATUS[0]}
  set -o pipefail
  if [ "${rc}" -eq 0 ]; then
    arm_autostart deepseek-ds4
  fi
  return "${rc}"
}

start_ling() {
  ensure_models_dir
  stop_all
  echo "Starting Ling-3.0-flash-int4 (SGLang Docker) on :8002 ..."
  echo "First run pulls image + weights (~25–40 GiB)."
  # WORK_DIR for pid/log files
  cd "${RUNTIME_DIR}/ling"
  # Align with MiaAI deployed Spark profile (can override via env)
  export PORT=8002
  export CTX="${CTX:-262144}"
  export MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.70}"
  export MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-4}"
  export MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-16}"
  export ENABLE_NEXTN="${ENABLE_NEXTN:-1}"
  export DOCKER_MEMORY="${DOCKER_MEMORY:-100g}"
  export HF_HOME="${HF_HOME:-${HOME}/.cache/huggingface}"
  bash "${MODELS_DIR}/ling/start.sh" "$@"
  arm_autostart ling
}

QWEN_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:nightly-aarch64}"
LING_IMAGE="${LING_IMAGE:-ghcr.io/miaai-lab/ling-3.0-flash-sglang-dgx-spark:ling_v3_support}"

download_qwen() {
  if [ -x "${HOME}/bin/download-qwen35-nvfp4.sh" ]; then
    "${HOME}/bin/download-qwen35-nvfp4.sh"
  else
    bash "${REPO_SPARK}/bin/download-qwen35-nvfp4.sh"
  fi
}

download_deepseek() {
  # Prefer full pull (build + GGUF, no --start)
  pull_deepseek
}

download_ling() {
  ensure_models_dir
  cd "${RUNTIME_DIR}/ling"
  export PORT=8002
  export HF_HOME="${HF_HOME:-${HOME}/.cache/huggingface}"
  bash "${MODELS_DIR}/ling/start.sh" --download-only
}

# pull = container/runtime image (if any) + weights; does NOT stop a running model
# and does NOT start serving (DeepSeek installer is run without --start).
pull_qwen() {
  echo "==> Pull Qwen (image + weights)"
  docker_image_size_report "${QWEN_IMAGE}" "Docker image"
  echo "  Weights: nvidia/Qwen3.6-35B-A3B-NVFP4  (~20–25 GiB HF, NVFP4; varies by cache)"
  echo ""
  echo "==> docker pull ${QWEN_IMAGE}"
  docker pull "${QWEN_IMAGE}"
  if docker image inspect "${QWEN_IMAGE}" >/dev/null 2>&1; then
    echo "  Local image size after pull: $(human_bytes "$(docker image inspect "${QWEN_IMAGE}" --format '{{.Size}}')") (unpacked)"
  fi
  echo "==> Download Qwen weights: nvidia/Qwen3.6-35B-A3B-NVFP4"
  download_qwen
  echo "==> Qwen pull complete (image + HF cache). Start with: sm start qwen"
}

pull_ling() {
  ensure_models_dir
  echo "==> Pull Ling (image + weights)"
  docker_image_size_report "${LING_IMAGE}" "Docker image"
  echo "  Weights: inclusionAI/Ling-3.0-flash-int4  (~25–40 GiB first pull; varies)"
  echo ""
  echo "==> docker pull ${LING_IMAGE}"
  docker pull "${LING_IMAGE}" || {
    echo "WARN: Spark GHCR pull failed; trying LMSYS image..."
    docker_image_size_report "lmsysorg/sglang:dev-Ling-3.0-flash" "Fallback image"
    docker pull lmsysorg/sglang:dev-Ling-3.0-flash
  }
  if docker image inspect "${LING_IMAGE}" >/dev/null 2>&1; then
    echo "  Local image size after pull: $(human_bytes "$(docker image inspect "${LING_IMAGE}" --format '{{.Size}}')") (unpacked)"
  fi
  echo "==> Download Ling weights: inclusionAI/Ling-3.0-flash-int4"
  download_ling
  echo "==> Ling pull complete. Start with: sm start ling"
}

# Soften noisy Upstream ds4 build log (keep errors / real progress).
# Compiler dumps (carets, __attribute__, "In function …") look like gibberish in sm.
_filter_ds4_noise() {
  local line
  while IFS= read -r line || [ -n "${line}" ]; do
    # Always keep real failures
    if [[ "${line}" == *FATAL:* || "${line}" == *'fatal error'* \
      || "${line}" == *'error:'* || "${line}" == *Error:* \
      || "${line}" == *FAILED* || "${line}" == *' failed'* ]]; then
      printf '%s\n' "${line}"
      continue
    fi

    # Keep installer / our wrapper progress
    if [[ "${line}" =~ ^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] ]] \
      || [[ "${line}" == OK:* || "${line}" == '==>'* || "${line}" == WARNING:* \
        || "${line}" == NOTE:* || "${line}" == Starting\ * || "${line}" == Waiting\ * \
        || "${line}" == Stopping\ * || "${line}" == Bind:* || "${line}" == 'ds4-serve:'* \
        || "${line}" == DeepSeek* || "${line}" == 'First run'* || "${line}" == Log:* \
        || "${line}" == Source:* || "${line}" == Weights:* || "${line}" == Phases:* \
        || "${line}" == sm\ * ]] \
      || [[ "${line}" == *Downloading* || "${line}" == *GGUF* || "${line}" == *.gguf* \
        || "${line}" == 'HEAD is now'* || "${line}" == 'From https://'* \
        || "${line}" == *' tag '* || "${line}" == Fast-forwarding* \
        || "${line}" == 'Verifying host'* || "${line}" == GPU:* || "${line}" == nvcc:* \
        || "${line}" == 'Host checks'* || "${line}" == 'Building ds4'* \
        || "${line}" == Installed* || "${line}" == *'pull complete'* \
        || "${line}" == *'ready on'* || "${line}" == *'up on http'* \
        || "${line}" == *'GiB'* ]]; then
      printf '%s\n' "${line}"
      continue
    fi
    # banners / numbered phases
    if [[ "${line}" =~ ^[=#-]{8,} ]] || [[ "${line}" =~ ^[[:space:]]*[0-9]+\) ]]; then
      printf '%s\n' "${line}"
      continue
    fi

    # Drop compiler / make / git-advice noise
    if [[ "${line}" == *'In function'* || "${line}" == *'inlined from'* \
      || "${line}" == *'In file included from'* || "${line}" == *'from ds4'* \
      || "${line}" == *__attribute__* || "${line}" == *__builtin* \
      || "${line}" == *__glibc_objsize* || "${line}" == *__va_arg_pack* \
      || "${line}" == *'warning #'* || "${line}" == *-W* \
      || "${line}" == *'was declared but never referenced'* \
      || "${line}" == *'Remark: The warnings'* || "${line}" == *'note: '* \
      || "${line}" == *'detached HEAD'* || "${line}" == 'git switch'* \
      || "${line}" == *'Turn off this advice'* || "${line}" == make\[* \
      || "${line}" == 'make -B '* || "${line}" == cc\ -O* \
      || "${line}" == /usr/local/cuda/bin/nvcc\ * \
      || "${line}" == 'Cuda compilation tools'* ]]; then
      continue
    fi
    # gcc/clang caret diagnostics: " 1234 | ..." / "     | ~~~^~~"
    if [[ "${line}" =~ ^[[:space:]]*[0-9]+[[:space:]]*\| ]] \
      || [[ "${line}" =~ ^[[:space:]]*\| ]] \
      || [[ "${line}" =~ ^[[:space:]]*\^[[:space:]]*$ ]] \
      || [[ "${line}" =~ ^[[:space:]]*~+\^ ]] \
      || [[ "${line}" =~ ^[a-zA-Z0-9_./+-]+\.(c|h|cu|cpp): ]]; then
      continue
    fi

    [[ -z "${line//[[:space:]]/}" ]] && continue

    # Keep anything else unclassified (safer than dropping unknown progress)
    printf '%s\n' "${line}"
  done
}

pull_deepseek() {
  pull_deepseek_exl3
}

pull_deepseek_exl3() {
  ensure_models_dir
  echo "========================================"
  echo "sm pull deepseek — EXL3 / SparkInfer (not ds4 GGUF)"
  echo "========================================"
  mkdir -p "$(dirname "${EXL3_DIR}")"
  if [ ! -x "${EXL3_DIR}/download.sh" ]; then
    echo "Cloning rimusz EXL3 recipe → ${EXL3_DIR}"
    git clone --depth 1 "${EXL3_REPO_URL}" "${EXL3_DIR}"
  elif [ -d "${EXL3_DIR}/.git" ]; then
    # Keep data/ + hf-hub; retarget older MiaAI checkouts to rimusz.
    local origin
    origin="$(git -C "${EXL3_DIR}" remote get-url origin 2>/dev/null || true)"
    case "${origin}" in
      *rimusz/DeepSeek-v4-Flash-One-DGX-Spark*)
        echo "Recipe already at ${origin}"
        git -C "${EXL3_DIR}" fetch --depth 1 origin main 2>/dev/null || true
        git -C "${EXL3_DIR}" checkout -B main "origin/main" 2>/dev/null || true
        ;;
      *)
        echo "Retargeting ${EXL3_DIR} origin → ${EXL3_REPO_URL}"
        echo "(weights under data/ and hf-hub are kept)"
        git -C "${EXL3_DIR}" remote set-url origin "${EXL3_REPO_URL}"
        git -C "${EXL3_DIR}" fetch --depth 1 origin main
        git -C "${EXL3_DIR}" checkout -B main "origin/main"
        ;;
    esac
  fi
  echo "Weights + coalesce via ${EXL3_DIR}/download.sh (~107 GiB). Does not start serve."
  echo "GGUF backup pull: sm pull deepseek-ds4"
  (cd "${EXL3_DIR}" && ./download.sh)
  echo "Start: sm start deepseek  →  http://spark:8001/v1"
}

pull_deepseek_ds4() {
  ensure_models_dir
  local log="${HOME}/logs/sm-pull-deepseek-ds4.log"
  mkdir -p "${HOME}/logs"

  echo "========================================"
  echo "sm pull deepseek-ds4 — native ds4-server GGUF backup"
  echo "========================================"
  echo "Entrpi/ds4 build + ~110 GiB GGUF → ~/gguf (does not start serve)."
  echo "Full log: ${log}"
  echo

  local tmp
  tmp="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/Entrpi/ds4-on-spark/main/install.sh" -o "${tmp}"

  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=advice.detachedHead
  export GIT_CONFIG_VALUE_0=false

  local rc=0
  set +o pipefail
  bash "${tmp}" --port 8001 --ctx "${DS4_CTX}" 2>&1 \
    | tee "${log}" \
    | _filter_ds4_noise
  rc=${PIPESTATUS[0]}
  set -o pipefail
  rm -f "${tmp}"

  if [ "${rc}" -ne 0 ]; then
    echo "❌ DeepSeek GGUF pull failed (exit ${rc}). Log: ${log}"
    return "${rc}"
  fi

  if pgrep -x ds4-server >/dev/null 2>&1; then
    echo "Stopping ds4-server left running by installer (pull should not serve)..."
    stop_deepseek
  fi

  echo "✅ GGUF backup ready. Start: sm start deepseek-ds4"
}

pull_all() {
  echo "========== sm pull all (images + weights; no exclusive start) =========="
  pull_qwen
  echo
  pull_ling
  echo
  pull_deepseek
  echo
  echo "All pulls finished. Use: sm start qwen|deepseek|ling"
}

usage() {
  cat <<'EOF'
Usage: spark-model <command> [model]

Commands:
  status                 Show which model ports are live
  stop                   Stop Qwen + DeepSeek + Ling (clears reboot autostart)
  start <model>          Stop others, start one (exclusive; that model returns after reboot)
  pull <model|all>       Prefetch runtime image + weights (does not start serve*)
  download <model|all>   Alias of pull

  * deepseek pull = EXL3 download.sh; deepseek-ds4 pull = Entrpi GGUF installer

Models:
  qwen           vLLM Docker,     port 8000, nvidia/Qwen3.6-35B-A3B-NVFP4
  deepseek       EXL3 SparkInfer, port 8001, DeepSeek-V4-Flash-0731 (default)
  deepseek-ds4   ds4-server GGUF, port 8001, same 0731 family (backup)
  ling           SGLang Docker,   port 8002, Ling-3.0-flash-int4
  all            qwen + ling + deepseek EXL3 (pull only)

Examples:
  sm status
  sm start deepseek
  sm start deepseek-ds4
  sm start deepseek --ds4
  sm pull deepseek
  sm pull deepseek-ds4
  sm stop
EOF
}

case "${cmd}" in
  status|st) do_status ;;
  stop) stop_all ;;
  start)
    case "${arg}" in
      qwen|q) start_qwen ;;
      deepseek-ds4|ds4|deepseek-gguf) start_deepseek_ds4 "${@:3}" ;;
      deepseek|ds|deep)
        case "${3:-}" in
          --ds4|--gguf) start_deepseek_ds4 "${@:4}" ;;
          *) start_deepseek_exl3 "${@:3}" ;;
        esac
        ;;
      ling|l) start_ling "${@:3}" ;;
      *) echo "Need model: qwen|deepseek|deepseek-ds4|ling"; usage; exit 1 ;;
    esac
    ;;
  pull|download|dl)
    case "${arg}" in
      qwen|q) pull_qwen ;;
      deepseek-ds4|ds4|deepseek-gguf) pull_deepseek_ds4 ;;
      deepseek|ds|deep) pull_deepseek_exl3 ;;
      ling|l) pull_ling ;;
      all|a) pull_all ;;
      *) echo "Need model: qwen|deepseek|deepseek-ds4|ling|all"; usage; exit 1 ;;
    esac
    ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
