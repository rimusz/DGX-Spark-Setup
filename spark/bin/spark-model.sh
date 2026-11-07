#!/usr/bin/env bash
# Exclusive multi-model switcher for DGX Spark (LAN inference).
# One heavy server at a time (shared ~128 GB unified memory).
#
#   sm status
#   sm stop
#   sm start qwen|deepseek|deepseek-ds4
#   sm pull qwen|deepseek|deepseek-ds4|all
#
# Ports (OpenAI base = http://spark-local:<port>/v1 on LAN):
#   qwen           → 8000  vLLM Docker  Qwen3.6-35B-A3B-NVFP4 (data analysis: 6/131k)
#   deepseek       → 8001  EXL3 / SparkInfer  DeepSeek-V4-Flash-0731
#   deepseek-ds4   → 8001  ds4-server GGUF backup
#
# Recipes:
#   Qwen:     this repo (vllm-qwen35-docker.sh)
#   DeepSeek: rimusz/DeepSeek-v4-Flash-One-DGX-Spark
#   Backup:   Entrpi/ds4-on-spark (GGUF in ~/gguf)
set -euo pipefail

export PATH="${HOME}/bin:${HOME}/.local/bin:${PATH}"

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
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -d "${HERE}/../models" ]; then
    REPO_SPARK="$(cd "${HERE}/.." && pwd)"
  fi
fi

MODELS_DIR="${REPO_SPARK}/models"
RUNTIME_DIR="${HOME}/.spark-models"
mkdir -p "${RUNTIME_DIR}/deepseek" "${HOME}/logs"

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

url_ok() {
  curl -sf --connect-timeout 2 "http://127.0.0.1:${1}/v1/models" >/dev/null 2>&1
}

port_for() {
  case "$1" in
    qwen) echo 8000 ;;
    deepseek|deepseek-ds4) echo 8001 ;;
    *) return 1 ;;
  esac
}

model_id_for() {
  case "$1" in
    qwen) echo "qwen36-35b-a3b-nvfp4 (data analysis 6/131k)" ;;
    deepseek) echo "DeepSeek-V4-Flash (EXL3 0731)" ;;
    deepseek-ds4) echo "DeepSeek-V4-Flash (ds4 GGUF backup)" ;;
    *) echo "?" ;;
  esac
}

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
    deepseek-ds4) echo "ds4-server (backup)" ;;
    *) echo "?" ;;
  esac
}

stop_qwen() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'vllm-qwen35'; then
    echo "Stopping Qwen (vllm-qwen35)..."
    docker rm -f vllm-qwen35 >/dev/null 2>&1 || true
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'vllm-qwen35'; then
    docker rm -f vllm-qwen35 >/dev/null 2>&1 || true
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
  stop_deepseek
  if systemctl is-active --quiet vllm-qwen35 2>/dev/null; then
    echo "Note: native vllm-qwen35 unit active — sudo systemctl stop vllm-qwen35"
  fi
  echo "Spark model servers stopped (best-effort)."
}

print_mem() {
  if ! command -v free >/dev/null 2>&1; then
    return 0
  fi
  local fields
  # shellcheck disable=SC2207
  fields=($(free -b 2>/dev/null | awk '/^Mem:/{print $2,$3,$4,$6,$7}'))
  if [ "${#fields[@]}" -lt 5 ]; then
    free -h 2>/dev/null | awk 'NR==1 || /^Mem:/' | sed 's/^/  /'
    return 0
  fi
  human() { awk -v b="$1" 'BEGIN{printf "%.1fGi", b/1024/1024/1024}'; }
  echo "Memory (unified — GB10: CPU + GPU share this pool):"
  printf '  %-12s %8s\n' "total" "$(human "${fields[0]}")"
  printf '  %-12s %8s\n' "used" "$(human "${fields[1]}")"
  printf '  %-12s %8s\n' "free" "$(human "${fields[2]}")"
  printf '  %-12s %8s\n' "buff/cache" "$(human "${fields[3]}")"
  printf '  %-12s %8s\n' "available" "$(human "${fields[4]}")"
}

status_one() {
  local name="$1" port catalog live
  port="$(port_for "$name")"
  catalog="$(model_id_for "$name")"
  if url_ok "${port}"; then
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
  echo "Spark models (LAN — one at a time)"
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
  status_one qwen
  if pgrep -x ds4-server >/dev/null 2>&1; then
    status_one deepseek-ds4
  else
    status_one deepseek
  fi
  echo
  echo "URLs: http://spark-local:8000/v1 (qwen)  |  http://spark-local:8001/v1 (deepseek)"
  echo "Commands: sm start qwen | sm start deepseek | sm start deepseek-ds4 | sm pull … | sm stop"
}

ensure_models_dir() {
  if [ ! -f "${MODELS_DIR}/deepseek/start.sh" ] \
    || [ ! -f "${MODELS_DIR}/deepseek/start-exl3.sh" ]; then
    echo "Missing vendored scripts under ${MODELS_DIR}/deepseek"
    echo "Sync repo then: bash scripts/spark-ops/setup-spark.sh"
    exit 1
  fi
}

start_qwen() {
  stop_all
  echo "Starting Qwen3.6-35B-A3B-NVFP4 (vLLM) on :8000 ..."
  echo "Profile: data analysis — VLLM_MAX_NUM_SEQS=${VLLM_MAX_NUM_SEQS:-6}  VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-131072}"
  echo "Tools + reasoning on; override env for full 262k (lower seqs)."
  local rc=0
  if [ -x "${HOME}/bin/vllm-qwen35-docker.sh" ]; then
    PORT=8000 "${HOME}/bin/vllm-qwen35-docker.sh"
    rc=$?
  elif [ -x "${REPO_SPARK}/bin/vllm-qwen35-docker.sh" ]; then
    PORT=8000 bash "${REPO_SPARK}/bin/vllm-qwen35-docker.sh"
    rc=$?
  else
    echo "Missing vllm-qwen35-docker.sh — run: bash scripts/spark-ops/setup-spark.sh"
    exit 1
  fi
  if [ "${rc}" -eq 0 ]; then
    arm_autostart qwen
  fi
  return "${rc}"
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

_filter_ds4_noise() {
  local line
  while IFS= read -r line || [ -n "${line}" ]; do
    if [[ "${line}" == *FATAL:* || "${line}" == *'fatal error'* \
      || "${line}" == *'error:'* || "${line}" == *Error:* \
      || "${line}" == *FAILED* || "${line}" == *' failed'* ]]; then
      printf '%s\n' "${line}"
      continue
    fi
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
    if [[ "${line}" =~ ^[=#-]{8,} ]] || [[ "${line}" =~ ^[[:space:]]*[0-9]+\) ]]; then
      printf '%s\n' "${line}"
      continue
    fi
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
    if [[ "${line}" =~ ^[[:space:]]*[0-9]+[[:space:]]*\| ]] \
      || [[ "${line}" =~ ^[[:space:]]*\| ]] \
      || [[ "${line}" =~ ^[[:space:]]*\^[[:space:]]*$ ]] \
      || [[ "${line}" =~ ^[[:space:]]*~+\^ ]] \
      || [[ "${line}" =~ ^[a-zA-Z0-9_./+-]+\.(c|h|cu|cpp): ]]; then
      continue
    fi
    [[ -z "${line//[[:space:]]/}" ]] && continue
    printf '%s\n' "${line}"
  done
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

download_qwen() {
  if [ -x "${HOME}/bin/download-qwen35-nvfp4.sh" ]; then
    "${HOME}/bin/download-qwen35-nvfp4.sh"
  elif [ -x "${REPO_SPARK}/bin/download-qwen35-nvfp4.sh" ]; then
    bash "${REPO_SPARK}/bin/download-qwen35-nvfp4.sh"
  else
    echo "Missing download-qwen35-nvfp4.sh — run: bash scripts/spark-ops/setup-spark.sh"
    exit 1
  fi
}

pull_qwen() {
  echo "========================================"
  echo "sm pull qwen — vLLM image + HF NVFP4 weights"
  echo "========================================"
  echo "Data-analysis serve profile: 6 seqs / 131k (tools + reasoning)."
  local image="${VLLM_IMAGE:-vllm/vllm-openai:nightly-aarch64}"
  echo "Pulling ${image}..."
  docker pull "${image}"
  download_qwen
  echo "==> Qwen pull complete. Start: sm start qwen  →  http://spark-local:8000/v1"
}

pull_deepseek_exl3() {
  ensure_models_dir
  echo "========================================"
  echo "sm pull deepseek — EXL3 / SparkInfer"
  echo "========================================"
  mkdir -p "$(dirname "${EXL3_DIR}")"
  if [ ! -x "${EXL3_DIR}/download.sh" ]; then
    echo "Cloning rimusz EXL3 recipe → ${EXL3_DIR}"
    git clone --depth 1 "${EXL3_REPO_URL}" "${EXL3_DIR}"
  elif [ -d "${EXL3_DIR}/.git" ]; then
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
        git -C "${EXL3_DIR}" remote set-url origin "${EXL3_REPO_URL}"
        git -C "${EXL3_DIR}" fetch --depth 1 origin main
        git -C "${EXL3_DIR}" checkout -B main "origin/main"
        ;;
    esac
  fi
  echo "Weights + coalesce via ${EXL3_DIR}/download.sh (~107 GiB). Does not start serve."
  echo "GGUF backup pull: sm pull deepseek-ds4"
  (cd "${EXL3_DIR}" && ./download.sh)
  echo "Start: sm start deepseek  →  http://spark-local:8001/v1"
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
  pull_qwen
  pull_deepseek_exl3
  echo "All pulls finished. Use: sm start qwen|deepseek"
}

usage() {
  cat <<'EOF'
Usage: spark-model <command> [model]

Commands:
  status                 Show Qwen :8000 / DeepSeek :8001 status
  stop                   Stop all (clears reboot autostart)
  start <model>          Start one model (exclusive; returns after reboot)
  pull <model>           Prefetch weights (does not start serve)
  download <model>       Alias of pull

Models:
  qwen           vLLM Docker, port 8000 — data analysis (6 seqs / 131k, tools)
  deepseek       EXL3 SparkInfer, port 8001 (8 seqs / 256k / K5)
  deepseek-ds4   ds4-server GGUF backup, port 8001
  all            qwen + deepseek EXL3 (pull only)

Examples:
  sm status
  sm pull qwen && sm start qwen
  sm pull deepseek && sm start deepseek
  sm start deepseek-ds4
  sm stop

Qwen overrides (optional):
  VLLM_MAX_NUM_SEQS=4 VLLM_MAX_MODEL_LEN=262144 sm start qwen   # full context
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
      "")
        echo "Need model: qwen|deepseek|deepseek-ds4"
        usage
        exit 1
        ;;
      *) echo "Need model: qwen|deepseek|deepseek-ds4"; usage; exit 1 ;;
    esac
    ;;
  pull|download|dl)
    case "${arg}" in
      qwen|q) pull_qwen ;;
      deepseek-ds4|ds4|deepseek-gguf) pull_deepseek_ds4 ;;
      deepseek|ds|deep) pull_deepseek_exl3 ;;
      all|a) pull_all ;;
      "") echo "Need model: qwen|deepseek|deepseek-ds4|all"; usage; exit 1 ;;
      *) echo "Need model: qwen|deepseek|deepseek-ds4|all"; usage; exit 1 ;;
    esac
    ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
