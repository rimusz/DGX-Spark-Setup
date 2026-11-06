# DGX Spark — DeepSeek inference

**Role:** OpenAI-compatible **DeepSeek V4 Flash** only. No agents, no Qwen/Ling.  
**Clients:** LAN only (`spark-local` / `YOUR_LAN_IP`). No Tailscale.

| Item | Value |
|------|--------|
| Host | `spark-local`→`YOUR_LAN_IP` (client `/etc/hosts`) |
| Access | **LAN only** |
| User | `YOUR_LINUX_USER` |
| Hardware | NVIDIA DGX Spark (GB10, 128 GB unified, aarch64) |
| Model | **DeepSeek-V4-Flash** EXL3 / SparkInfer on **:8001** |
| Backup | `sm start deepseek-ds4` (ds4 GGUF, same port) |
| Switcher | `sm` / `spark-model` |
| Stability | GB10 clock cap **300–2200 MHz** (`gb10-clock-cap.service`) |
| Dashboard | `http://spark-local:8787` |

Recipe: [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) (`sm pull deepseek` → `~/code/dsv4-exl3`).

---

## Layout

```text
spark/
├── README.md
├── bin/
│   ├── spark-model.sh              # sm — DeepSeek start/stop/pull
│   ├── spark-boot.sh               # @reboot last sm start
│   ├── apply-gb10-clock-cap.sh     # nvidia-smi -lgc 300,2200 + systemd
│   ├── revert-gb10-clock-cap.sh
│   ├── spark-headless.sh           # multi-user vs graphical (free RAM)
│   ├── ensure-hf-cli.sh
│   ├── ensure-spark-dashboard.sh
│   └── spark-privileged-bootstrap.sh
├── models/deepseek/                # EXL3 + ds4 wrappers
└── systemd/gb10-clock-cap.service
```

---

## Quick start (on Spark)

```bash
cd ~/DGX-Spark-Setup
bash scripts/spark-ops/setup-spark.sh
source ~/.bashrc

sudo ~/bin/spark-privileged-bootstrap.sh
newgrp docker

sm pull deepseek
sm start deepseek    # → http://spark-local:8001/v1
sm status
```

Optional GGUF backup: `sm pull deepseek-ds4` then `sm start deepseek-ds4`.

Default EXL3 profile: **8 seqs / 256k / K5** (`MAX_NUM_SEQS=8`, `MAX_MODEL_LEN=256000`, `DSPARK_TOKENS=5`).

---

## Boot / power-loss

After AC returns, the **machine** must power on by itself; then OS boot helpers bring DeepSeek back:

1. Firmware **After Power Loss → Auto Boot** (aka Restore AC Power Loss → Power On) — see below.
2. `gb10-clock-cap.service` reapplies `nvidia-smi -lgc 300,2200` every boot.
3. Last `sm start deepseek|deepseek-ds4` arms crontab `@reboot` → `spark-boot.sh` (`sm stop` clears it).

```bash
sudo apply-gb10-clock-cap.sh
systemctl status gb10-clock-cap
sm status
curl -sf http://127.0.0.1:8001/v1/models
```

Community prior art for the clock cap: [DGX-Spark-Hard-Poweroff-Fix](https://github.com/tonyd2wild/DGX-Spark-Hard-Poweroff-Fix).

### Set “power on after power loss”

Linux cannot turn the box on while it is off. This is a **UEFI** setting. Official names (NVIDIA [Advanced Tab](https://docs.nvidia.com/dgx/dgx-spark-uefi/advanced-tab.html)):

| Setting | Value for auto-boot after AC restore |
|---------|--------------------------------------|
| **Advanced → Power On Behavior → After Power Loss Behavior** | **`Auto Boot`** (not `Power Button Press`) |

#### Option A — UEFI Setup (official)

1. Attach a display/keyboard (or use BMC/KVM if you have one).
2. Reboot and enter UEFI Setup (Del / F2 at the firmware splash — vendor key as shown on screen).
3. **Advanced → Power On Behavior → After Power Loss Behavior → `Auto Boot`**.
4. **Save & Exit** (or Save Changes and Reset).

#### Option B — headless script (community, at your own risk)

No display? Patch the AMI `Setup` EFI variable from Linux. Third-party tool (not NVIDIA-supported; backs up before write; `--revert` available):

[Fheodoor01/DGX-Spark---Power-on-boot-](https://github.com/Fheodoor01/DGX-Spark---Power-on-boot-)

```bash
sudo apt-get install -y efivar
git clone https://github.com/Fheodoor01/DGX-Spark---Power-on-boot-.git ~/DGX-Spark-Power-on-boot
cd ~/DGX-Spark-Power-on-boot
sudo ./dgx-spark-auto-poweron.sh --check    # show current state
sudo ./dgx-spark-auto-poweron.sh            # enable Power On / Auto Boot
sudo reboot                                 # required for the change to take effect
# later: sudo ./dgx-spark-auto-poweron.sh --revert
```

Spark has **no** rack-style Redfish `PowerRestorePolicy` for this. A clean `poweroff` exercises the same firmware path as AC loss for testing: after `Auto Boot`, the unit should power back on within ~30s.

---

## Headless (disable GUI)

GB10 unified memory is shared with the desktop. Booting without GNOME often frees **~10–15 GiB** for KV cache. SSH/LAN keep working.

```bash
spark-headless status
sudo spark-headless on && sudo reboot    # multi-user.target — no GUI after reboot
sudo spark-headless now                  # drop GUI this boot only
sudo spark-headless off && sudo reboot   # restore graphical desktop
```

Do **not** `apt purge ubuntu-desktop` — that can remove Spark platform packages. Leave the desktop installed; `multi-user.target` simply never starts it.

---

## Client URLs (LAN)

| From | Base URL |
|------|----------|
| On Spark | `http://127.0.0.1:8001/v1` |
| LAN hosts | `http://spark-local:8001/v1` |
| LAN IP | `http://YOUR_LAN_IP:8001/v1` |

```bash
curl -s http://spark-local:8001/v1/models | jq .
curl -s http://spark-local:8001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-v4-flash-0731",
    "messages": [{"role":"user","content":"Say only: SPARK-OK"}],
    "max_tokens": 256,
    "temperature": 0
  }' | jq .
```

On macOS, allow Local Network for the client process, or use the raw LAN IP.

---

## Hugging Face CLI

`setup-spark.sh` / `ensure-hf-cli.sh` → `hf` in `~/.local/bin`. Gated models: `hf auth login` or `HF_TOKEN=…` (never commit).

---

## From a LAN laptop

```bash
export SPARK_HOST=user@YOUR_LAN_IP
export SPARK_LAN_IP=YOUR_LAN_IP
./scripts/spark-ops/update-spark.sh
./scripts/spark-ops/update-spark.sh --images deepseek
```
