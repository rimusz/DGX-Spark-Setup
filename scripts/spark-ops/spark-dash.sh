#!/bin/bash
# spark-dash.sh — open the Spark host dashboard (:8787).
# Tries LAN first (spark-local / YOUR_LAN_IP), then Tailscale (spark).
set -euo pipefail

PORT="${DASHBOARD_PORT:-8787}"
SPARK_LOCAL="${SPARK_LOCAL:-spark-local}"
SPARK_LAN_IP="${SPARK_LAN_IP:?set SPARK_LAN_IP to your Spark LAN IPv4}"
SPARK_TS="${SPARK_TS:-spark}"

url=""
via=""
for host in "${SPARK_LOCAL}" "${SPARK_LAN_IP}" "${SPARK_TS}"; do
  if curl -sf --connect-timeout 2 "http://${host}:${PORT}/api/health" >/dev/null 2>&1; then
    url="http://${host}:${PORT}"
    case "${host}" in
      spark|*.ts.net|100.*) via="Tailscale" ;;
      *) via="LAN" ;;
    esac
    break
  fi
done

if [ -z "${url}" ]; then
  url="http://${SPARK_TS}:${PORT}"
  via="unverified"
  echo "Dashboard health not reachable; opening ${url} anyway." >&2
fi

echo "Spark dash  ${url}  (${via})"

if command -v open >/dev/null 2>&1; then
  open "${url}"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "${url}" >/dev/null 2>&1 || true
else
  echo "${url}"
fi
