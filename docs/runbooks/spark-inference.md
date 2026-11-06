# Runbook: DGX Spark inference

Full guide: **[spark/README.md](../../spark/README.md)**.

## Role

- Spark runs **only** OpenAI-compatible inference (no agents on this host).
- Prefer the exclusive switcher (`sm`) — one heavy model at a time.

## Production

| Command | Port | Engine |
|---------|------|--------|
| `sm start qwen` | 8000 | vLLM Docker |
| `sm start deepseek` | 8001 | EXL3 / SparkInfer (0731), 8 seqs / 256k / K5 |
| `sm start deepseek-ds4` | 8001 | ds4-server GGUF backup |
| `sm start ling` | 8002 | SGLang Docker |
| `sm status` / `sm stop` | — | — |

DeepSeek EXL3 recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) (`sm pull deepseek`).

### Boot / power-loss

- Last `sm start` can be armed for `@reboot` via `spark-boot.sh`.
- Qwen Docker may use `unless-stopped` if that container remains.
- Verify: `sm status` ; `curl -sf http://127.0.0.1:800N/v1/models`

## Client URLs

Base URL form: `http://<host>:<port>/v1`.

| From | Prefer |
|------|--------|
| On Spark | `http://127.0.0.1:800N/v1` |
| Tailnet MagicDNS | `http://spark:800N/v1` |
| LAN hosts entry | `http://spark-local:800N/v1` (set `SPARK_LAN_IP` then `add-spark-local-hosts.sh`) |

Check path quality: `tailscale ping spark` (prefer direct, not DERP).

## Health checks

```bash
curl -sf http://127.0.0.1:8000/v1/models
curl -sf http://spark:8000/v1/models
curl -sf http://spark:8787/api/health
```

## Hugging Face CLI

`setup-spark.sh` installs `hf` into `~/.local/bin`. Gated repos: `hf auth login` or `HF_TOKEN=…` (never commit tokens).

## Common failures

| Symptom | Check |
|---------|-------|
| Out of memory / second model | `sm stop` then start only one |
| Tailscale only fails | `tailscale status` on Spark; renew key if expired |
| `hf: command not found` | `source ~/.bashrc` or re-run `setup-spark.sh` / `ensure-hf-cli.sh` |
| Docker permission | `newgrp docker` / re-login after bootstrap |

## Do not

- Run agents or messaging bots on Spark.
- Publish real LAN / Tailscale IPs or auth keys.
