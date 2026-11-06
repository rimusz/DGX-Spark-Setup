#!/usr/bin/env bash
# After reboot, start whichever model last `sm start` armed.
# File: ~/.config/spark-models/autostart  (qwen|deepseek|deepseek-ds4|ling)
# Legacy: ~/.config/ds4/autostart → deepseek (EXL3 default)
# Does NOT run the DeepSeek installer. Cron: @reboot sleep 30 && ~/bin/spark-boot.sh
set -euo pipefail

export PATH="${HOME}/bin:${HOME}/.local/bin:${PATH}"

LOG="${HOME}/logs/spark-boot.log"
FLAG="${HOME}/.config/spark-models/autostart"
LEGACY="${HOME}/.config/ds4/autostart"
mkdir -p "$(dirname "${LOG}")"

model=""
if [ -f "${FLAG}" ]; then
  model="$(tr -d '[:space:]' < "${FLAG}")"
elif [ -f "${LEGACY}" ]; then
  model="deepseek"
fi

case "${model}" in
  qwen|deepseek|deepseek-ds4|ling) ;;
  *) exit 0 ;;
esac

echo "[$(date)] spark-boot: last model=${model}" >> "${LOG}"

url_ok() {
  curl -sf --connect-timeout 2 "http://127.0.0.1:${1}/v1/models" >/dev/null 2>&1
}

boot_qwen() {
  url_ok 8000 && exit 0
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx vllm-qwen35; then
    exit 0
  fi
  echo "[$(date)] spark-boot: starting qwen" >> "${LOG}"
  if [ -x "${HOME}/bin/vllm-qwen35-docker.sh" ]; then
    PORT=8000 "${HOME}/bin/vllm-qwen35-docker.sh" >> "${LOG}" 2>&1
  else
    echo "[$(date)] spark-boot: vllm-qwen35-docker.sh missing" >> "${LOG}"
    exit 1
  fi
}

boot_deepseek() {
  local port="${PORT:-8001}"
  local dir="${EXL3_DIR:-${HOME}/code/dsv4-exl3}"
  if url_ok "${port}"; then
    exit 0
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'deepseek-v4-flash'; then
    exit 0
  fi
  if [ ! -x "${dir}/start.sh" ]; then
    echo "[$(date)] spark-boot: ${dir}/start.sh missing" >> "${LOG}"
    exit 1
  fi
  echo "[$(date)] spark-boot: starting EXL3 DeepSeek :${port} seqs=${MAX_NUM_SEQS:-8} len=${MAX_MODEL_LEN:-256000} k=${DSPARK_TOKENS:-5}" >> "${LOG}"
  local wrapper="${HOME}/DGX-Spark-Setup/spark/models/deepseek/start-exl3.sh"
  if [ -x "${wrapper}" ]; then
    PORT="${port}" AUTO_DOWNLOAD=0 ABLATE=0 EXL3_DIR="${dir}" \
      MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}" MAX_MODEL_LEN="${MAX_MODEL_LEN:-256000}" \
      DSPARK_TOKENS="${DSPARK_TOKENS:-5}" \
      bash "${wrapper}" --no-wait >> "${LOG}" 2>&1 || {
        echo "[$(date)] spark-boot: start-exl3.sh failed" >> "${LOG}"
        exit 1
      }
  else
    (
      cd "${dir}"
      SERVING_PORT="${port}" AUTO_DOWNLOAD=0 ABLATE=0 \
        MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}" MAX_MODEL_LEN="${MAX_MODEL_LEN:-256000}" \
        DSPARK_TOKENS="${DSPARK_TOKENS:-5}" \
        ./start.sh --no-wait
    ) >> "${LOG}" 2>&1 || {
      echo "[$(date)] spark-boot: EXL3 start.sh failed" >> "${LOG}"
      exit 1
    }
  fi
}

boot_deepseek_ds4() {
  local host="${HOST:-0.0.0.0}" port="${PORT:-8001}" ctx="${CTX:-524288}"
  local kv_dir="${KV_DISK_DIR-${HOME}/ds4-kv}" kv_mb="${KV_DISK_SPACE_MB:-8192}"
  local extra=()
  if url_ok "${port}"; then
    exit 0
  fi
  if pgrep -x ds4-server >/dev/null 2>&1; then
    exit 0
  fi
  if ! command -v ds4-serve >/dev/null 2>&1; then
    echo "[$(date)] spark-boot: ds4-serve not on PATH" >> "${LOG}"
    exit 1
  fi
  case "${kv_dir}" in
    ""|0|false|FALSE|off|OFF|no|NO) ;;
    *)
      mkdir -p "${kv_dir}"
      extra+=(--kv-disk-dir "${kv_dir}" --kv-disk-space-mb "${kv_mb}")
      ;;
  esac
  echo "[$(date)] spark-boot: starting ds4-serve :${port} -c ${ctx}" >> "${LOG}"
  nohup ds4-serve --port "${port}" -c "${ctx}" --host "${host}" \
    "${extra[@]}" \
    >> "${HOME}/ds4-server.log" 2>&1 < /dev/null &
  disown || true
}

boot_ling() {
  url_ok 8002 && exit 0
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ling-3.0-flash-int4; then
    exit 0
  fi
  local repo="${SPARK_REPO_DIR:-${HOME}/DGX-Spark-Setup/spark}"
  local start="${repo}/models/ling/start.sh"
  if [ ! -f "${start}" ]; then
    echo "[$(date)] spark-boot: ${start} missing" >> "${LOG}"
    exit 1
  fi
  echo "[$(date)] spark-boot: starting ling" >> "${LOG}"
  mkdir -p "${HOME}/.spark-models/ling"
  cd "${HOME}/.spark-models/ling"
  PORT=8002 \
    CTX="${CTX:-262144}" \
    MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.70}" \
    MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-4}" \
    MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-16}" \
    ENABLE_NEXTN="${ENABLE_NEXTN:-1}" \
    DOCKER_MEMORY="${DOCKER_MEMORY:-100g}" \
    HF_HOME="${HF_HOME:-${HOME}/.cache/huggingface}" \
    bash "${start}" >> "${LOG}" 2>&1
}

case "${model}" in
  qwen) boot_qwen ;;
  deepseek) boot_deepseek ;;
  deepseek-ds4) boot_deepseek_ds4 ;;
  ling) boot_ling ;;
esac
