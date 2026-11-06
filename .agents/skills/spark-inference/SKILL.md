---
name: spark-inference
description: >
  Operate DGX Spark DeepSeek-only inference (sm, :8001 EXL3, LAN-only,
  GB10 2200 MHz clock cap). Use when DeepSeek is down, pulling/starting,
  probing :8001, or updating Spark helpers.
---

# DGX Spark DeepSeek ops

## Goal

Keep **DeepSeek V4 Flash** serving on **:8001** over the **local network**.

## Commands (on Spark)

```bash
sm status
sm pull deepseek
sm start deepseek      # :8001 EXL3, 8 seqs / 256k / K5
sm start deepseek-ds4  # :8001 ds4 GGUF backup
sm stop
sudo apply-gb10-clock-cap.sh
systemctl status gb10-clock-cap
sudo spark-headless on && sudo reboot  # optional: no GUI
ensure-spark-dashboard.sh --upgrade
```

Recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark).

## From a LAN laptop

```bash
export SPARK_HOST=user@YOUR_LAN_IP
export SPARK_LAN_IP=YOUR_LAN_IP
./scripts/spark-ops/update-spark.sh
spark-llms
curl -sf http://spark-local:8001/v1/models
```

## Client URL

`http://spark-local:8001/v1` — no Tailscale, no Qwen/Ling.

## Power loss

Firmware AC restore + clock-cap unit + last `sm start` → `spark-boot.sh`.
Optional: `sudo spark-headless on` (no GUI, more unified RAM).

## Safety

- DeepSeek only on this host.
- Do not paste HF tokens into chat.
