#!/usr/bin/env bash
# Remove GB10 GPU clock cap and its systemd unit.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with: sudo $0"
  exit 1
fi

nvidia-smi -rgc 2>/dev/null || true
systemctl disable --now gb10-clock-cap.service 2>/dev/null || true
rm -f /etc/systemd/system/gb10-clock-cap.service
systemctl daemon-reload
echo "Clock cap reverted (GPU default clocks)."
