# DGX Spark — dedicated LLM inference

**Role:** OpenAI-compatible inference **only**. No agents or orchestration on this host.  
**Clients:** LAN hosts only (no Tailscale). Use `spark-local` / `YOUR_LAN_IP`.

| Item | Value |
|------|--------|
| Host | `spark-local`→`YOUR_LAN_IP` (client `/etc/hosts`) / optional mDNS `spark.local` |
| Access | **LAN only** |
| User | `YOUR_LINUX_USER` |
| Hardware | NVIDIA DGX Spark (GB10, 128 GB unified, CUDA 13 / driver 580, aarch64) |
| **Production path** | **Docker** `vllm/vllm-openai:nightly-aarch64` |
| Models | **Qwen** (vLLM :8000), **DeepSeek-V4-Flash** (EXL3 :8001), **Ling-3.0-flash** (SGLang :8002) — **one at a time** |
| Switcher | `sm` / `spark-model start qwen\|deepseek\|ling` |
| Stability | GB10 clock cap **300–2200 MHz** (`gb10-clock-cap.service`) |
| Dashboard | `http://spark-local:8787` (LAN bind) — `ensure-spark-dashboard.sh` |

---

## Layout (this directory)

```text
setup-spark.sh                      # repo root (same as other setup-*.sh)
spark/
├── README.md
├── bin/
│   ├── spark-model.sh              # exclusive multi-model switcher → ~/bin/spark-model
│   ├── vllm-qwen35-docker.sh       # Qwen vLLM Docker
│   ├── vllm-docker-ops.sh
│   ├── ensure-hf-cli.sh            # Hugging Face `hf` CLI → ~/.local/bin
│   ├── download-qwen35-nvfp4.sh    # uses hf download into HF cache
│   ├── bench-vllm.sh
│   ├── vllm-qwen35-serve.sh        # native Qwen (secondary)
│   ├── spark-privileged-bootstrap.sh
│   ├── apply-gb10-clock-cap.sh     # nvidia-smi -lgc 300,2200 + systemd
│   ├── revert-gb10-clock-cap.sh
│   └── spark-boot.sh               # @reboot last sm start
├── models/
│   ├── README.md
│   ├── deepseek/                   # vendored MiaAI ds4 wrappers
│   └── ling/                       # vendored MiaAI SGLang wrappers
├── systemd/
│   ├── vllm-qwen35.service
│   └── gb10-clock-cap.service
└── experimental/
```

Runbook mirror: [docs/runbooks/spark-inference.md](../docs/runbooks/spark-inference.md).

---

## Production quick start (on Spark)

```bash
# From this repo (on Spark or scp'd) — setup script is at repo root
cd ~/DGX-Spark-Setup
./scripts/spark-ops/setup-spark.sh
source ~/.bashrc

# Once (root): apt, docker, GB10 2200 MHz clock cap (LAN-only; no Tailscale)
sudo ~/bin/spark-privileged-bootstrap.sh
newgrp docker   # or re-login

# Prefetch + serve via exclusive switcher (recommended)
# setup-spark.sh also installs Hugging Face `hf` → ~/.local/bin (login PATH)
sm pull qwen         # Docker image + HF weights via `hf download` (no start)
sm start qwen        # → http://spark-local:8000/v1 (from LAN clients)
sm status
hf --version         # model Hub CLI (not a server)
```

### Hugging Face CLI (`hf`)

Installed by `setup-spark.sh` / `ensure-hf-cli.sh` into `~/.local/bin` (already on PATH in login shells via `.bashrc` / `.profile`).

| Use | Command |
|-----|---------|
| Check | `hf --version` |
| Upgrade | `ensure-hf-cli.sh --upgrade` |
| Prefetch weights | `hf download nvidia/Qwen3.6-35B-A3B-NVFP4` (or `sm pull qwen`) |
| Gated models | `hf auth login` or `HF_TOKEN=…` |

`hf` only manages Hub downloads/cache — it does **not** serve models. Serving stays with `sm start …`.

### Other models (same host — exclusive)

```bash
# Prefetch (safe while another model is serving)
sm pull deepseek     # ds4 build + ~110 GiB GGUF (no serve)
sm pull ling         # SGLang image + INT4 weights
sm pull all          # all three

# DeepSeek-V4-Flash (EXL3 / SparkInfer default; GGUF backup: sm start deepseek-ds4)
sm start deepseek    # → http://spark-local:8001/v1

# Ling-3.0-flash-int4 (SGLang Docker)
sm start ling        # → http://spark-local:8002/v1

sm stop              # free unified memory
```

**Important:** Only **one** of Qwen / DeepSeek / Ling should run. Each wants most of 128 GB unified memory.

### Boot / power-loss: what auto-starts?

### GB10 clock cap (hard power-off mitigation)

Sustained load can trigger a **log-less hard power cut**. Cap graphics clocks at **2200 MHz**:

```bash
sudo apply-gb10-clock-cap.sh          # now + enable gb10-clock-cap.service
# or: sudo nvidia-smi -lgc 300,2200
systemctl status gb10-clock-cap
nvidia-smi -q -d CLOCK | head -40
```

Revert: `sudo revert-gb10-clock-cap.sh`. Community prior art: [DGX-Spark-Hard-Poweroff-Fix](https://github.com/tonyd2wild/DGX-Spark-Hard-Poweroff-Fix).

Also set firmware **Restore AC Power Loss → Power On** so the machine returns after outages; then Docker + clock-cap + `spark-boot.sh` bring inference back.


Production Qwen is a **Docker** container (`vllm-qwen35`) created with **`--restart unless-stopped`**. Docker itself is **enabled** on boot. The native systemd unit `vllm-qwen35.service` stays **disabled** (Docker path only).

| Situation | Auto-starts after reboot / AC restore? |
|-----------|------------------------------------------|
| **Qwen** (`sm start qwen` / Docker `vllm-qwen35`) | **Yes**, if the container still exists and was not left deliberately stopped |
| Firmware “power on after power loss” | Powers the **machine** on when AC returns; does not replace Docker policy |
| Clean `poweroff` / `shutdown` then later power on | Machine may stay off until you press power **or** AC is cut and restored (depends on firmware); Docker then restarts eligible containers |
| `docker stop vllm-qwen35` and leave it stopped | **No** — `unless-stopped` does not restart a *user-stopped* container until you `docker start` / `sm start qwen` once |
| `sm stop` or container removed | **No** — start again with `sm start qwen` |
| **Last `sm start`** (qwen / deepseek / ling) | **Yes** — `~/.config/spark-models/autostart` + crontab `@reboot` → `spark-boot.sh`. `sm stop` clears it. Qwen Docker `unless-stopped` is extra if that container is still present |
| **Ling** (SGLang Docker) | Only if that container remains with a restart policy; exclusive switcher usually stops other models |

**After move or power cycle — verify:**

```bash
# On Spark
sm status
docker ps --filter name=vllm
curl -sf http://127.0.0.1:8000/v1/models

# From Mini / MacBook on LAN (wait a few minutes for weights to load)
curl -sf http://spark-local:8000/v1/models
curl -sf http://YOUR_LAN_IP:8000/v1/models
```

If Qwen is down after boot: `sm start qwen` (or `vo start` / recreate via `vllm-qwen35-docker.sh`).  
Inspect policy: `docker inspect vllm-qwen35 --format '{{.HostConfig.RestartPolicy.Name}}'` → expect `unless-stopped`.

### Client URLs (LAN only)

OpenAI **base URL** is always `http://<host>:<port>/v1` (clients append `/models`, `/chat/completions`).  
Bare `http://…/v1` with no further path often returns `{"detail":"Not Found"}` — that is normal; probe with `/v1/models`.

| Client situation | Prefer base URL (Qwen example) | Notes |
|------------------|--------------------------------|--------|
| **LAN clients (spark-local)** | **`http://spark-local:8000/v1`** | `/etc/hosts` → `YOUR_LAN_IP`; needs Local Network → **node** on macOS |
| LAN IP | `http://YOUR_LAN_IP:8000/v1` | Direct; no hosts entry required |
| curl / browsers | `http://spark.local:8000/v1` | Happy Eyeballs; **not for long-lived clients** |

Same hosts for other models: DeepSeek port **8001**, Ling **8002**.

**This setup does not use Tailscale.** Keep Spark and clients on the same LAN.

**Client caveats**
1. **Local Network:** if Test Connection gets `EHOSTUNREACH` to `spark-local` / `192.168.1.x`, enable System Settings → Privacy & Security → Local Network → **node**, then retry (or use `http://YOUR_LAN_IP:800N/v1`).
2. **mDNS:** do not use `spark.local` in long-lived clients (IPv6 first + IPv4-only binds).

#### Latency

Prefer same-switch LAN. Decode (ms/token) dominates; URL choice rarely changes tok/s.

#### LAN clients on Mac Mini (recommended)

```text
Base URL:  http://spark-local:8001/v1    # DeepSeek; :8000 Qwen / :8002 Ling (LAN)
API key:   leave empty or any placeholder if UI requires one
Model id:  curl -s http://spark-local:8001/v1/models | jq -r '.data[].id'
```

Hosts entry: `add-spark-local-hosts.sh`. This host is LAN-only — no off-LAN URL.

Ollama on Mini is **optional / stopped by default** — prefer Spark as the primary local LLM provider.

### Verify

```bash
# On Spark
curl -s http://127.0.0.1:8000/v1/models | jq .

# From Mac Mini / laptop on LAN
curl -s http://spark-local:8000/v1/models | jq .
curl -s http://YOUR_LAN_IP:8000/v1/models | jq .
```

Chat (use enough `max_tokens` — model emits **reasoning** first):

```bash
curl -s http://spark-local:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen36-35b-a3b-nvfp4",
    "messages": [{"role":"user","content":"Say only: SPARK-OK"}],
    "max_tokens": 256,
    "temperature": 0
  }' | jq .
```

---

## Serve flags (35B-A3B MoE NVFP4)

| Requirement | Setting |
|-------------|---------|
| Quantization | `--quantization modelopt` |
| FP8 KV | `--kv-cache-dtype fp8` |
| Marlin MoE | `--moe-backend marlin` + `VLLM_MXFP4_USE_MARLIN=1` |
| FlashInfer | `--attention-backend flashinfer` |
| MTP-3 | `--speculative-config '{"method":"mtp","num_speculative_tokens":3,"moe_backend":"triton"}'` |
| Reasoning | `--reasoning-parser qwen3` |
| Tools | `--tool-call-parser qwen3_xml --enable-auto-tool-choice` |
| Bind | `--host 0.0.0.0 --port 8000` |
| Context | `--max-model-len 262144`, `--gpu-memory-utilization 0.40` |

Env overrides: `VLLM_GPU_MEM_UTIL`, `VLLM_MAX_MODEL_LEN`, `VLLM_MAX_NUM_SEQS`, `VLLM_IMAGE`, `HF_TOKEN`, `HF_CACHE`.

---

## Multi-model matrix

| Key | Engine | Port | Weights (order of magnitude) | Upstream |
|-----|--------|------|------------------------------|----------|
| `qwen` | vLLM Docker | **8000** | ~22 GB NVFP4 | our `vllm-qwen35-docker.sh` |
| `deepseek` | **EXL3 / SparkInfer** (Docker) | **8001** | ~**107 GB** EXL3 | [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) (`~/code/dsv4-exl3`) |
| `deepseek-ds4` | **ds4-server** GGUF backup | **8001** | ~**88 GB** GGUF | Entrpi/ds4-on-spark (`~/gguf`) |
| `ling` | **SGLang** Docker | **8002** | ~25–40 GB INT4 | [MiaAI Ling-3.0-Flash-SGLang](https://github.com/MiaAI-Lab/Ling-3.0-Flash-SGLang-DGX-Spark) |

Default DeepSeek is **EXL3 / SparkInfer** (OpenAI `/v1`, model id `deepseek-v4-flash-0731`). Profile is **8 seqs / 256k / K5** on **:8001** (`MAX_NUM_SEQS=8`, `MAX_MODEL_LEN=256000`, `DSPARK_TOKENS=5`; DSpark will not start below K5) so clients can overlap concurrent work. Leave `MAX_NUM_BATCHED_TOKENS=8224`. Recipe: `sm pull deepseek` clones/retargets [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) (based on MiaAI). GGUF backup: `sm start deepseek-ds4` (`~/gguf`, 512k). Ling is Docker like Qwen but **SGLang**, not vLLM.

## Lessons from MiaAI-Lab DGX Spark repos

References:

- [Qwen3.6-27B-NVFP4-DFlash-DGX-Spark](https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-DFlash-DGX-Spark) (patterns; we serve 35B-A3B not 27B-DFlash)
- [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) (stack EXL3 recipe; based on MiaAI)
- [MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark) (upstream deep-context recipe)
- [Ling-3.0-Flash-SGLang-DGX-Spark](https://github.com/MiaAI-Lab/Ling-3.0-Flash-SGLang-DGX-Spark)

That project targets a **dense 27B** with **DFlash** draft model. We adapted patterns that apply to any Spark + vLLM Docker deployment:

| MiaAI pattern | Applied here |
|---------------|--------------|
| Image `vllm/vllm-openai:nightly-aarch64` | Default `VLLM_IMAGE` (not plain `:nightly`) |
| `--network host --ipc host --privileged --gpus all` | Same |
| `CUTE_DSL_ARCH=sm_121a` | Set for GB10 |
| `VLLM_TARGET_DEVICE=cuda`, high float32 matmul precision | Set |
| Mount HF **and** Triton caches | `${HOME}/.cache/huggingface` + `.cache/triton` |
| Readiness poll on `/v1/models` | Built into `vllm-qwen35-docker.sh` |
| `--served-model-name` stable API id | `qwen36-35b-a3b-nvfp4` |
| `HF_TOKEN` passthrough | Supported |
| Clean start/stop UX | `vllm-qwen35-docker.sh` + `vllm-docker-ops.sh` |
| Custom chat template + DFlash | **Not** used for 35B-A3B (different draft path: MTP-3) |
| `gpu-memory-utilization 0.84` | We use **0.40** (MoE + 262k + MTP on unified memory) |
| Port 8888 | We use **8000** (stack convention) |

If you later switch to **27B dense + DFlash**, clone MiaAI’s `start.sh` / `chat_template.jinja` and change only host/port/cache paths — do not mix DFlash flags with our MoE MTP config without testing.

---

## What we learned on this Spark (pitfalls)

1. **Native eelbaz vLLM (≈0.11.1)** builds on GB10 (sm_121 / CUDA 13) but **does not register** `Qwen3_5MoeForConditionalGeneration` → cannot load Qwen3.6-35B-A3B.
2. **Newer vLLM (main / Qwen3.5 commits)** support the arch but **failed to compile** here (`_C_stable_libtorch` / torch header errors with torch 2.13+cu130).
3. **`apache-tvm-ffi==0.1.0b15`** is yanked; pin `flashinfer-python==0.6.9` and current `apache-tvm-ffi` if rebuilding native.
4. **CMake MoE arches:** add `12.0f` / `12.1a` to `SCALED_MM_ARCHS` or `cutlass_moe_mm_sm100` is missing at import.
5. **Docker under `sudo`:** `HOME=/root` → mount **`/home/YOUR_LINUX_USER/.cache/huggingface`** explicitly (scripts use `${HOME}` when run as user).
6. **Sudoless Docker:** `usermod -aG docker $USER` + re-login; `~/bin` on PATH via `.bashrc`.
7. **Reasoning models:** short `max_tokens` fills **reasoning** only; use ≥256 for final `content`.
8. **Keep Spark lean:** desktop apps (Firefox/GNOME) waste unified memory; inference-only is ideal.

---

## Tuning (unified memory)

| Goal | Knobs |
|------|--------|
| Full 262k context | `VLLM_GPU_MEM_UTIL=0.35–0.45`, low `max-num-seqs` (2–4) |
| More concurrency | Lower `VLLM_MAX_MODEL_LEN` (e.g. 128k), raise util to 0.5–0.7 |
| OOM / thrash | Lower util first, then context, then disable MTP |
| Prefix-heavy agents | Qwen: `--enable-prefix-caching`. DeepSeek: disk KV (`~/ds4-kv`, on by default). Ling: SGLang radix (default on). |

```bash
VLLM_GPU_MEM_UTIL=0.50 VLLM_MAX_MODEL_LEN=131072 vllm-qwen35-docker.sh
```

---

## Benchmark (tok/s)

MiaAI-comparable metrics (TTFT, prefill tok/s, decode tok/s, e2e out tok/s).  
Default: **thinking off**, salted prompts (prefix-cache fairer).

```bash
# On Spark (or any host that can reach the API)
bench-vllm.sh

# Deep context sweep (default INPUT_LENS=2048,8192,16384,32768 OUTPUT_LEN=256)
INPUT_LENS=2048,8192,16384 OUTPUT_LEN=256 bench-vllm.sh

# Concurrency decode table (like MiaAI ×1–×4)
MODE=decode CONCURRENCY=1,2,4 OUTPUT_LEN=256 bench-vllm.sh

# From MacBook on LAN
BASE_URL=http://spark-local:8000/v1 bench-vllm.sh

# Allow reasoning tokens (inflates completion count / changes latency)
THINKING=1 bench-vllm.sh
```

| Env | Default | Meaning |
|-----|---------|---------|
| `BASE_URL` | `http://127.0.0.1:8000/v1` | API root |
| `MODE` | `deep` | `deep` = context lengths; `decode` = concurrency |
| `OUTPUT_LEN` | `256` | `max_tokens` |
| `INPUT_LENS` | `2048,8192,...` | target input sizes (deep) |
| `CONCURRENCY` | `1` | parallel streams |
| `THINKING` | `0` | `0` sends `enable_thinking=false` when supported |
| `RUNS` | `1` | repeats per cell |

Compare to [MiaAI 27B+DFlash tables](https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-DFlash-DGX-Spark) only with the same `OUTPUT_LEN` / similar input lens — models still differ.

## Ops cheatsheet

```bash
vllm-docker-ops.sh status
vllm-docker-ops.sh logs
vllm-docker-ops.sh restart
vllm-docker-ops.sh stop
vllm-docker-ops.sh start    # recreate (pull + run)

# Upgrade image only
VLLM_IMAGE=vllm/vllm-openai:nightly-aarch64 vllm-qwen35-docker.sh
```

Native unit (optional; **disabled** while Docker is production):

```bash
# Keep disabled so reboot does not fight Docker
sudo systemctl disable --now vllm-qwen35

# Only if native serve works and Docker is stopped:
# sudo systemctl enable --now vllm-qwen35
# journalctl -u vllm-qwen35 -f
```

---

## Sync / update from this repo

Preferred (from MacBook / Mini, repo root):

```bash
./scripts/spark-ops/update-spark.sh              # rsync helpers + setup-spark.sh (hf CLI + dashboard) on Spark
./scripts/spark-ops/update-spark.sh --images     # also sm pull all (weights/images; does not start)
./scripts/spark-ops/update-spark.sh --local      # already on Spark
```

Manual:

```bash
rsync -av setup-spark.sh spark/ ${SPARK_HOST:-user@spark}:~/DGX-Spark-Setup/
ssh ${SPARK_HOST:-user@spark} 'bash ~/DGX-Spark-Setup/setup-spark.sh'   # ~/bin helpers + hf → ~/.local/bin
# or: git -C ~/DGX-Spark-Setup pull && bash setup-spark.sh
ssh ${SPARK_HOST:-user@spark} 'bash -lc "hf --version"'
```

---

## Related

- [eelbaz/dgx-spark-vllm-setup](https://github.com/eelbaz/dgx-spark-vllm-setup) — native GB10 installer (base for experimental path)
- [nvidia/Qwen3.6-35B-A3B-NVFP4](https://huggingface.co/nvidia/Qwen3.6-35B-A3B-NVFP4)
- [MiaAI DFlash 27B Spark wrapper](https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-DFlash-DGX-Spark)
- Stack map: [docs/architecture/stack-map.md](../docs/architecture/stack-map.md)
