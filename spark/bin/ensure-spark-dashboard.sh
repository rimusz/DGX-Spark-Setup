#!/usr/bin/env bash
# Install or refresh DGX Spark Dashboard (singhangadin) on this host.
# Official installer: checksummed release bundle + GHCR ARM64 image.
# Bind loopback + LAN + Tailscale only (not 0.0.0.0). Health: :8787/api/health
#
# Usage (on Spark):
#   ensure-spark-dashboard.sh           # install if missing / recreate if bind changed
#   ensure-spark-dashboard.sh --upgrade # pull latest release + recreate
set -euo pipefail

export PATH="${HOME}/bin:${HOME}/.local/bin:/usr/local/bin:${PATH}"

INSTALLER_URL="${DGX_DASHBOARD_INSTALLER_URL:-https://raw.githubusercontent.com/singhangadin/DGX-Spark-Dashboard/main/install.sh}"
INSTALL_DIR="${DGX_DASHBOARD_DIR:-${HOME}/DGX-Spark-Dashboard}"
PORT="${DASHBOARD_PORT:-8787}"
FORCE=0

case "${1:-}" in
  -u|--upgrade|--update) FORCE=1 ;;
  -h|--help)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

dash_lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

dash_ts_ip() {
  tailscale ip -4 2>/dev/null | head -1 || true
}

ensure_bind() {
  local env_file="${INSTALL_DIR}/.env"
  local lan ts bind cur
  if [ ! -f "${env_file}" ]; then
    return 1
  fi
  lan="$(dash_lan_ip || true)"
  ts="$(dash_ts_ip || true)"
  bind="127.0.0.1"
  if [ -n "${lan}" ] && [ "${lan}" != "127.0.0.1" ]; then
    bind="${bind},${lan}"
  fi
  if [ -n "${ts}" ]; then
    bind="${bind},${ts}"
  fi
  cur="$(sed -n 's/^DASHBOARD_BIND_ADDRESS=//p' "${env_file}" | tail -n 1)"
  if [ "${cur}" = "${bind}" ]; then
    return 1
  fi
  if grep -q '^DASHBOARD_BIND_ADDRESS=' "${env_file}"; then
    sed -i "s|^DASHBOARD_BIND_ADDRESS=.*|DASHBOARD_BIND_ADDRESS=${bind}|" "${env_file}"
  else
    printf '\nDASHBOARD_BIND_ADDRESS=%s\n' "${bind}" >> "${env_file}"
  fi
  echo "→ Dashboard bind: ${bind}"
  return 0
}

run_official_installer() {
  if [ -x "${INSTALL_DIR}/install.sh" ]; then
    echo "→ ${INSTALL_DIR}/install.sh"
    (cd "${INSTALL_DIR}" && sh ./install.sh)
    return 0
  fi
  echo "→ First-time DGX Spark Dashboard → ${INSTALL_DIR}"
  curl -fsSL "${INSTALLER_URL}" | DGX_DASHBOARD_DIR="${INSTALL_DIR}" sh
}

dashboard_healthy() {
  curl -sf --connect-timeout 2 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1
}

if [ "${FORCE}" -eq 0 ] && dashboard_healthy && [ -f "${INSTALL_DIR}/.env" ]; then
  if ensure_bind; then
    echo "→ Bind changed — recreating dashboard"
    run_official_installer
  else
    echo "DGX Spark Dashboard: already healthy on :${PORT}"
    exit 0
  fi
else
  run_official_installer
  ensure_bind && run_official_installer || true
fi

if dashboard_healthy; then
  echo "✅ DGX Spark Dashboard http://127.0.0.1:${PORT}  (LAN/Tailscale :${PORT})"
else
  echo "⚠️  Dashboard started but /api/health not ready yet — check: (cd ${INSTALL_DIR} && docker compose ps)" >&2
  exit 1
fi
