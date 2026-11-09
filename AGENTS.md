# AGENTS.md — DGX Spark setup

Spark is **LLM inference only**, **LAN-only** access. Run **one** model at a time.

## Role

- Host: NVIDIA DGX Spark (GB10 / aarch64)
- **Qwen** on **:8000** — data analysis default (`sm start qwen`, 6 seqs / 131k, tools)
- **DeepSeek** on **:8001** — EXL3 (`sm start deepseek`, 6 seqs / 256k / K5; shared GPU/KV)
- Backup: `sm start deepseek-ds4` (ds4 GGUF)
- **Colibri** on **:8003** — opt-in (`sm pull colibri && sm start colibri`, qwen36-35b CUDA)
- DeepSeek recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark)
- Colibri: [JustVugg/colibri](https://github.com/JustVugg/colibri)
- **No Tailscale**, **no Ling** (not in this public tree)

## Install

```bash
git clone https://github.com/rimusz/DGX-Spark-Setup.git ~/DGX-Spark-Setup
cd ~/DGX-Spark-Setup
bash scripts/spark-ops/setup-spark.sh
sudo ~/bin/spark-privileged-bootstrap.sh
sm pull qwen && sm start qwen          # data analysis
# or: sm pull deepseek && sm start deepseek
# or: sm pull colibri && sm start colibri   # :8003 opt-in
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
