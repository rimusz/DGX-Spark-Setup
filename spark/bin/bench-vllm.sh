#!/usr/bin/env bash
# Benchmark OpenAI-compatible vLLM on Spark (MiaAI-comparable table).
#
# Reports TTFT, prefill tok/s, decode tok/s, e2e out tok/s for fixed input/output
# lengths. Prompts are salted so prefix cache does not inflate results.
#
# Usage (on Spark or any client that can reach the API):
#   bench-vllm.sh
#   BASE_URL=http://spark-local:8000/v1 OUTPUT_LEN=256 CONCURRENCY=1 bench-vllm.sh
#   INPUT_LENS="2048,8192,16384" THINKING=0 bench-vllm.sh
#   MODE=decode CONCURRENCY=1,2,4 OUTPUT_LEN=256 bench-vllm.sh
#
# Env:
#   BASE_URL       default http://127.0.0.1:8000/v1
#   MODEL          default: first id from /models
#   MODE           deep (default) | decode
#   INPUT_LENS     comma list of *target* input token counts (deep mode)
#   OUTPUT_LEN     completion tokens to generate (default 256)
#   CONCURRENCY    comma list (decode mode) or single int (deep mode, default 1)
#   RUNS           repeats per cell (default 1)
#   THINKING       1=allow reasoning (default 0 for fair decode numbers)
#   WARMUP         1=one short warmup request first (default 1)
#   CHARS_PER_TOKEN approx chars per token for prompt padding (default 4)
set -euo pipefail

export PATH="${HOME}/bin:${HOME}/.local/bin:${PATH}"

BASE_URL="${BASE_URL:-http://127.0.0.1:8000/v1}"
MODE="${MODE:-deep}"
INPUT_LENS="${INPUT_LENS:-2048,8192,16384,32768}"
OUTPUT_LEN="${OUTPUT_LEN:-256}"
CONCURRENCY="${CONCURRENCY:-1}"
RUNS="${RUNS:-1}"
THINKING="${THINKING:-0}"
WARMUP="${WARMUP:-1}"
CHARS_PER_TOKEN="${CHARS_PER_TOKEN:-4}"
MODEL="${MODEL:-}"

command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl required"; exit 1; }

if ! curl -sf --connect-timeout 3 "${BASE_URL}/models" >/dev/null; then
  echo "API not reachable at ${BASE_URL}/models"
  echo "Start server: vllm-qwen35-docker.sh   (or set BASE_URL=...)"
  exit 1
fi

exec python3 - "$@" <<'PY'
from __future__ import annotations

import json
import os
import random
import string
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

BASE = os.environ.get("BASE_URL", "http://127.0.0.1:8000/v1").rstrip("/")
MODE = os.environ.get("MODE", "deep").strip().lower()
OUTPUT_LEN = int(os.environ.get("OUTPUT_LEN", "256"))
RUNS = max(1, int(os.environ.get("RUNS", "1")))
THINKING = os.environ.get("THINKING", "0").strip() not in ("0", "false", "no", "")
WARMUP = os.environ.get("WARMUP", "1").strip() not in ("0", "false", "no", "")
CPT = max(1, int(os.environ.get("CHARS_PER_TOKEN", "4")))
MODEL = os.environ.get("MODEL", "").strip() or None

INPUT_LENS = [int(x) for x in os.environ.get("INPUT_LENS", "2048,8192,16384,32768").split(",") if x.strip()]
CONCURRENCIES = [int(x) for x in os.environ.get("CONCURRENCY", "1").split(",") if x.strip()]


def http_json(method: str, url: str, body: dict | None = None, timeout: float = 600.0) -> Any:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def resolve_model() -> str:
    global MODEL
    if MODEL:
        return MODEL
    d = http_json("GET", f"{BASE}/models", timeout=30)
    models = d.get("data") or []
    if not models:
        raise SystemExit("No models listed at /v1/models")
    MODEL = models[0]["id"]
    return MODEL


def pad_prompt(target_tokens: int, salt: str) -> str:
    """Build a ~target_tokens prompt (heuristic; usage.prompt_tokens is ground truth)."""
    # Instruction + salt; pad with unique digits so cache cannot hit across runs.
    head = (
        f"Task: repeat the word ok. Salt={salt}. "
        "Ignore the following filler; it only sets context length.\n"
    )
    need = max(0, target_tokens * CPT - len(head))
    # Use a deterministic alphabet stream mixed with salt so runs differ.
    rng = random.Random(salt)
    chunk = "".join(rng.choice(string.ascii_lowercase + " ") for _ in range(min(need, 200_000)))
    if need > len(chunk):
        chunk = (chunk * (need // max(len(chunk), 1) + 1))[:need]
    return head + chunk


def chat_body(prompt: str, max_tokens: int, stream: bool) -> dict:
    body: dict[str, Any] = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": stream,
    }
    if stream:
        # Ask vLLM/OpenAI for final usage on the stream (accurate tok counts).
        body["stream_options"] = {"include_usage": True}
    # Reduce reasoning burn so completion tokens ≈ usable decode work.
    if not THINKING:
        body["chat_template_kwargs"] = {"enable_thinking": False}
    return body


def one_completion(prompt: str, max_tokens: int) -> dict[str, float | int]:
    """Non-stream request; returns timings + token usage."""
    body = chat_body(prompt, max_tokens, stream=False)
    # Also try top-level only (some servers reject nested extra_body)
    if not THINKING:
        body.pop("extra_body", None)

    t0 = time.perf_counter()
    try:
        d = http_json("POST", f"{BASE}/chat/completions", body, timeout=900)
    except urllib.error.HTTPError as e:
        err = e.read().decode(errors="replace")[:500]
        # Retry without chat_template_kwargs if server rejects it
        if "chat_template" in err.lower() or e.code in (400, 422):
            body.pop("chat_template_kwargs", None)
            t0 = time.perf_counter()
            d = http_json("POST", f"{BASE}/chat/completions", body, timeout=900)
        else:
            raise SystemExit(f"HTTP {e.code}: {err}") from e
    t1 = time.perf_counter()

    usage = d.get("usage") or {}
    pt = int(usage.get("prompt_tokens") or 0)
    ct = int(usage.get("completion_tokens") or 0)
    elapsed = t1 - t0
    return {
        "elapsed": elapsed,
        "prompt_tokens": pt,
        "completion_tokens": ct,
        "e2e_out_tok_s": (ct / elapsed) if elapsed > 0 and ct else 0.0,
    }


def one_stream(prompt: str, max_tokens: int) -> dict[str, float | int]:
    """Stream for TTFT; still use usage if present on final chunk."""
    body = chat_body(prompt, max_tokens, stream=True)
    body.pop("extra_body", None)
    if not THINKING:
        body["chat_template_kwargs"] = {"enable_thinking": False}

    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=data,
        method="POST",
        headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
    )
    t0 = time.perf_counter()
    ttft = None
    completion_tokens = 0
    prompt_tokens = 0
    text_chars = 0

    try:
        resp = urllib.request.urlopen(req, timeout=900)
    except urllib.error.HTTPError as e:
        err = e.read().decode(errors="replace")[:500]
        if "chat_template" in err.lower() or e.code in (400, 422):
            body.pop("chat_template_kwargs", None)
            data = json.dumps(body).encode()
            req = urllib.request.Request(
                f"{BASE}/chat/completions",
                data=data,
                method="POST",
                headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
            )
            t0 = time.perf_counter()
            resp = urllib.request.urlopen(req, timeout=900)
        else:
            raise SystemExit(f"HTTP {e.code}: {err}") from e

    with resp:
        for raw in resp:
            line = raw.decode("utf-8", errors="replace")
            if not line.startswith("data: "):
                continue
            payload = line[6:].strip()
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if ttft is None:
                ttft = time.perf_counter() - t0
            usage = chunk.get("usage")
            if usage:
                prompt_tokens = int(usage.get("prompt_tokens") or prompt_tokens)
                completion_tokens = int(usage.get("completion_tokens") or completion_tokens)
            choices = chunk.get("choices") or []
            if not choices:
                continue
            delta = choices[0].get("delta") or {}
            for key in ("content", "reasoning", "reasoning_content"):
                if delta.get(key):
                    text_chars += len(delta[key])
                    break

    t1 = time.perf_counter()
    elapsed = t1 - t0
    if ttft is None:
        ttft = elapsed
    # If usage missing, estimate completion from chunks (rough)
    if completion_tokens <= 0 and text_chars:
        completion_tokens = max(1, text_chars // CPT)

    gen_time = max(elapsed - ttft, 1e-6)
    return {
        "elapsed": elapsed,
        "ttft": ttft,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "prefill_tok_s": (prompt_tokens / ttft) if ttft > 0 and prompt_tokens else 0.0,
        "decode_tok_s": (completion_tokens / gen_time) if completion_tokens else 0.0,
        "e2e_out_tok_s": (completion_tokens / elapsed) if elapsed > 0 and completion_tokens else 0.0,
    }


def avg(rows: list[dict], key: str) -> float:
    if not rows:
        return 0.0
    return sum(float(r[key]) for r in rows) / len(rows)


def print_table(headers: list[str], rows: list[list[str]]) -> None:
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    fmt = " | ".join(f"{{:{w}}}" for w in widths)
    print(fmt.format(*headers))
    print("-+-".join("-" * w for w in widths))
    for row in rows:
        print(fmt.format(*row))


def run_warmup() -> None:
    print("Warmup (short request)...")
    one_stream("Say hi in three words.", 16)
    print("Warmup done.\n")


def mode_deep() -> None:
    """Deep-context table similar to MiaAI README."""
    conc = CONCURRENCIES[0] if CONCURRENCIES else 1
    print(f"MODE=deep  BASE={BASE}  MODEL={MODEL}")
    print(f"OUTPUT_LEN={OUTPUT_LEN}  RUNS={RUNS}  CONCURRENCY={conc}  THINKING={int(THINKING)}")
    print(f"INPUT_LENS={INPUT_LENS}  CHARS_PER_TOKEN={CPT}\n")

    headers = [
        "target_in",
        "prompt_tok",
        "out_tok",
        "ttft_s",
        "prefill_t/s",
        "decode_t/s",
        "e2e_out_t/s",
        "total_s",
    ]
    table: list[list[str]] = []

    for target in INPUT_LENS:
        cells: list[dict] = []
        for run in range(RUNS):
            salt = f"{target}-{run}-{int(time.time() * 1000)}-{random.randrange(1 << 20)}"
            prompt = pad_prompt(target, salt)
            if conc <= 1:
                cells.append(one_stream(prompt, OUTPUT_LEN))
            else:
                # concurrent identical-length salted prompts
                def job(i: int) -> dict:
                    s = f"{salt}-c{i}"
                    return one_stream(pad_prompt(target, s), OUTPUT_LEN)

                with ThreadPoolExecutor(max_workers=conc) as ex:
                    futs = [ex.submit(job, i) for i in range(conc)]
                    for f in as_completed(futs):
                        cells.append(f.result())
            print(
                f"  target_in={target} run={run + 1}/{RUNS} "
                f"prompt={cells[-1]['prompt_tokens']} out={cells[-1]['completion_tokens']} "
                f"ttft={cells[-1]['ttft']:.3f}s decode={cells[-1]['decode_tok_s']:.1f} t/s"
            )
        table.append(
            [
                str(target),
                f"{avg(cells, 'prompt_tokens'):.0f}",
                f"{avg(cells, 'completion_tokens'):.0f}",
                f"{avg(cells, 'ttft'):.3f}",
                f"{avg(cells, 'prefill_tok_s'):.1f}",
                f"{avg(cells, 'decode_tok_s'):.1f}",
                f"{avg(cells, 'e2e_out_tok_s'):.1f}",
                f"{avg(cells, 'elapsed'):.2f}",
            ]
        )

    print()
    print_table(headers, table)


def mode_decode() -> None:
    """Concurrency scaling at short prompt, fixed output (MiaAI decode table style)."""
    print(f"MODE=decode  BASE={BASE}  MODEL={MODEL}")
    print(f"OUTPUT_LEN={OUTPUT_LEN}  RUNS={RUNS}  CONCURRENCY={CONCURRENCIES}  THINKING={int(THINKING)}\n")

    headers = ["conc", "ttft_s", "streams", "agg_t/s", "stream_t/s", "out_tok", "total_s"]
    table: list[list[str]] = []
    # Short fixed prompt + salt
    base_prompt = "Write a numbered list of facts about rivers. Be concise."

    for conc in CONCURRENCIES:
        run_rows: list[dict] = []
        for run in range(RUNS):
            salt = f"dec-{conc}-{run}-{random.randrange(1 << 20)}"

            def job(i: int) -> dict:
                return one_stream(f"{base_prompt} Salt={salt}-{i}.", OUTPUT_LEN)

            t0 = time.perf_counter()
            results: list[dict] = []
            with ThreadPoolExecutor(max_workers=conc) as ex:
                futs = [ex.submit(job, i) for i in range(conc)]
                for f in as_completed(futs):
                    results.append(f.result())
            wall = time.perf_counter() - t0
            total_out = sum(int(r["completion_tokens"]) for r in results)
            agg = total_out / wall if wall > 0 else 0.0
            stream = avg(results, "decode_tok_s")
            ttft = avg(results, "ttft")
            run_rows.append(
                {
                    "ttft": ttft,
                    "agg": agg,
                    "stream": stream,
                    "out": total_out / conc,
                    "wall": wall,
                    "ok": len(results),
                }
            )
            print(
                f"  conc={conc} run={run + 1}/{RUNS} "
                f"ttft={ttft:.3f}s stream_decode={stream:.1f} t/s agg={agg:.1f} t/s"
            )
        table.append(
            [
                f"×{conc}",
                f"{avg(run_rows, 'ttft'):.3f}",
                f"{conc}/{conc}",
                f"{avg(run_rows, 'agg'):.1f}",
                f"{avg(run_rows, 'stream'):.1f}",
                f"{avg(run_rows, 'out'):.0f}",
                f"{avg(run_rows, 'wall'):.2f}",
            ]
        )

    print()
    print_table(headers, table)


def main() -> None:
    resolve_model()
    print("=== Spark vLLM bench (MiaAI-style metrics) ===")
    if WARMUP:
        run_warmup()
    if MODE == "decode":
        mode_decode()
    else:
        mode_deep()
    print("\nNotes:")
    print("  - decode_t/s ≈ completion_tokens / (total_time - ttft)")
    print("  - prefill_t/s ≈ prompt_tokens / ttft (approximation)")
    print("  - THINKING=0 sends chat_template_kwargs.enable_thinking=false when supported")
    print("  - Prompts are salted; still disable server prefix cache for purest numbers if needed")
    print("  - Compare to MiaAI 27B+DFlash tables only with same OUTPUT_LEN and similar input lens")


if __name__ == "__main__":
    main()
PY
