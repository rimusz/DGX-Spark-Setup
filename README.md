# DGX Spark Setup

Public tooling to run **DeepSeek V4 Flash** (OpenAI-compatible) on one **NVIDIA DGX Spark** (GB10).

**Model:** DeepSeek only — EXL3 / SparkInfer on **`:8001`** (optional GGUF backup `deepseek-ds4`).

→ [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark)

**Access:** **LAN only** (no Tailscale) via `spark-local` / LAN IP.

**Stability:** GB10 GPU clock cap **300–2200 MHz**, optional **headless** (`spark-headless on`) to free unified RAM, firmware AC restore + `@reboot` → `spark-boot.sh`.

---

## Layout

```text
spark/                 # sm, boot, clock-cap, DeepSeek wrappers
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

sm pull deepseek
sm start deepseek
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
curl -sf http://spark-local:8001/v1/models
```

---

## Client URL

`http://spark-local:8001/v1` or `http://YOUR_LAN_IP:8001/v1`

Optional dashboard: `:8787` (loopback + LAN).

---

## License

MIT for scripts and docs in this repository. Model weights and upstream recipes keep their own licenses.
