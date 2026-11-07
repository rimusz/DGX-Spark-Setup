---
name: spark-inference
description: >
  Operate DGX Spark Qwen+DeepSeek inference (sm, Qwen :8000 data analysis
  6/131k, DeepSeek :8001 EXL3, LAN-only, GB10 2200 MHz clock cap). Use when
  switching models, pulling/starting, probing :8000/:8001, or updating helpers.
---

# DGX Spark inference ops

## Goal

Keep **one** of Qwen or DeepSeek serving over the **local network**.

## Commands (on Spark)

```bash
sm status
sm pull qwen
sm start qwen          # :8000 vLLM — data analysis (6 seqs / 131k, tools)
sm pull deepseek
sm start deepseek      # :8001 EXL3, 8 seqs / 256k / K5
sm start deepseek-ds4  # :8001 ds4 GGUF backup
sm stop
sudo apply-gb10-clock-cap.sh
systemctl status gb10-clock-cap
sudo spark-headless on && sudo reboot  # optional: no GUI
ensure-spark-dashboard.sh --upgrade
```

DeepSeek recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark).

Qwen full 262k: `VLLM_MAX_MODEL_LEN=262144 VLLM_MAX_NUM_SEQS=4 sm start qwen`

## From a LAN laptop

```bash
export SPARK_HOST=user@YOUR_LAN_IP
export SPARK_LAN_IP=YOUR_LAN_IP
./scripts/spark-ops/update-spark.sh
spark-llms
curl -sf http://spark-local:8000/v1/models
curl -sf http://spark-local:8001/v1/models
```

## Client URLs

- Qwen: `http://spark-local:8000/v1` — **prefer for data analysis**
- DeepSeek: `http://spark-local:8001/v1`

## Power loss

Firmware AC restore + clock-cap unit + last `sm start` → `spark-boot.sh`.
Optional: `sudo spark-headless on` (no GUI, more unified RAM).

## Safety

- One model at a time on this host.
- Do not paste HF tokens into chat.
