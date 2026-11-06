---
name: spark-inference
description: >
  Operate DGX Spark as LLM inference only (sm/vo, Qwen/DeepSeek/Ling exclusive
  switcher). Use when Spark is down, switching models, probing :8000/:8001/:8002,
  or updating Spark helpers (update-spark.sh / setup-spark.sh).
---

# DGX Spark inference ops

## Goal

Keep **Spark** serving one OpenAI-compatible model at a time.

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
ensure-spark-dashboard.sh --upgrade   # host metrics UI :8787
```

DeepSeek recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) (`sm pull deepseek` → `~/code/dsv4-exl3`).

## From a laptop

```bash
export SPARK_HOST=user@spark
./scripts/spark-ops/update-spark.sh
./scripts/spark-ops/update-spark.sh --images
spark-llms
curl -sf http://spark:8000/v1/models
curl -sf http://spark:8787/api/health
```

## Client base URLs

| Slot | Port | Example |
|------|------|---------|
| qwen | 8000 | `http://spark:8000/v1` |
| deepseek | 8001 | `http://spark:8001/v1` |
| ling | 8002 | `http://spark:8002/v1` |

API key: unused / `not-needed`. Model id: from `GET …/v1/models`. Prefer MagicDNS `spark` or a LAN hosts entry.

## Safety

- No agents or messaging bots on Spark.
- One heavy model at a time on GB10.
- Do not paste HF tokens or Tailscale auth keys into chat.
- `hf` is for Hub download/cache only — not a model server.

## Related

- Skill card: `docs/skills/spark-inference.md`
- Runbook: `docs/runbooks/spark-inference.md`
- Full guide: `spark/README.md`
- Contract: `AGENTS.md`
