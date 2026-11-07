#!/usr/bin/env bash
# One-time root bootstrap on DGX Spark (apt, docker group, GB10 clock cap).
# LAN-only by design — does not install Tailscale. DeepSeek-only stack.
# Run: sudo ./spark-privileged-bootstrap.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with: sudo $0"
  exit 1
fi

SPARK_USER="${SUDO_USER:-${SPARK_USER:?set SPARK_USER}}"
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_HINT=""
if REPO_HINT="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd)"; then
  :
else
  REPO_HINT=""
fi

echo "=== [1/5] apt update + essentials ==="
apt-get update
apt-get -y full-upgrade
apt-get -y install \
  build-essential cmake ninja-build git curl wget ca-certificates \
  pkg-config python3-dev python3-venv \
  libssl-dev zlib1g-dev libffi-dev \
  htop jq tmux unzip rsync
apt-get -y autoremove --purge || true

echo "=== [2/5] docker group + enable Docker on boot ==="
if getent group docker >/dev/null 2>&1; then
  usermod -aG docker "${SPARK_USER}" || true
  echo "Added ${SPARK_USER} to docker (re-login / newgrp docker)"
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now docker 2>/dev/null || true
fi

echo "=== [3/5] GB10 GPU clock cap (300–2200 MHz, survives reboot) ==="
APPLY=""
for cand in \
  "${SCRIPT_DIR}/apply-gb10-clock-cap.sh" \
  "/home/${SPARK_USER}/bin/apply-gb10-clock-cap.sh" \
  "${REPO_HINT}/spark/bin/apply-gb10-clock-cap.sh"
do
  if [ -x "${cand}" ]; then
    APPLY="${cand}"
    break
  fi
done
if [ -n "${APPLY}" ]; then
  bash "${APPLY}" 2200
else
  echo "WARN: apply-gb10-clock-cap.sh missing — run after setup-spark.sh:"
  echo "  sudo ~/bin/apply-gb10-clock-cap.sh"
fi

echo "=== [4/5] ufw allow DeepSeek + dashboard if firewall active (LAN) ==="
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 8001/tcp comment "Spark DeepSeek OpenAI" || true
  ufw allow 8787/tcp comment "Spark dashboard" || true
fi

echo "=== [5/5] firmware reminder: power-on after AC restore ==="
echo "In DGX Spark BIOS / BMC / NVIDIA DGX Dashboard, set \"Restore AC Power Loss\""
echo "(or equivalent) to Power On so the host comes back after outages."
echo "Software then: Docker enable + gb10-clock-cap + crontab @reboot → spark-boot.sh."

echo
echo "NEXT (as ${SPARK_USER}):"
echo "  newgrp docker   # or re-login"
echo "  bash ~/DGX-Spark-Setup/scripts/spark-ops/setup-spark.sh"
echo "  sm pull deepseek && sm start deepseek"
echo "  sm pull colibri && sm start colibri   # optional :8003"
echo "  sudo ~/bin/spark-headless on && sudo reboot   # optional: no GUI, more unified RAM"
echo
echo "Access is LAN-only (no Tailscale). From a LAN client:"
echo "  http://spark-local:8001/v1"
echo "  http://YOUR_LAN_IP:8001/v1"
