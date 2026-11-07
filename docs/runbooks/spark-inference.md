# Runbook: DGX Spark Qwen + DeepSeek

Full guide: **[spark/README.md](../../spark/README.md)**.

## Role

- **One model at a time** on GB10 unified memory.
- **Qwen** on **:8000** (vLLM) — data analysis default **6 seqs / 131k**, tools + reasoning.
- **DeepSeek** on **:8001** (EXL3 default; optional `deepseek-ds4` GGUF).
- LAN-only (no Tailscale).

## Commands

| Command | Port | Engine |
|---------|------|--------|
| `sm start qwen` | 8000 | vLLM Docker (6 seqs / 131k data analysis) |
| `sm start deepseek` | 8001 | EXL3 / SparkInfer (8 seqs / 256k / K5) |
| `sm start deepseek-ds4` | 8001 | ds4-server GGUF backup |
| `sm status` / `sm stop` | — | — |

DeepSeek recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark).

Qwen full 262k (fewer streams): `VLLM_MAX_MODEL_LEN=262144 VLLM_MAX_NUM_SEQS=4 sm start qwen`.

### Boot / power-loss

1. Firmware **After Power Loss → Auto Boot** (Restore AC → Power On). How-to: [spark/README.md](../../spark/README.md) § Set “power on after power loss” — UEFI path **or** headless [EFI-var script](https://github.com/Fheodoor01/DGX-Spark---Power-on-boot-) (at your own risk).
2. `gb10-clock-cap.service` → `nvidia-smi -lgc 300,2200`.
3. Last `sm start` → crontab `@reboot` → `spark-boot.sh`.
4. Verify: `sm status` ; `curl -sf http://127.0.0.1:8000/v1/models` or `:8001`

### Headless (no GUI)

```bash
sudo spark-headless on && sudo reboot   # free ~10–15 GiB unified RAM
spark-headless status
```

Do not purge `ubuntu-desktop`.

## Client URL

| Model | URL |
|-------|-----|
| Qwen | `http://spark-local:8000/v1` |
| DeepSeek | `http://spark-local:8001/v1` |

Set `SPARK_LAN_IP` + `add-spark-local-hosts.sh`, or use `http://YOUR_LAN_IP:800N/v1`.

## Health

```bash
curl -sf http://127.0.0.1:8000/v1/models
curl -sf http://127.0.0.1:8001/v1/models
curl -sf http://spark-local:8000/v1/models
systemctl status gb10-clock-cap
```

## Failures

| Symptom | Check |
|---------|-------|
| Hard power-off under load | `sudo apply-gb10-clock-cap.sh` |
| LAN unreachable | Local Network allowlist / raw LAN IP |
| Docker permission | `newgrp docker` after bootstrap |
| Qwen OOM | Lower `VLLM_MAX_MODEL_LEN` or `VLLM_MAX_NUM_SEQS`; try headless |
