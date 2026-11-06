# AGENTS.md — DGX Spark setup

Public operating notes for this repository. Spark is **LLM inference only**.

## Role

- Host: NVIDIA DGX Spark (GB10 / aarch64)
- Exclusive model switcher: `sm` / `spark-model` (one heavy model at a time)
- DeepSeek EXL3 recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) (`sm pull deepseek` → `~/code/dsv4-exl3`)

## Ports

| Model | Command | Port |
|-------|---------|------|
| Qwen | `sm start qwen` | 8000 |
| DeepSeek EXL3 | `sm start deepseek` | 8001 |
| DeepSeek GGUF backup | `sm start deepseek-ds4` | 8001 |
| Ling | `sm start ling` | 8002 |

## Install (on Spark)

```bash
git clone https://github.com/rimusz/DGX-Spark-Setup.git ~/DGX-Spark-Setup
cd ~/DGX-Spark-Setup
sudo ./spark/bin/spark-privileged-bootstrap.sh
sudo tailscale up --accept-dns=false --hostname=spark   # optional
newgrp docker
bash scripts/spark-ops/setup-spark.sh
sm pull deepseek && sm start deepseek
```

From a laptop:

```bash
export SPARK_HOST=user@spark
./scripts/spark-ops/update-spark.sh
```

## Skills (agents)

| Tool | Path |
|------|------|
| Cursor | `.cursor/skills/spark-inference/` |
| Claude Code | `.claude/skills/spark-inference/` |
| Agents | `.agents/skills/spark-inference/` |
| Codex | `.codex/skills/spark-inference/` |

Docs: `docs/runbooks/spark-inference.md`, `docs/skills/spark-inference.md`, `spark/README.md`.

## Safety

- No agents / messaging bots on Spark.
- Do not commit `HF_TOKEN`, `~/.hf_env`, or Tailscale auth keys.
