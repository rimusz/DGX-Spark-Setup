#!/usr/bin/env bash
# One-time root bootstrap on DGX Spark (apt, Tailscale, docker group, optional systemd).
# Run: sudo ./spark-privileged-bootstrap.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with: sudo $0"
  exit 1
fi

SPARK_USER="${SUDO_USER:-${SPARK_USER:?set SPARK_USER}}"
export DEBIAN_FRONTEND=noninteractive

echo "=== [1/5] apt update + essentials ==="
apt-get update
apt-get -y full-upgrade
apt-get -y install \
  build-essential cmake ninja-build git curl wget ca-certificates \
  pkg-config python3-dev python3-venv \
  libssl-dev zlib1g-dev libffi-dev \
  htop jq tmux unzip rsync
apt-get -y autoremove --purge || true

echo "=== [2/5] Tailscale ==="
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "=== [3/5] docker group for ${SPARK_USER} ==="
if getent group docker >/dev/null 2>&1; then
  usermod -aG docker "${SPARK_USER}" || true
  echo "Added ${SPARK_USER} to docker (re-login / newgrp docker)"
fi

echo "=== [4/5] systemd unit (native path, optional; leave disabled) ==="
UNIT_SRC="/home/${SPARK_USER}/src/vllm-qwen35.service"
UNIT_REPO="/home/${SPARK_USER}/DGX-Spark-Setup/spark/systemd/vllm-qwen35.service"
if [ -f "${UNIT_SRC}" ] || [ -f "${UNIT_REPO}" ]; then
  SRC="${UNIT_SRC}"
  [ -f "${SRC}" ] || SRC="${UNIT_REPO}"
  install -m 644 "${SRC}" /etc/systemd/system/vllm-qwen35.service
  systemctl daemon-reload
  # Docker is production — do not enable native unit on boot
  systemctl disable --now vllm-qwen35.service 2>/dev/null || true
  echo "Installed vllm-qwen35.service (disabled; Docker is production)"
fi

echo "=== [5/5] ufw port 8000 if active ==="
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 8000/tcp comment "vLLM OpenAI" || true
fi

echo
echo "NEXT:"
echo "  sudo tailscale up --accept-dns=false --hostname=spark"
echo "  sudo tailscale set --operator=${SPARK_USER}"
echo "  # as ${SPARK_USER}:"
echo "  newgrp docker   # or re-login"
echo "  bash ~/DGX-Spark-Setup/setup-spark.sh   # helpers + hf CLI → ~/bin + ~/.local/bin"
echo "  sm pull qwen && sm start qwen            # or: ~/bin/download-qwen35-nvfp4.sh"
