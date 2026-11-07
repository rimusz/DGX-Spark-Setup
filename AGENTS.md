# AGENTS.md â DGX Spark setup

Spark is **LLM inference only**, **LAN-only** access. Run **one** model at a time.

## Role

- Host: NVIDIA DGX Spark (GB10 / aarch64)
- **Qwen** on **:8000** â data analysis default (`sm start qwen`, 6 seqs / 131k, tools)
- **DeepSeek** on **:8001** â EXL3 (`sm start deepseek`, 8 seqs / 256k / K5)
- Backup: `sm start deepseek-ds4` (ds4 GGUF)
- DeepSeek recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark)
- **No Tailscale**, **no Ling** (not in this public tree)

## Install

```bash
git clone https://github.com/rimusz/DGX-Spark-Setup.git ~/DGX-Spark-Setup
cd ~/DGX-Spark-Setup
bash scripts/spark-ops/setup-spark.sh
sudo ~/bin/spark-privileged-bootstrap.sh
sm pull qwen && sm start qwen          # data analysis
# or: sm pull deepseek && sm start deepseek
```

## Stability

- `sudo apply-gb10-clock-cap.sh` â **300â2200 MHz**
- `sudo spark-headless on && sudo reboot` â no GUI, more unified RAM
- Firmware: restore AC â power on
- Last `sm start` â `spark-boot.sh` @reboot

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
