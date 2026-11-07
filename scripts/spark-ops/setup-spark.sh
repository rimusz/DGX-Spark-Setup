#!/usr/bin/env bash
# Install DeepSeek Spark helpers into ~/bin and ensure PATH.
# Also installs Hugging Face `hf` CLI → ~/.local/bin (model downloads / HF cache).
# Run ON the DGX Spark as the inference user.
#
# Usage:
#   ./scripts/spark-ops/setup-spark.sh
#   ssh ${SPARK_HOST:-user@spark} 'cd ~/DGX-Spark-Setup && git pull && bash scripts/spark-ops/setup-spark.sh'
#   ./scripts/spark-ops/update-spark.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
SPARK_DIR="${REPO_ROOT}/spark"
BIN_SRC="${SPARK_DIR}/bin"
DEST_BIN="${HOME}/bin"
DEST_SRC="${HOME}/src"

if [ -z "${REPO_ROOT:-}" ] || [ ! -d "${BIN_SRC}" ]; then
  echo "ERROR: ${BIN_SRC} not found — run scripts/spark-ops/setup-spark.sh from a full checkout."
  exit 1
fi

echo "========================================"
echo "DGX Spark helpers (Qwen + DeepSeek) → ${DEST_BIN}"
echo "========================================"

mkdir -p "${DEST_BIN}" "${DEST_SRC}" "${HOME}/logs" \
  "${HOME}/.cache/huggingface" "${HOME}/.cache/triton"

install -m 755 "${BIN_SRC}/ensure-hf-cli.sh" "${DEST_BIN}/"
install -m 755 "${BIN_SRC}/ensure-spark-dashboard.sh" "${DEST_BIN}/"
install -m 755 "${BIN_SRC}/spark-privileged-bootstrap.sh" "${DEST_BIN}/"
install -m 755 "${BIN_SRC}/spark-model.sh" "${DEST_BIN}/spark-model"
install -m 755 "${BIN_SRC}/spark-model.sh" "${DEST_BIN}/spark-model.sh"
install -m 755 "${BIN_SRC}/vllm-qwen35-docker.sh" "${DEST_BIN}/vllm-qwen35-docker.sh"
install -m 755 "${BIN_SRC}/vllm-docker-ops.sh" "${DEST_BIN}/vllm-docker-ops.sh"
install -m 755 "${BIN_SRC}/download-qwen35-nvfp4.sh" "${DEST_BIN}/download-qwen35-nvfp4.sh"
ln -sfn "${DEST_BIN}/vllm-docker-ops.sh" "${DEST_BIN}/vo"
install -m 755 "${BIN_SRC}/ds4-boot.sh" "${DEST_BIN}/ds4-boot.sh"
install -m 755 "${BIN_SRC}/spark-boot.sh" "${DEST_BIN}/spark-boot.sh"
install -m 755 "${BIN_SRC}/spark-headless.sh" "${DEST_BIN}/spark-headless.sh"
ln -sfn "${DEST_BIN}/spark-headless.sh" "${DEST_BIN}/spark-headless"
install -m 755 "${BIN_SRC}/apply-gb10-clock-cap.sh" "${DEST_BIN}/apply-gb10-clock-cap.sh"
install -m 755 "${BIN_SRC}/revert-gb10-clock-cap.sh" "${DEST_BIN}/revert-gb10-clock-cap.sh"
ln -sfn "${DEST_BIN}/spark-model" "${DEST_BIN}/sm"

_llms="$(pai_script spark-llms.sh || true)"
if [ -n "${_llms}" ]; then
  install -m 755 "${_llms}" "${DEST_BIN}/spark-llms.sh"
fi
_dash="$(pai_script spark-dash.sh || true)"
if [ -n "${_dash}" ]; then
  install -m 755 "${_dash}" "${DEST_BIN}/spark-dash.sh"
  ln -sfn "${DEST_BIN}/spark-dash.sh" "${DEST_BIN}/spark-dash"
fi

ensure_bashrc_path_ssh_safe() {
  python3 - <<'PY'
from pathlib import Path
import re

p = Path.home() / ".bashrc"
text = p.read_text() if p.exists() else "# ~/.bashrc\n"
marker = "# === DGX-Spark-Setup PATH (ssh-safe) ==="
block = f"""{marker}
if [ -d "$HOME/bin" ]; then
  PATH="$HOME/bin:$PATH"
fi
if [ -d "$HOME/.local/bin" ]; then
  PATH="$HOME/.local/bin:$PATH"
fi
export PATH
"""

text = re.sub(
    r"\n?# === DGX-Spark-Setup PATH \(ssh-safe\) ===\n"
    r"if \[ -d \"\$HOME/bin\" \]; then\n"
    r"  PATH=\"\$HOME/bin:\$PATH\"\n"
    r"fi\n"
    r"if \[ -d \"\$HOME/\.local/bin\" \]; then\n"
    r"  PATH=\"\$HOME/\.local/bin:\$PATH\"\n"
    r"fi\n"
    r"export PATH\n",
    "\n",
    text,
)
text = re.sub(
    r"\n# User binaries[^\n]*\n"
    r"if \[ -d \"\$HOME/bin\" \]; then\n"
    r"  PATH=\"\$HOME/bin:\$PATH\"\n"
    r"fi\n"
    r"if \[ -d \"\$HOME/\.local/bin\" \]; then\n"
    r"  PATH=\"\$HOME/\.local/bin:\$PATH\"\n"
    r"fi\n"
    r"export PATH\n",
    "\n",
    text,
)

lines = text.splitlines(True)
insert_at = 0
for i, ln in enumerate(lines):
    if "not running interactively" in ln or ln.startswith("case $-"):
        insert_at = i
        break
    insert_at = i + 1

new = "".join(lines[:insert_at]) + "\n" + block + "\n" + "".join(lines[insert_at:])
p.write_text(new)
print(f"Ensured ssh-safe PATH in {p} (before interactive early-return)")
PY
}

ensure_profile_path() {
  local file="${HOME}/.profile"
  if [ ! -f "${file}" ]; then
    return 0
  fi
  if grep -qE 'HOME/bin|\$HOME/bin' "${file}" 2>/dev/null; then
    echo "PATH already references ~/bin in ${file}"
    return 0
  fi
  cat >> "${file}" << 'EOF'

# User binaries (Spark helpers)
if [ -d "$HOME/bin" ]; then
  PATH="$HOME/bin:$PATH"
fi
if [ -d "$HOME/.local/bin" ]; then
  PATH="$HOME/.local/bin:$PATH"
fi
export PATH
EOF
  echo "Appended ~/bin to ${file}"
}

ensure_bashrc_path_ssh_safe
ensure_profile_path

ensure_docker_alias() {
  local file="$1"
  if [ ! -f "${file}" ]; then
    return 0
  fi
  if grep -q 'DGX-Spark-Setup host aliases' "${file}" 2>/dev/null; then
    return 0
  fi
  cat >> "${file}" << 'EOF'

# === DGX-Spark-Setup host aliases ===
alias d=docker
EOF
  echo "Appended docker alias (d) to ${file}"
}
ensure_docker_alias "${HOME}/.bashrc"

export PATH="${DEST_BIN}:${HOME}/.local/bin:${PATH}"

ensure_spark_reboot_cron() {
  python3 - <<'PY'
from pathlib import Path
import os
import subprocess

home = Path.home()
boot = home / "bin" / "spark-boot.sh"
line = f"@reboot sleep 30 && {boot}"
marker = "# === DGX-Spark-Setup spark-boot ==="
try:
    current = subprocess.check_output(["crontab", "-l"], text=True, stderr=subprocess.DEVNULL)
except subprocess.CalledProcessError:
    current = ""
skip = ("ds4-boot", "spark-boot", "DGX-Spark-Setup ds4-boot", "DGX-Spark-Setup spark-boot")
lines = [ln for ln in current.splitlines() if not any(s in ln for s in skip)]
if not boot.is_file():
    text = "\n".join(lines).rstrip() + ("\n" if lines else "")
else:
    text = "\n".join(lines).rstrip()
    if text:
        text += "\n"
    text += f"{marker}\n{line}\n"
tmp = Path(os.environ.get("TMPDIR", "/tmp")) / f"spark-cron-{os.getpid()}"
tmp.write_text(text)
subprocess.check_call(["crontab", str(tmp)])
tmp.unlink(missing_ok=True)
print(f"crontab: {line}" if boot.is_file() else "crontab: spark-boot.sh missing — skip")
PY
  local live=""
  if curl -sf --connect-timeout 2 http://127.0.0.1:8000/v1/models >/dev/null 2>&1 \
    || docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'vllm-qwen35'; then
    live=qwen
  elif curl -sf --connect-timeout 2 http://127.0.0.1:8001/v1/models >/dev/null 2>&1 \
    || pgrep -x ds4-server >/dev/null 2>&1; then
    if pgrep -x ds4-server >/dev/null 2>&1; then
      live=deepseek-ds4
    else
      live=deepseek
    fi
  fi
  if [ -n "${live}" ]; then
    mkdir -p "${HOME}/.config/spark-models"
    printf '%s\n' "${live}" > "${HOME}/.config/spark-models/autostart"
    echo "Armed reboot autostart: ${live}"
  fi
}
echo ""
echo "→ Reboot autostart (crontab @reboot → spark-boot.sh, last sm start)…"
ensure_spark_reboot_cron

echo ""
echo "→ Hugging Face CLI (hf) for model weight downloads…"
bash "${DEST_BIN}/ensure-hf-cli.sh" || true

echo ""
echo "→ DGX Spark Dashboard (host metrics :8787)…"
bash "${DEST_BIN}/ensure-spark-dashboard.sh" || true

echo ""
echo "Installed:"
ls -1 "${DEST_BIN}"/ensure-* "${DEST_BIN}"/spark-* "${DEST_BIN}"/sm \
  "${DEST_BIN}"/vllm-* "${DEST_BIN}"/download-qwen* "${DEST_BIN}"/vo \
  "${DEST_BIN}"/*clock* 2>/dev/null || true
echo "hf: $(command -v hf 2>/dev/null || echo 'not on PATH — source ~/.bashrc or: ensure-hf-cli.sh')"
echo ""
echo "Docker group: $(id -nG | tr ' ' '\n' | grep -qx docker && echo OK || echo 'MISSING — sudo usermod -aG docker $USER')"
echo ""
echo "Next:"
echo "  source ~/.bashrc"
echo "  sudo ~/bin/spark-privileged-bootstrap.sh   # docker + GB10 2200 MHz clock cap"
echo "  sm pull qwen && sm start qwen              # :8000 data analysis (6 seqs / 131k)"
echo "  sm pull deepseek && sm start deepseek      # :8001 EXL3"
echo "  sm start deepseek-ds4                      # optional GGUF backup"
echo "  sm status"
echo ""
echo "LAN OpenAI bases:"
echo "  Qwen:     http://spark-local:8000/v1"
echo "  DeepSeek: http://spark-local:8001/v1"
echo "Headless (free RAM): sudo spark-headless on && sudo reboot"
echo "Power-loss: firmware AC→power-on + gb10-clock-cap + crontab @reboot spark-boot.sh"
