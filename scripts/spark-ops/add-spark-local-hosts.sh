#!/bin/bash
# add-spark-local-hosts.sh — map spark-local → Spark LAN IPv4 in /etc/hosts
# Run on Mac Mini (needs admin once). Idempotent.
#
#   ./add-spark-local-hosts.sh
#   SPARK_LAN_IP=YOUR_LAN_IP SPARK_LOCAL_NAME=spark-local ./add-spark-local-hosts.sh
#
# Note: Clients under launchd still need Privacy → Local Network → node to use
# http://spark-local:800N/v1; until then prefer http://spark:800N/v1 (Tailscale).
set -euo pipefail

SPARK_LAN_IP="${SPARK_LAN_IP:?set SPARK_LAN_IP to your Spark LAN IPv4}"
SPARK_LOCAL_NAME="${SPARK_LOCAL_NAME:-spark-local}"
LINE="${SPARK_LAN_IP} ${SPARK_LOCAL_NAME}"

if grep -qE "[[:space:]]${SPARK_LOCAL_NAME}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
  echo "Already present:"
  grep -E "[[:space:]]${SPARK_LOCAL_NAME}([[:space:]]|$)" /etc/hosts
  exit 0
fi

echo "Adding: ${LINE}"
if osascript -e "do shell script \"grep -qE '[[:space:]]${SPARK_LOCAL_NAME}([[:space:]]|\$)' /etc/hosts || echo '${LINE}' >> /etc/hosts\" with administrator privileges" 2>/dev/null; then
  echo "Added via admin prompt"
elif echo "${LINE}" | sudo tee -a /etc/hosts >/dev/null; then
  echo "Added via sudo"
else
  echo "Failed — run: sudo sh -c 'echo \"${LINE}\" >> /etc/hosts'" >&2
  exit 1
fi

dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true
echo "Resolve:"
dscacheutil -q host -a name "${SPARK_LOCAL_NAME}" || true
ping -c 1 -W 1000 "${SPARK_LOCAL_NAME}" || true
curl -sf --connect-timeout 2 "http://${SPARK_LOCAL_NAME}:8001/v1/models" | head -c 100 || true
echo
