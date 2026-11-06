# Skill: spark-inference

Operate DGX Spark **DeepSeek-only** inference on the local network.

## Commands

- `sm status|start|stop|pull` (`deepseek` / `deepseek-ds4`)
- `sudo apply-gb10-clock-cap.sh` (300–2200 MHz)
- `sudo spark-headless on && sudo reboot` (no GUI → more unified RAM)
- From LAN laptop: `./scripts/spark-ops/update-spark.sh`, `spark-llms`

## Port

DeepSeek → **8001**

Recipe: https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark

## Boot / power-loss

- Firmware AC restore → power on
- Clock cap systemd unit
- Last `sm start` → `spark-boot.sh` @reboot
- Headless: `sudo spark-headless on` (do not purge desktop packages)

## Docs

- Runbook: `docs/runbooks/spark-inference.md`
- Guide: `spark/README.md`
