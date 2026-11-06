# Runbook: DGX Spark inference

Full guide: **[spark/README.md](../../spark/README.md)**.

## Role

- Spark runs **only** OpenAI-compatible inference (no agents on this host).
- Prefer the exclusive switcher (`sm`) — one heavy model at a time.
- **LAN-only** access (no Tailscale).

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

1. Firmware “Restore AC Power Loss” → Power On.
2. `gb10-clock-cap.service` reapplies `nvidia-smi -lgc 300,2200` every boot.
3. Last `sm start` is armed for crontab `@reboot` → `spark-boot.sh` (`sm stop` clears it).
4. Qwen Docker may use `unless-stopped` if that container remains.
5. Verify: `sm status` ; `curl -sf http://127.0.0.1:800N/v1/models` ; `systemctl is-active gb10-clock-cap`

## Client URLs (LAN)

Base URL form: `http://<host>:<port>/v1`.

| From | Prefer |
|------|--------|
| On Spark | `http://127.0.0.1:800N/v1` |
| LAN hosts entry | `http://spark-local:800N/v1` (set `SPARK_LAN_IP` then `add-spark-local-hosts.sh`) |
| LAN IP | `http://YOUR_LAN_IP:800N/v1` |

## Health checks

```bash
curl -sf http://127.0.0.1:8000/v1/models
curl -sf http://spark-local:8000/v1/models
curl -sf http://spark-local:8787/api/health
nvidia-smi -q -d CLOCK | head -40
```

## Hugging Face CLI

`setup-spark.sh` installs `hf` into `~/.local/bin`. Gated repos: `hf auth login` or `HF_TOKEN=…` (never commit tokens).

## Common failures

| Symptom | Check |
|---------|-------|
| Out of memory / second model | `sm stop` then start only one |
| Hard power-off under load | Confirm clock cap: `systemctl status gb10-clock-cap`; re-run `sudo apply-gb10-clock-cap.sh` |
| LAN unreachable from Mac | Privacy → Local Network allowlist, or use raw `YOUR_LAN_IP` |
| `hf: command not found` | `source ~/.bashrc` or re-run `setup-spark.sh` / `ensure-hf-cli.sh` |
| Docker permission | `newgrp docker` / re-login after bootstrap |

## Do not

- Run agents or messaging bots on Spark.
- Publish real LAN IPs or HF tokens.
- Depend on Tailscale / MagicDNS for this host.
