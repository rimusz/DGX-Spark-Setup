#!/bin/bash
# spark-dash.sh — open the Spark host dashboard (:8787) over LAN only.
# Tries spark-local, then SPARK_LAN_IP.
set -euo pipefail

PORT="${DASHBOARD_PORT:-8787}"
SPARK_LOCAL="${SPARK_LOCAL:-spark-local}"
SPARK_LAN_IP="${SPARK_LAN_IP:?set SPARK_LAN_IP to your Spark LAN IPv4}"

url=""
via=""
for host in "${SPARK_LOCAL}" "${SPARK_LAN_IP}"; do
  if curl -sf --connect-timeout 2 "http://${host}:${PORT}/api/health" >/dev/null 2>&1; then
    url="http://${host}:${PORT}"
    via="LAN"
    break
  fi
done

if [ -z "${url}" ]; then
  url="http://${SPARK_LOCAL}:${PORT}"
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
