#!/usr/bin/env bash
# Cap GB10 GPU clocks to reduce log-less hard power-offs under sustained load.
# Default: 300–2200 MHz. Persists across reboot via systemd.
#
# Usage (on Spark):
#   sudo ~/bin/apply-gb10-clock-cap.sh          # 2200 MHz ceiling
#   sudo ~/bin/apply-gb10-clock-cap.sh 2100     # optional lower ceiling
#
# Community prior art: https://github.com/tonyd2wild/DGX-Spark-Hard-Poweroff-Fix
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with: sudo $0 ${*:-}"
  exit 1
fi

MAX="${1:-2200}"
case "${MAX}" in
  ''|*[!0-9]*) echo "MAX MHz must be an integer (got: ${MAX})" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SRC=""
for cand in \
  "${SCRIPT_DIR}/../systemd/gb10-clock-cap.service" \
  "${HOME}/DGX-Spark-Setup/spark/systemd/gb10-clock-cap.service" \
  "/home/${SUDO_USER:-}/DGX-Spark-Setup/spark/systemd/gb10-clock-cap.service"
do
  if [ -f "${cand}" ]; then
    UNIT_SRC="${cand}"
    break
  fi
done
if [ -z "${UNIT_SRC}" ]; then
  echo "ERROR: gb10-clock-cap.service not found next to this script" >&2
  exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found" >&2
  exit 1
fi

echo "→ nvidia-smi -lgc 300,${MAX}"
nvidia-smi -lgc "300,${MAX}"

echo "→ install /etc/systemd/system/gb10-clock-cap.service (boot persistence)"
sed "s/300,2200/300,${MAX}/" "${UNIT_SRC}" >/etc/systemd/system/gb10-clock-cap.service
systemctl daemon-reload
systemctl enable --now gb10-clock-cap.service

echo "Done. Verify under load: nvidia-smi -q -d CLOCK | head -40"
echo "Revert: sudo revert-gb10-clock-cap.sh"
