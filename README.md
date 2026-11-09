# DGX Spark Setup

Public tooling to run **OpenAI-compatible LLMs** on one **NVIDIA DGX Spark** (GB10).

**Models (exclusive — one at a time):**

| Key | Port | Engine | Default profile | Best for |
|-----|------|--------|-----------------|----------|
| **`qwen`** | **`:8000`** | vLLM Docker | **6 seqs / 131k** | **Data analysis** (tools + reasoning) |
| **`deepseek`** | **`:8001`** | EXL3 / SparkInfer | 6 seqs / 256k / K5 | Long-context reasoning (shared GPU/KV) |
| `deepseek-ds4` | `:8001` | ds4 GGUF backup | — | Fallback for DeepSeek |
| `colibri` | `:8003` | Colibri CUDA | qwen36-35b (~23 GiB) | Opt-in Colibri engine (same family as Qwen) |

DeepSeek recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark)  
Colibri: [JustVugg/colibri](https://github.com/JustVugg/colibri) (`sm pull colibri` — not part of `sm pull all`)

**Access:** **LAN only** (no Tailscale) via `spark-local` / LAN IP.

**Stability:** GB10 GPU clock cap **300–2200 MHz**, optional **headless** (`spark-headless on`) to free unified RAM, firmware AC restore + `@reboot` → `spark-boot.sh`.

---

## Layout

```text
spark/                 # sm, boot, clock-cap, Qwen vLLM + DeepSeek wrappers
scripts/spark-ops/     # setup / update / LAN probe
docs/                  # runbook + skill card
.cursor|claude|agents|codex/skills/spark-inference/
```

---

## Quick start (on Spark)

```bash
git clone https://github.com/rimusz/DGX-Spark-Setup.git ~/DGX-Spark-Setup
cd ~/DGX-Spark-Setup

bash scripts/spark-ops/setup-spark.sh
sudo ~/bin/spark-privileged-bootstrap.sh
newgrp docker

# Data analysis (recommended default for tools / multi-stream work)
sm pull qwen
sm start qwen          # → http://spark-local:8000/v1  (6 concurrent / 131k)

# Or DeepSeek for deep long-context reasoning
sm pull deepseek
sm start deepseek      # → http://spark-local:8001/v1

# Optional: Colibri CUDA path for qwen36-35b (~23 GiB)
# sm pull colibri && sm start colibri   # → http://spark-local:8003/v1

sm status

# optional: disable GUI for more unified RAM
sudo spark-headless on && sudo reboot
```

From a laptop on the same LAN:

```bash
export SPARK_HOST=user@YOUR_LAN_IP
export SPARK_LAN_IP=192.168.x.x
./scripts/spark-ops/add-spark-local-hosts.sh
./scripts/spark-ops/update-spark.sh
curl -sf http://spark-local:8000/v1/models   # qwen
curl -sf http://spark-local:8001/v1/models   # deepseek
curl -sf http://spark-local:8003/v1/models   # colibri (if started)
```

---

## Which model?

- **Data analysis / agents with tools / up to 6 parallel streams** → `sm start qwen`
- **Heavier long-context reasoning (256k, 6 streams; shared GPU/KV)** → `sm start deepseek`
- **Try Colibri’s CUDA engine on qwen36-35b** → `sm pull colibri && sm start colibri` (exclusive; slower than vLLM Qwen for most workloads)

Qwen full 262k context (fewer streams):

```bash
VLLM_MAX_MODEL_LEN=262144 VLLM_MAX_NUM_SEQS=4 sm start qwen
```

---

## Client URLs

| Model | Base URL |
|-------|----------|
| Qwen | `http://spark-local:8000/v1` or `http://YOUR_LAN_IP:8000/v1` |
| DeepSeek | `http://spark-local:8001/v1` or `http://YOUR_LAN_IP:8001/v1` |
| Colibri | `http://spark-local:8003/v1` or `http://YOUR_LAN_IP:8003/v1` |

Optional dashboard: `:8787` (loopback + LAN).

---

## License

MIT for scripts and docs in this repository. Model weights and upstream recipes keep their own licenses.
