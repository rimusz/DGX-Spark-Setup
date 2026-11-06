---
name: spark-inference
description: >
  Operate DGX Spark as LLM inference only (sm/vo, Qwen/DeepSeek/Ling exclusive
  switcher, LAN-only). Use when Spark is down, switching models, probing
  :8000/:8001/:8002, applying the GB10 2200 MHz clock cap, or updating helpers.
---

# DGX Spark inference ops

## Goal

Keep **Spark** serving one OpenAI-compatible model at a time on the **local network**.

## Commands (on Spark)

```bash
sm status
sm start qwen          # :8000 vLLM
sm start deepseek      # :8001 EXL3, 8 seqs / 256k / K5
sm start deepseek-ds4  # :8001 ds4 GGUF backup
sm start ling          # :8002
sm stop
sm pull qwen|deepseek|ling|all
vo status|logs|restart   # Qwen Docker only
hf --version
ensure-hf-cli.sh --upgrade
ensure-spark-dashboard.sh --upgrade   # host metrics UI :8787 (LAN bind)
sudo apply-gb10-clock-cap.sh          # 300–2200 MHz; survives reboot
systemctl status gb10-clock-cap
```

DeepSeek recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) (`sm pull deepseek` → `~/code/dsv4-exl3`).

## From a LAN laptop

```bash
export SPARK_HOST=user@YOUR_LAN_IP
export SPARK_LAN_IP=YOUR_LAN_IP
./scripts/spark-ops/update-spark.sh
./scripts/spark-ops/update-spark.sh --images
spark-llms
curl -sf http://spark-local:8000/v1/models
curl -sf http://spark-local:8787/api/health
```

## Client base URLs (LAN only)

| Slot | Port | Example |
|------|------|---------|
| qwen | 8000 | `http://spark-local:8000/v1` |
| deepseek | 8001 | `http://spark-local:8001/v1` |
| ling | 8002 | `http://spark-local:8002/v1` |

API key: unused / `not-needed`. Model id: from `GET …/v1/models`. Prefer `spark-local` hosts entry or raw LAN IP. No Tailscale.

## Power loss

- Firmware power-on after AC restore
- `gb10-clock-cap.service` + last `sm start` → `spark-boot.sh`

## Safety

- No agents or messaging bots on Spark.
- One heavy model at a time on GB10.
- Do not paste HF tokens into chat.
- `hf` is for Hub download/cache only — not a model server.

## Related

- Skill card: `docs/skills/spark-inference.md`
- Runbook: `docs/runbooks/spark-inference.md`
- Full guide: `spark/README.md`
- Contract: `AGENTS.md`
