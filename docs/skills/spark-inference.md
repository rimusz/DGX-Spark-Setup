# Skill: spark-inference

Operate DGX Spark as exclusive LLM inference (`sm` / `vo`).

## Commands

- On Spark: `sm status|start|stop|pull`, `vo …`, `hf --version`
- From laptop: `./scripts/spark-ops/update-spark.sh`, `spark-llms`

## Ports

| Model | Port |
|-------|------|
| qwen | 8000 |
| deepseek (EXL3) | 8001 |
| ling | 8002 |

DeepSeek recipe: https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark

## Docs

- Runbook: `docs/runbooks/spark-inference.md`
- Guide: `spark/README.md`
