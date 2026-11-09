# Skill: spark-inference

Operate DGX Spark **Qwen + DeepSeek + Colibri** inference on the local network (one at a time).

## Commands

- `sm status|start|stop|pull` (`qwen` / `deepseek` / `deepseek-ds4` / `colibri`)
- `sudo apply-gb10-clock-cap.sh` (300–2200 MHz)
- `sudo spark-headless on && sudo reboot` (no GUI → more unified RAM)
- From LAN laptop: `./scripts/spark-ops/update-spark.sh`, `spark-llms`

## Ports / profiles

| Model | Port | Default | Use |
|-------|------|---------|-----|
| Qwen | **8000** | 6 seqs / 131k | **Data analysis** (tools + reasoning) |
| DeepSeek | **8001** | 6 seqs / 256k / K5 | Long-context reasoning (shared GPU/KV) |
| Colibri | **8003** | qwen36-35b CUDA | Opt-in Colibri engine |

DeepSeek recipe: https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark  
Colibri: https://github.com/JustVugg/colibri (`sm pull colibri` — not in `sm pull all`)

## Boot / power-loss

- Firmware AC restore → power on
- Clock cap systemd unit
- Last `sm start` → `spark-boot.sh` @reboot
- Headless: `sudo spark-headless on` (do not purge desktop packages)

## Docs

- Runbook: `docs/runbooks/spark-inference.md`
- Guide: `spark/README.md`
