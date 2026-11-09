#!/usr/bin/env bash
# Install / refresh Spark token-usage dashboard (companion to host metrics :8787).
# Scrapes local LLM OpenAI ports' /metrics; UI + API on :8788.
# Binds 0.0.0.0 so loopback + LAN can reach it (same pattern as inference ports).
#
# Usage (on Spark):
#   ensure-spark-token-dashboard.sh           # install / start if needed
#   ensure-spark-token-dashboard.sh --upgrade # reinstall files + restart
set -euo pipefail

export PATH="${HOME}/bin:${HOME}/.local/bin:/usr/local/bin:${PATH}"

PORT="${TOKEN_DASH_PORT:-8788}"
LLM_PORTS="${TOKEN_DASH_LLM_PORTS:-8000,8001,8002,8003}"
INSTALL_DIR="${TOKEN_DASH_DIR:-${HOME}/.local/share/spark-token-dashboard}"
UNIT_NAME="spark-token-dashboard.service"
UNIT_PATH="${HOME}/.config/systemd/user/${UNIT_NAME}"
FORCE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve app sources (repo checkout preferred; ~/src copy from setup-spark as fallback).
SRC_DIR=""
for candidate in \
  "${SCRIPT_DIR}/../token-dashboard" \
  "${REPO_ROOT:-}/spark/token-dashboard" \
  "${HOME}/DGX-Spark-Setup/spark/token-dashboard" \
  "${HOME}/src/spark-token-dashboard"
do
  if [ -n "${candidate}" ] && [ -f "${candidate}/server.py" ]; then
    SRC_DIR="$(cd "${candidate}" && pwd)"
    break
  fi
done

case "${1:-}" in
  -u|--upgrade|--update) FORCE=1 ;;
  -h|--help)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [ -z "${SRC_DIR:-}" ] || [ ! -f "${SRC_DIR}/server.py" ]; then
  echo "ERROR: spark/token-dashboard source not found next to this script." >&2
  exit 1
fi

dash_lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

token_dash_healthy() {
  curl -sf --connect-timeout 2 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1
}

install_files() {
  mkdir -p "${INSTALL_DIR}/static" "${HOME}/.config/systemd/user" "${HOME}/logs"
  install -m 755 "${SRC_DIR}/server.py" "${INSTALL_DIR}/server.py"
  cp -a "${SRC_DIR}/static/." "${INSTALL_DIR}/static/"
  local bind="0.0.0.0"
  cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=Spark token usage dashboard (:${PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
Environment=TOKEN_DASH_PORT=${PORT}
Environment=TOKEN_DASH_LLM_PORTS=${LLM_PORTS}
Environment=TOKEN_DASH_DB=${INSTALL_DIR}/ledger.sqlite
Environment=SYSTEM_DASHBOARD_PORT=8787
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/server.py --host ${bind} --port ${PORT} --ports ${LLM_PORTS} --db ${INSTALL_DIR}/ledger.sqlite
Restart=on-failure
RestartSec=3
StandardOutput=append:${HOME}/logs/spark-token-dashboard.log
StandardError=append:${HOME}/logs/spark-token-dashboard.log

[Install]
WantedBy=default.target
EOF
}

enable_linger() {
  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$(id -un)" 2>/dev/null || true
  fi
}

restart_unit() {
  systemctl --user daemon-reload
  systemctl --user enable --now "${UNIT_NAME}"
  systemctl --user restart "${UNIT_NAME}"
}

if [ "${FORCE}" -eq 0 ] && token_dash_healthy && [ -f "${UNIT_PATH}" ] && [ -f "${INSTALL_DIR}/server.py" ]; then
  echo "Spark token dashboard: already healthy on :${PORT}"
  lan="$(dash_lan_ip || true)"
  echo "  loopback  http://127.0.0.1:${PORT}"
  [ -n "${lan}" ] && echo "  LAN       http://${lan}:${PORT}"
  exit 0
fi

echo "→ Install Spark token dashboard → ${INSTALL_DIR}"
install_files
enable_linger
restart_unit

ok=0
for _ in $(seq 1 20); do
  if token_dash_healthy; then
    ok=1
    break
  fi
  sleep 0.5
done

if [ "${ok}" -eq 1 ]; then
  echo "✅ Spark token dashboard http://127.0.0.1:${PORT}  (LAN :${PORT})"
  echo "   System dashboard link targets :8787"
else
  echo "⚠️  Token dashboard started but /api/health not ready — check: journalctl --user -u ${UNIT_NAME} -n 50" >&2
  echo "   log: ${HOME}/logs/spark-token-dashboard.log" >&2
  exit 1
fi
