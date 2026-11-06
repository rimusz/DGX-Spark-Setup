# DGX Spark Setup

Public tooling to run **OpenAI-compatible LLM inference** on one **NVIDIA DGX Spark** (GB10), with an exclusive model switcher (`sm`).

**Access model:** **LAN only** (no Tailscale). Clients on the same local network use `spark-local` / LAN IP.

**Hard power-off mitigation:** GB10 GPU clock cap **300–2200 MHz** (systemd, survives reboot).

**DeepSeek V4 Flash EXL3** (8 concurrent seqs / 256k / `:8001`):

→ [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark)

Also includes helpers for **Qwen** (vLLM `:8000`) and **Ling** (SGLang `:8002`). Run **one** heavy model at a time.

---

## Layout

```text
spark/                 # host helpers (sm, boot, clock-cap, hf, dashboards, model wrappers)
scripts/spark-ops/     # setup / update / probe from Spark or a laptop
scripts/lib/paths.sh   # repo-root lookup
docs/runbooks/         # spark-inference runbook
docs/skills/           # skill card
.cursor/skills/        # Cursor skill
.claude/skills/        # Claude Code skill
.agents/skills/        # generic agents skill
.codex/skills/         # Codex skill
AGENTS.md              # short operating contract
```

---

## Quick start (on Spark)

```bash
git clone https://github.com/rimusz/DGX-Spark-Setup.git ~/DGX-Spark-Setup
cd ~/DGX-Spark-Setup

bash scripts/spark-ops/setup-spark.sh
sudo ~/bin/spark-privileged-bootstrap.sh   # apt, docker, GB10 2200 MHz clock cap
newgrp docker

sm pull deepseek
sm start deepseek
sm status
```

From a laptop **on the same LAN**:

```bash
export SPARK_HOST=user@YOUR_LAN_IP
export SPARK_LAN_IP=192.168.x.x
./scripts/spark-ops/add-spark-local-hosts.sh   # once on the laptop/Mini
./scripts/spark-ops/update-spark.sh
```

---

## Client URLs (LAN)

| Situation | Base URL example |
|-----------|------------------|
| On Spark | `http://127.0.0.1:800N/v1` |
| LAN hosts entry | `http://spark-local:800N/v1` |
| LAN IP | `http://YOUR_LAN_IP:800N/v1` |

Ports: Qwen **8000**, DeepSeek **8001**, Ling **8002**. Optional dashboard: `:8787` (bound to loopback + LAN).

---

## Power loss / reboot

1. **Firmware:** set “Restore AC Power Loss” / power-on after AC restore (BIOS or DGX Dashboard).
2. **Clock cap:** `gb10-clock-cap.service` → `nvidia-smi -lgc 300,2200` on every boot.
3. **Last model:** `sm start …` arms crontab `@reboot` → `spark-boot.sh`.
4. **Docker:** enabled on boot; Qwen uses `--restart unless-stopped` when that container remains.

---

## Agent skills

Bundled **`spark-inference`** skill:

- `.cursor/skills/spark-inference/SKILL.md`
- `.claude/skills/spark-inference/SKILL.md`
- `.agents/skills/spark-inference/SKILL.md`
- `.codex/skills/spark-inference/SKILL.md`

---

## License

MIT for scripts and docs in this repository. Model weights, runtime images, and upstream recipes keep their own licenses.
