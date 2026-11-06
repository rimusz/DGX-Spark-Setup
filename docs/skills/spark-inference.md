# Skill: spark-inference

Operate DGX Spark as exclusive LLM inference (`sm` / `vo`) on the **local network only**.

## Commands

- On Spark: `sm status|start|stop|pull`, `vo …`, `hf --version`
- Stability: `sudo apply-gb10-clock-cap.sh` (300–2200 MHz), `systemctl status gb10-clock-cap`
- From LAN laptop: `./scripts/spark-ops/update-spark.sh`, `spark-llms`

## Ports

| Model | Port |
|-------|------|
| qwen | 8000 |
| deepseek (EXL3) | 8001 |
| ling | 8002 |

DeepSeek recipe: https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark

## Boot / power-loss

- Firmware AC restore → power on
- Clock cap systemd unit
- Last `sm start` → `spark-boot.sh` @reboot

## Docs

- Runbook: `docs/runbooks/spark-inference.md`
- Guide: `spark/README.md`
