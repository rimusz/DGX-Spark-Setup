# AGENTS.md — DGX Spark setup

Public operating notes for this repository. Spark is **LLM inference only**, **LAN-only** access.

## Role

- Host: NVIDIA DGX Spark (GB10 / aarch64)
- Exclusive model switcher: `sm` / `spark-model` (one heavy model at a time)
- DeepSeek EXL3 recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) (`sm pull deepseek` → `~/code/dsv4-exl3`)
- **No Tailscale** — clients reach Spark over the local network only

## Ports

| Model | Command | Port |
|-------|---------|------|
| Qwen | `sm start qwen` | 8000 |
| DeepSeek EXL3 | `sm start deepseek` | 8001 |
| DeepSeek GGUF backup | `sm start deepseek-ds4` | 8001 |
| Ling | `sm start ling` | 8002 |

## Install (on Spark)

```bash
git clone https://github.com/rimusz/DGX-Spark-Setup.git ~/DGX-Spark-Setup
cd ~/DGX-Spark-Setup
bash scripts/spark-ops/setup-spark.sh
sudo ~/bin/spark-privileged-bootstrap.sh   # docker + GB10 clock cap 2200 MHz
newgrp docker
sm pull deepseek && sm start deepseek
```

From a LAN laptop:

```bash
export SPARK_HOST=user@YOUR_LAN_IP
export SPARK_LAN_IP=YOUR_LAN_IP
./scripts/spark-ops/update-spark.sh
```

## Stability (power / thermal)

- Cap GPU clocks: `sudo apply-gb10-clock-cap.sh` → **300–2200 MHz** (systemd persists across reboot)
- Firmware: restore AC → power on
- Last `sm start` returns after reboot via `spark-boot.sh`

## Skills (agents)

| Tool | Path |
|------|------|
| Cursor | `.cursor/skills/spark-inference/` |
| Claude Code | `.claude/skills/spark-inference/` |
| Agents | `.agents/skills/spark-inference/` |
| Codex | `.codex/skills/spark-inference/` |

Docs: `docs/runbooks/spark-inference.md`, `docs/skills/spark-inference.md`, `spark/README.md`.

## Safety

- No agents / messaging bots on Spark.
- Do not commit `HF_TOKEN` or `~/.hf_env`.
- Do not publish real LAN IPs in public forks.
