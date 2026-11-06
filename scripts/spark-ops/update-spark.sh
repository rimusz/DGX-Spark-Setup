#!/bin/bash
# update-spark.sh — refresh DGX Spark inference helpers (and optionally model images).
# Re-runs setup-spark.sh (~/bin helpers + hf CLI + DGX Spark Dashboard).
# Run from MacBook / Mini (SSH + rsync), or ON Spark with --local.
#
# Usage:
#   ./scripts/spark-ops/update-spark.sh                    # rsync repo bits → spark, re-run setup-spark.sh
#   ./scripts/spark-ops/update-spark.sh --local            # already on Spark (git pull if clone, then setup)
#   ./scripts/spark-ops/update-spark.sh --host ${SPARK_HOST:-user@spark}
#   ./scripts/spark-ops/update-spark.sh --images           # also sm pull all (images/weights; does not start models)
#   ./scripts/spark-ops/update-spark.sh --images qwen      # only pull named model(s): qwen|deepseek|ling|all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
SETUP_SPARK="$(pai_script setup-spark.sh)"
SPARK_HOST="${SPARK_HOST:-user@spark}"
# Path on Spark relative to the remote user's home (never use local $HOME — macOS → /Users/...)
SPARK_REPO_REMOTE="${SPARK_REPO_REMOTE:-DGX-Spark-Setup}"
LOCAL=0
PULL_IMAGES=""
DO_RSYNC=1

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --local) LOCAL=1; shift ;;
    --host) SPARK_HOST="${2:?}"; shift 2 ;;
    --no-rsync) DO_RSYNC=0; shift ;;
    --images)
      if [ $# -ge 2 ] && [[ "$2" != -* ]]; then
        PULL_IMAGES="$2"
        shift 2
      else
        PULL_IMAGES="all"
        shift
      fi
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
  esac
done

if [ -z "${REPO_ROOT:-}" ] || [ ! -f "${SETUP_SPARK}" ] || [ ! -d "${REPO_ROOT}/spark/bin" ]; then
  echo "ERROR: need a full checkout (scripts/spark-ops/setup-spark.sh + spark/bin)."
  exit 1
fi

remote_update() {
  # $1 = repo path relative to remote $HOME (or absolute if it starts with /)
  # shellcheck disable=SC2029
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
    "${SPARK_HOST}" bash -s -- "${SPARK_REPO_REMOTE}" "${PULL_IMAGES}" <<'REMOTE'
set -euo pipefail
REL="${1:-DGX-Spark-Setup}"
case "${REL}" in
  /*) REPO="${REL}" ;;
  *)  REPO="${HOME}/${REL}" ;;
esac
PULL="${2:-}"
export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

echo "========================================"
echo "Updating Spark helpers on $(hostname -s)…"
echo "========================================"

if [ -d "${REPO}/.git" ]; then
  echo "→ git pull --ff-only in ${REPO}"
  git -C "${REPO}" pull --ff-only || {
    echo "⚠️  git pull failed (local changes?); continuing with current tree"
  }
fi

SETUP=""
if [ -f "${REPO}/scripts/spark-ops/setup-spark.sh" ]; then
  SETUP="${REPO}/scripts/spark-ops/setup-spark.sh"
elif [ -f "${REPO}/setup-spark.sh" ]; then
  SETUP="${REPO}/setup-spark.sh"
else
  echo "ERROR: setup-spark.sh missing in ${REPO} — sync the repo first"
  exit 1
fi

echo "→ setup-spark.sh (install helpers → ~/bin + hf CLI → ~/.local/bin)"
bash "${SETUP}"

echo "→ ensure-spark-dashboard.sh --upgrade"
if [ -x "$HOME/bin/ensure-spark-dashboard.sh" ]; then
  "$HOME/bin/ensure-spark-dashboard.sh" --upgrade || true
else
  echo "⚠️  ensure-spark-dashboard.sh missing — skip dashboard upgrade"
fi

if [ -n "${PULL}" ]; then
  if command -v sm &>/dev/null || [ -x "$HOME/bin/sm" ]; then
    echo "→ sm pull ${PULL} (images/weights only; not starting models)"
    sm pull "${PULL}" || true
  else
    echo "⚠️  sm not on PATH — skip image pull"
  fi
fi

echo ""
echo "Status:"
sm status 2>/dev/null || "$HOME/bin/sm" status 2>/dev/null || true
echo ""
echo "✅ Spark update finished on $(hostname -s)"
REMOTE
}

local_update() {
  export PATH="${HOME}/bin:${HOME}/.local/bin:/usr/local/bin:${PATH}"
  REPO="${SPARK_REPO_REMOTE}"
  if [ -n "${REPO_ROOT:-}" ]; then
    REPO="${REPO_ROOT}"
  elif [ -f "${SCRIPT_DIR}/setup-spark.sh" ]; then
    REPO="${SCRIPT_DIR}"
  fi

  echo "========================================"
  echo "Updating Spark helpers (local)…"
  echo "========================================"

  if [ -d "${REPO}/.git" ]; then
    echo "→ git pull --ff-only in ${REPO}"
    git -C "${REPO}" pull --ff-only || {
      echo "⚠️  git pull failed; continuing with current tree"
    }
  fi

  echo "→ setup-spark.sh"
  if [ -f "${REPO}/scripts/spark-ops/setup-spark.sh" ]; then
    bash "${REPO}/scripts/spark-ops/setup-spark.sh"
  else
    bash "${REPO}/setup-spark.sh"
  fi

  echo "→ ensure-spark-dashboard.sh --upgrade"
  if [ -x "${HOME}/bin/ensure-spark-dashboard.sh" ]; then
    "${HOME}/bin/ensure-spark-dashboard.sh" --upgrade || true
  fi

  if [ -n "${PULL_IMAGES}" ]; then
    echo "→ sm pull ${PULL_IMAGES}"
    sm pull "${PULL_IMAGES}" || true
  fi

  echo ""
  sm status 2>/dev/null || true
  echo ""
  echo "✅ Spark update finished (local)"
}

if [ "${LOCAL}" -eq 1 ]; then
  local_update
  exit 0
fi

echo "========================================"
echo "Update Spark via ${SPARK_HOST}"
echo "========================================"

if ! ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
  "${SPARK_HOST}" 'echo ok' &>/dev/null; then
  # Optional LAN/mDNS fallback (set SPARK_HOST_FALLBACK=user@spark.local)
  if [ -n "${SPARK_HOST_FALLBACK:-}" ] \
    && ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "${SPARK_HOST_FALLBACK}" 'echo ok' &>/dev/null; then
    SPARK_HOST="${SPARK_HOST_FALLBACK}"
    echo "→ Fallback host: ${SPARK_HOST}"
  else
    echo "ERROR: cannot SSH to ${SPARK_HOST} (BatchMode). Try: ssh-spark / ssh ${SPARK_HOST}"
    echo "       Or set SPARK_HOST_FALLBACK=user@spark.local"
    exit 1
  fi
fi

if [ "${DO_RSYNC}" -eq 1 ]; then
  echo "→ rsync scripts/spark-ops + spark/ → ${SPARK_HOST}:${SPARK_REPO_REMOTE}/"
  # Relative path → remote home (rsync/ssh treat host:foo as ~/foo)
  ssh "${SPARK_HOST}" "mkdir -p '${SPARK_REPO_REMOTE}/spark' '${SPARK_REPO_REMOTE}/scripts/spark-ops' '${SPARK_REPO_REMOTE}/scripts/lib'"
  rsync -az \
    "${SETUP_SPARK}" \
    "${SPARK_HOST}:${SPARK_REPO_REMOTE}/scripts/spark-ops/setup-spark.sh"
  rsync -az \
    "${SCRIPT_DIR}/../lib/paths.sh" \
    "${SPARK_HOST}:${SPARK_REPO_REMOTE}/scripts/lib/paths.sh"
  rsync -az \
    "${SCRIPT_DIR}/spark-llms.sh" \
    "${SCRIPT_DIR}/spark-dash.sh" \
    "${SPARK_HOST}:${SPARK_REPO_REMOTE}/scripts/spark-ops/"
  rsync -az --delete \
    --exclude 'experimental/.vllm' \
    --exclude 'experimental/.tiktoken_cache' \
    --exclude '.git' \
    "${REPO_ROOT}/spark/" \
    "${SPARK_HOST}:${SPARK_REPO_REMOTE}/spark/"
fi

remote_update
echo ""
echo "From this machine: curl -sf http://spark:8000/v1/models | head -c 120; echo"
echo "  (or: sm status on Spark)"
