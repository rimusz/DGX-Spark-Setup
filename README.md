# DGX Spark Setup

Public tooling to run **OpenAI-compatible LLM inference** on one **NVIDIA DGX Spark** (GB10), with an exclusive model switcher (`sm`).

**DeepSeek V4 Flash EXL3** (8 concurrent seqs / 256k / `:8001`):

→ [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark)

Also includes helpers for **Qwen** (vLLM `:8000`) and **Ling** (SGLang `:8002`). Run **one** heavy model at a time.

---

## Layout

```text
spark/                 # host helpers (sm, boot, hf, dashboards, model wrappers)
scripts/spark-ops/     # setup / update / probe from Spark or a laptop
scripts/lib/paths.sh   # repo-root lookup
docs/runbooks/         # spark-inference runbook
docs/skills/           # skill card
.cursor/skills/        # Cursor skill
.claude/skills/        # Claude Code skill
.agents/skills/        # generic agents skill
.codex/skills/         # Codex skill
AGENTS.md              # short operating contract
```

---

## Quick start (on Spark)

```bash
git clone https://github.com/rimusz/DGX-Spark-Setup.git ~/DGX-Spark-Setup
cd ~/DGX-Spark-Setup

sudo ./spark/bin/spark-privileged-bootstrap.sh
sudo tailscale up --accept-dns=false --hostname=spark   # optional
sudo tailscale set --operator="$USER"                   # optional
newgrp docker

bash scripts/spark-ops/setup-spark.sh
source ~/.bashrc

sm pull deepseek
sm start deepseek
sm status
```

From a laptop:

```bash
export SPARK_HOST=user@spark
export SPARK_LAN_IP=192.168.x.x    # optional, for spark-local hosts helper
./scripts/spark-ops/update-spark.sh
```

---

## Client URLs

| Situation | Base URL example |
|-----------|------------------|
| On Spark | `http://127.0.0.1:800N/v1` |
| MagicDNS | `http://spark:800N/v1` |
| LAN hosts entry | `http://spark-local:800N/v1` |

Ports: Qwen **8000**, DeepSeek **8001**, Ling **8002**. Optional dashboard: `:8787`.

---

## Agent skills

Bundled **`spark-inference`** skill:

- `.cursor/skills/spark-inference/SKILL.md`
- `.claude/skills/spark-inference/SKILL.md`
- `.agents/skills/spark-inference/SKILL.md`
- `.codex/skills/spark-inference/SKILL.md`

---

## License

MIT for scripts and docs in this repository. Model weights, runtime images, and upstream recipes keep their own licenses.
