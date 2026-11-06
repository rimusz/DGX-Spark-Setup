# AGENTS.md — DGX Spark DeepSeek setup

Spark is **DeepSeek inference only**, **LAN-only** access.

## Role

- Host: NVIDIA DGX Spark (GB10 / aarch64)
- Model: DeepSeek V4 Flash EXL3 on **:8001** (`sm start deepseek`)
- Backup: `sm start deepseek-ds4` (ds4 GGUF)
- Recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark)
- **No Tailscale**, **no Qwen/Ling**

## Install

```bash
git clone https://github.com/rimusz/DGX-Spark-Setup.git ~/DGX-Spark-Setup
cd ~/DGX-Spark-Setup
bash scripts/spark-ops/setup-spark.sh
sudo ~/bin/spark-privileged-bootstrap.sh
sm pull deepseek && sm start deepseek
```

## Stability

- `sudo apply-gb10-clock-cap.sh` → **300–2200 MHz**
- `sudo spark-headless on && sudo reboot` → no GUI, more unified RAM
- Firmware: restore AC → power on
- Last `sm start` → `spark-boot.sh` @reboot

## Skills

| Tool | Path |
|------|------|
| Cursor | `.cursor/skills/spark-inference/` |
| Claude Code | `.claude/skills/spark-inference/` |
| Agents | `.agents/skills/spark-inference/` |
| Codex | `.codex/skills/spark-inference/` |

## Safety

- No agents / messaging bots on Spark.
- Do not commit `HF_TOKEN` or publish real LAN IPs.
