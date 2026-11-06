#!/usr/bin/env bash
#
# start.sh — GGUF backup (Entrpi/ds4-on-spark). Default slot is EXL3:
#   sm start deepseek       → start-exl3.sh
#   sm start deepseek-ds4   → this file
#
# Heads-up: this repo does NOT use vLLM. ds4-on-spark is the ds4-server
# (DwarfStar 4, C/CUDA) engine, which exposes the same OpenAI-compatible /v1
# API that `vllm serve` does. vLLM cannot read this repo's asymmetric GGUF,
# so the repo ships its own server; ds4-serve is that server's launcher.
#
# This is a thin, idempotent wrapper over the repo's official installer:
#   * first run : verify host, clone+build the pinned fork, download the
#     ~110 GiB GGUF set, smoke-test, install ds4-serve (no server start).
#   * always    : start ds4-serve with --host 0.0.0.0 so LAN
#     clients can reach it (upstream installer defaults to 127.0.0.1).
#
# Locations (installer defaults, override via env):
#   source  -> ~/code/ds4   ($DS4_SRC_DIR)
#   weights -> ~/gguf       ($DS4_GGUF_DIR)
#   log     -> ~/ds4-server.log
#
# Usage:
#   ./start.sh                        # stack on :8888 (or PORT=), ctx default
#   PORT=8001 HOST=0.0.0.0 ./start.sh # Spark switcher defaults
#   CTX=524288 ./start.sh
#   ./start.sh --no-dspark            # passed through to installer
#
# Env:
#   PORT   listen port (default 8888; spark-model uses 8001)
#   HOST   bind address (default 0.0.0.0 for LAN)
#   CTX    context size (default 524288 / 512k; Entrpi installer default)
#   KV_DISK_DIR          disk KV prefix-cache dir (default ~/ds4-kv; empty/`0`/off disables)
#   KV_DISK_SPACE_MB     disk budget (default 8192)
#   KV_CACHE_MIN_TOKENS / KV_CACHE_COLD_MAX_TOKENS / …  optional ds4 overrides
#
# To force a clean restart: pkill -x ds4-server; ./start.sh
#
# Reboot autostart is owned by sm (spark-model): ~/.config/spark-models/autostart.
set -euo pipefail

REPO=https://github.com/Entrpi/ds4-on-spark
PORT="${PORT:-8888}"
CTX="${CTX:-524288}"
HOST="${HOST:-0.0.0.0}"
LOG="${HOME}/ds4-server.log"
READY_URL="http://127.0.0.1:${PORT}/v1/models"
# Cold load of ~110 GiB can exceed upstream installer's 120s wait
READY_TIMEOUT_S="${READY_TIMEOUT_S:-900}"

# Disk KV = ds4's prefix-cache for agents that resend long stable prompts
# (analogous to vLLM --enable-prefix-caching; different mechanism).
KV_DISK_DIR="${KV_DISK_DIR-${HOME}/ds4-kv}"
KV_DISK_SPACE_MB="${KV_DISK_SPACE_MB:-8192}"

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }

kv_disk_enabled() {
  case "${KV_DISK_DIR}" in
    ""|0|false|FALSE|off|OFF|no|NO) return 1 ;;
    *) return 0 ;;
  esac
}

# Extra ds4-serve args (disk KV + optional overrides)
ds4_extra_args() {
  local -a args=()
  if kv_disk_enabled; then
    mkdir -p "${KV_DISK_DIR}"
    args+=(--kv-disk-dir "${KV_DISK_DIR}" --kv-disk-space-mb "${KV_DISK_SPACE_MB}")
    [ -n "${KV_CACHE_MIN_TOKENS:-}" ] && args+=(--kv-cache-min-tokens "${KV_CACHE_MIN_TOKENS}")
    [ -n "${KV_CACHE_COLD_MAX_TOKENS:-}" ] && args+=(--kv-cache-cold-max-tokens "${KV_CACHE_COLD_MAX_TOKENS}")
    [ -n "${KV_CACHE_CONTINUED_INTERVAL_TOKENS:-}" ] && args+=(--kv-cache-continued-interval-tokens "${KV_CACHE_CONTINUED_INTERVAL_TOKENS}")
  fi
  printf '%s\n' "${args[@]}"
}

listening_loopback_only() {
  ss -tln 2>/dev/null | grep -qE "127\\.0\\.0\\.1:${PORT}\\b" \
    && ! ss -tln 2>/dev/null | grep -qE "(\\*|0\\.0\\.0\\.0|\\[::\\]):${PORT}\\b"
}

wait_ready() {
  local i=0
  local steps=$((READY_TIMEOUT_S / 2))
  [ "${steps}" -lt 1 ] && steps=1
  echo "Waiting for ${READY_URL} (up to ${READY_TIMEOUT_S}s)..."
  while [ "${i}" -lt "${steps}" ]; do
    if curl -sf "${READY_URL}" >/dev/null 2>&1; then
      echo "ds4-server is up on http://${HOST}:${PORT} (local probe ${READY_URL})"
      curl -s "${READY_URL}" | python3 -m json.tool 2>/dev/null || true
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  echo "!!! Not reachable within ${READY_TIMEOUT_S}s — check ${LOG}" >&2
  return 1
}

start_ds4_serve() {
  if ! command -v ds4-serve >/dev/null 2>&1; then
    echo "error: ds4-serve not on PATH (expected ~/.local/bin after installer)" >&2
    exit 1
  fi
  local -a extra=()
  # Read null-safe from helper lines
  while IFS= read -r line; do
    [ -n "$line" ] && extra+=("$line")
  done < <(ds4_extra_args)

  echo "==> Starting ds4-serve --host ${HOST} --port ${PORT} -c ${CTX}"
  if kv_disk_enabled; then
    echo "    Disk KV prefix-cache: ${KV_DISK_DIR} (${KV_DISK_SPACE_MB} MiB)"
  else
    echo "    Disk KV prefix-cache: disabled (KV_DISK_DIR empty/off)"
  fi
  # Append so installer/build messages from earlier steps remain
  nohup ds4-serve --port "${PORT}" -c "${CTX}" --host "${HOST}" \
    "${extra[@]}" \
    >> "${LOG}" 2>&1 < /dev/null &
  disown || true
  wait_ready
  mkdir -p "${HOME}/.config/ds4"
  touch "${HOME}/.config/ds4/autostart"
}

# Already serving?
if curl -sf "${READY_URL}" >/dev/null 2>&1; then
  if [ "${HOST}" != "127.0.0.1" ] && [ "${HOST}" != "localhost" ] && listening_loopback_only; then
    echo "Serving on 127.0.0.1:${PORT} but HOST=${HOST} — one-time rebind (reloads weights; can take several minutes)..."
    pkill -x ds4-server 2>/dev/null || true
    sleep 2
    start_ds4_serve
    exit $?
  fi
  echo "Already serving on :${PORT} — nothing to do. (Restart with: pkill -x ds4-server; ./start.sh)"
  mkdir -p "${HOME}/.config/ds4"
  touch "${HOME}/.config/ds4/autostart"
  curl -s "${READY_URL}" | python3 -m json.tool 2>/dev/null || true
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "==> Fetching installer from $REPO ..."
curl -fsSL "$REPO/raw/main/install.sh" -o "$tmp"

# Install/build/weights only — do NOT use installer --start (it binds 127.0.0.1
# and does not accept --host). We launch ds4-serve ourselves below.
echo "==> Running installer (no --start; port ${PORT}, ctx ${CTX}) ..."
bash "$tmp" --port "${PORT}" --ctx "${CTX}" "$@"

echo
start_ds4_serve
