#!/usr/bin/env python3
"""Spark token usage dashboard — scrapes local LLM /metrics, serves UI on :8788."""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

APP_DIR = Path(__file__).resolve().parent
STATIC_DIR = APP_DIR / "static"
DEFAULT_PORTS = (8000, 8001, 8002, 8003)
SCRAPE_INTERVAL_S = 2.0
SAMPLE_KEEP_SECONDS = 4 * 3600  # throughput chart window + buffer
BUCKET_KEEP_DAYS = 400

METRIC_LINE = re.compile(
    r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)"
    r"(?:\{(?P<labels>[^}]*)\})?\s+"
    r"(?P<value>[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)$"
)
LABEL_RE = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"')


def parse_labels(raw: str | None) -> dict[str, str]:
    if not raw:
        return {}
    out: dict[str, str] = {}
    for key, val in LABEL_RE.findall(raw):
        out[key] = val.encode("utf-8").decode("unicode_escape")
    return out


def parse_prometheus(text: str) -> list[tuple[str, dict[str, str], float]]:
    rows: list[tuple[str, dict[str, str], float]] = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        m = METRIC_LINE.match(line.strip())
        if not m:
            continue
        try:
            value = float(m.group("value"))
        except ValueError:
            continue
        rows.append((m.group("name"), parse_labels(m.group("labels")), value))
    return rows


def http_get(url: str, timeout: float = 2.0) -> str | None:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "spark-token-dashboard/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, TimeoutError, OSError):
        return None


class Store:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self.lock = threading.RLock()
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._init_schema()
        # last scraped absolute counters keyed by (port, model)
        self._prev: dict[tuple[int, str], dict[str, float]] = {}
        self._live: dict[str, Any] = {
            "updated_at": 0,
            "online": [],
            "active_requests": 0,
            "waiting_requests": 0,
            "kv_cache_pct": 0.0,
            "output_tok_s_now": 0.0,
        }

    def _init_schema(self) -> None:
        cur = self._conn.cursor()
        cur.executescript(
            """
            CREATE TABLE IF NOT EXISTS minute_buckets (
              minute_ts INTEGER NOT NULL,
              model TEXT NOT NULL,
              port INTEGER NOT NULL,
              prompt_tokens REAL NOT NULL DEFAULT 0,
              generation_tokens REAL NOT NULL DEFAULT 0,
              requests REAL NOT NULL DEFAULT 0,
              busy_seconds REAL NOT NULL DEFAULT 0,
              PRIMARY KEY (minute_ts, model, port)
            );
            CREATE TABLE IF NOT EXISTS samples (
              ts REAL NOT NULL,
              model TEXT NOT NULL,
              port INTEGER NOT NULL,
              generation_tok_s REAL NOT NULL DEFAULT 0,
              running REAL NOT NULL DEFAULT 0,
              waiting REAL NOT NULL DEFAULT 0,
              kv_pct REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
            CREATE TABLE IF NOT EXISTS model_stats (
              model TEXT NOT NULL,
              port INTEGER NOT NULL,
              lifetime_prompt REAL NOT NULL DEFAULT 0,
              lifetime_generation REAL NOT NULL DEFAULT 0,
              lifetime_requests REAL NOT NULL DEFAULT 0,
              lifetime_busy_seconds REAL NOT NULL DEFAULT 0,
              lifetime_ttft_sum REAL NOT NULL DEFAULT 0,
              lifetime_ttft_count REAL NOT NULL DEFAULT 0,
              lifetime_tpot_sum REAL NOT NULL DEFAULT 0,
              lifetime_tpot_count REAL NOT NULL DEFAULT 0,
              peak_parallel REAL NOT NULL DEFAULT 0,
              last_used REAL NOT NULL DEFAULT 0,
              PRIMARY KEY (model, port)
            );
            CREATE TABLE IF NOT EXISTS day_baseline (
              day TEXT NOT NULL,
              model TEXT NOT NULL,
              port INTEGER NOT NULL,
              prompt REAL NOT NULL DEFAULT 0,
              generation REAL NOT NULL DEFAULT 0,
              requests REAL NOT NULL DEFAULT 0,
              PRIMARY KEY (day, model, port)
            );
            """
        )
        self._conn.commit()

    def close(self) -> None:
        with self.lock:
            self._conn.close()

    def ingest_port(self, port: int, metrics_text: str, models_json: str | None, now: float) -> None:
        rows = parse_prometheus(metrics_text)
        by_model: dict[str, dict[str, float]] = {}

        def slot(model: str) -> dict[str, float]:
            if model not in by_model:
                by_model[model] = {
                    "prompt": 0.0,
                    "generation": 0.0,
                    "requests": 0.0,
                    "running": 0.0,
                    "waiting": 0.0,
                    "kv": 0.0,
                    "ttft_sum": 0.0,
                    "ttft_count": 0.0,
                    "tpot_sum": 0.0,
                    "tpot_count": 0.0,
                }
            return by_model[model]

        for name, labels, value in rows:
            model = labels.get("model_name") or labels.get("model") or ""
            if not model:
                continue
            s = slot(model)
            if name == "vllm:prompt_tokens_total":
                s["prompt"] += value
            elif name == "vllm:generation_tokens_total":
                s["generation"] += value
            elif name == "vllm:request_success_total":
                s["requests"] += value
            elif name == "vllm:num_requests_running":
                s["running"] += value
            elif name == "vllm:num_requests_waiting":
                s["waiting"] += value
            elif name == "vllm:kv_cache_usage_perc":
                s["kv"] = max(s["kv"], value)
            elif name == "vllm:time_to_first_token_seconds_sum":
                s["ttft_sum"] += value
            elif name == "vllm:time_to_first_token_seconds_count":
                s["ttft_count"] += value
            elif name == "vllm:request_time_per_output_token_seconds_sum":
                s["tpot_sum"] += value
            elif name == "vllm:request_time_per_output_token_seconds_count":
                s["tpot_count"] += value

        # Fall back to /v1/models id when metrics lack model_name (unlikely for vLLM).
        if not by_model and models_json:
            try:
                data = json.loads(models_json)
                mid = (data.get("data") or [{}])[0].get("id")
                if mid:
                    by_model[mid] = slot(mid)
            except (json.JSONDecodeError, TypeError, IndexError, AttributeError):
                pass

        with self.lock:
            total_running = 0.0
            total_waiting = 0.0
            kv_pct = 0.0
            out_now = 0.0
            online: list[dict[str, Any]] = []

            for model, cur in by_model.items():
                key = (port, model)
                prev = self._prev.get(key)
                d_prompt = d_gen = d_req = 0.0
                d_ttft_sum = d_ttft_count = d_tpot_sum = d_tpot_count = 0.0
                if prev is None:
                    # First sighting after dashboard start: adopt engine absolute
                    # counters into lifetime (so All time matches /metrics), and set
                    # today's baseline to the same values so Today only counts new traffic.
                    self._prev[key] = dict(cur)
                    if cur["prompt"] > 0 or cur["generation"] > 0 or cur["requests"] > 0:
                        self._seed_from_absolute(now=now, model=model, port=port, cur=cur)
                    continue
                else:
                    # Counter reset (engine restart) → treat current as fresh delta from 0.
                    if cur["prompt"] < prev["prompt"] or cur["generation"] < prev["generation"]:
                        d_prompt = cur["prompt"]
                        d_gen = cur["generation"]
                        d_req = cur["requests"]
                        d_ttft_sum = cur["ttft_sum"]
                        d_ttft_count = cur["ttft_count"]
                        d_tpot_sum = cur["tpot_sum"]
                        d_tpot_count = cur["tpot_count"]
                    else:
                        d_prompt = cur["prompt"] - prev["prompt"]
                        d_gen = cur["generation"] - prev["generation"]
                        d_req = cur["requests"] - prev["requests"]
                        d_ttft_sum = cur["ttft_sum"] - prev["ttft_sum"]
                        d_ttft_count = cur["ttft_count"] - prev["ttft_count"]
                        d_tpot_sum = cur["tpot_sum"] - prev["tpot_sum"]
                        d_tpot_count = cur["tpot_count"] - prev["tpot_count"]
                    self._prev[key] = dict(cur)

                busy = 1.0 if cur["running"] > 0 else 0.0
                if d_prompt > 0 or d_gen > 0 or d_req > 0 or busy:
                    self._apply_deltas(
                        now=now,
                        model=model,
                        port=port,
                        d_prompt=max(0.0, d_prompt),
                        d_gen=max(0.0, d_gen),
                        d_req=max(0.0, d_req),
                        busy_seconds=busy * SCRAPE_INTERVAL_S,
                        d_ttft_sum=max(0.0, d_ttft_sum),
                        d_ttft_count=max(0.0, d_ttft_count),
                        d_tpot_sum=max(0.0, d_tpot_sum),
                        d_tpot_count=max(0.0, d_tpot_count),
                        running=cur["running"],
                        waiting=cur["waiting"],
                        kv=cur["kv"] * 100.0,
                        gen_tok_s=(max(0.0, d_gen) / SCRAPE_INTERVAL_S) if SCRAPE_INTERVAL_S else 0.0,
                    )

                total_running += cur["running"]
                total_waiting += cur["waiting"]
                kv_pct = max(kv_pct, cur["kv"] * 100.0)
                if SCRAPE_INTERVAL_S and d_gen > 0:
                    out_now += max(0.0, d_gen) / SCRAPE_INTERVAL_S
                online.append({"model": model, "port": port, "running": cur["running"]})

            # Merge online from this scrape into live snapshot (caller aggregates ports).
            existing = [o for o in self._live.get("online", []) if o.get("port") != port]
            self._live["online"] = existing + online
            self._live["updated_at"] = now
            # Recompute aggregates across remembered live online entries after all ports.
            # Per-port scrape updates running/waiting/kv/out for this pass only — full
            # aggregate happens in scraper after all ports.

    def _seed_from_absolute(self, *, now: float, model: str, port: int, cur: dict[str, float]) -> None:
        """Import engine counters once so All-time matches Prometheus; Today starts at 0."""
        day = time.strftime("%Y-%m-%d", time.localtime(now))
        cur_db = self._conn.cursor()
        existing = cur_db.execute(
            "SELECT lifetime_prompt, lifetime_generation, lifetime_requests FROM model_stats WHERE model=? AND port=?",
            (model, port),
        ).fetchone()
        if existing and (
            existing["lifetime_prompt"] > 0
            or existing["lifetime_generation"] > 0
            or existing["lifetime_requests"] > 0
        ):
            # Ledger already has history from prior dashboard runs — don't clobber.
            return
        prompt = float(cur.get("prompt") or 0.0)
        gen = float(cur.get("generation") or 0.0)
        req = float(cur.get("requests") or 0.0)
        ttft_sum = float(cur.get("ttft_sum") or 0.0)
        ttft_count = float(cur.get("ttft_count") or 0.0)
        tpot_sum = float(cur.get("tpot_sum") or 0.0)
        tpot_count = float(cur.get("tpot_count") or 0.0)
        cur_db.execute(
            """
            INSERT INTO model_stats (
              model, port, lifetime_prompt, lifetime_generation, lifetime_requests,
              lifetime_busy_seconds, lifetime_ttft_sum, lifetime_ttft_count,
              lifetime_tpot_sum, lifetime_tpot_count, peak_parallel, last_used
            ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(model, port) DO UPDATE SET
              lifetime_prompt = excluded.lifetime_prompt,
              lifetime_generation = excluded.lifetime_generation,
              lifetime_requests = excluded.lifetime_requests,
              lifetime_ttft_sum = excluded.lifetime_ttft_sum,
              lifetime_ttft_count = excluded.lifetime_ttft_count,
              lifetime_tpot_sum = excluded.lifetime_tpot_sum,
              lifetime_tpot_count = excluded.lifetime_tpot_count,
              last_used = excluded.last_used
            """,
            (
                model,
                port,
                prompt,
                gen,
                req,
                ttft_sum,
                ttft_count,
                tpot_sum,
                tpot_count,
                float(cur.get("running") or 0.0),
                now if (prompt + gen + req) > 0 else 0.0,
            ),
        )
        # Baseline = current absolute → Today KPI stays 0 until new deltas arrive.
        cur_db.execute(
            """
            INSERT INTO day_baseline (day, model, port, prompt, generation, requests)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(day, model, port) DO UPDATE SET
              prompt = excluded.prompt,
              generation = excluded.generation,
              requests = excluded.requests
            """,
            (day, model, port, prompt, gen, req),
        )
        self._conn.commit()

    def _apply_deltas(
        self,
        *,
        now: float,
        model: str,
        port: int,
        d_prompt: float,
        d_gen: float,
        d_req: float,
        busy_seconds: float,
        d_ttft_sum: float,
        d_ttft_count: float,
        d_tpot_sum: float,
        d_tpot_count: float,
        running: float,
        waiting: float,
        kv: float,
        gen_tok_s: float,
    ) -> None:
        minute_ts = int(now // 60) * 60
        day = time.strftime("%Y-%m-%d", time.localtime(now))
        cur = self._conn.cursor()
        cur.execute(
            """
            INSERT INTO minute_buckets (minute_ts, model, port, prompt_tokens, generation_tokens, requests, busy_seconds)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(minute_ts, model, port) DO UPDATE SET
              prompt_tokens = prompt_tokens + excluded.prompt_tokens,
              generation_tokens = generation_tokens + excluded.generation_tokens,
              requests = requests + excluded.requests,
              busy_seconds = busy_seconds + excluded.busy_seconds
            """,
            (minute_ts, model, port, d_prompt, d_gen, d_req, busy_seconds),
        )
        cur.execute(
            """
            INSERT INTO samples (ts, model, port, generation_tok_s, running, waiting, kv_pct)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (now, model, port, gen_tok_s, running, waiting, kv),
        )
        cur.execute(
            """
            INSERT INTO model_stats (
              model, port, lifetime_prompt, lifetime_generation, lifetime_requests,
              lifetime_busy_seconds, lifetime_ttft_sum, lifetime_ttft_count,
              lifetime_tpot_sum, lifetime_tpot_count, peak_parallel, last_used
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(model, port) DO UPDATE SET
              lifetime_prompt = lifetime_prompt + excluded.lifetime_prompt,
              lifetime_generation = lifetime_generation + excluded.lifetime_generation,
              lifetime_requests = lifetime_requests + excluded.lifetime_requests,
              lifetime_busy_seconds = lifetime_busy_seconds + excluded.lifetime_busy_seconds,
              lifetime_ttft_sum = lifetime_ttft_sum + excluded.lifetime_ttft_sum,
              lifetime_ttft_count = lifetime_ttft_count + excluded.lifetime_ttft_count,
              lifetime_tpot_sum = lifetime_tpot_sum + excluded.lifetime_tpot_sum,
              lifetime_tpot_count = lifetime_tpot_count + excluded.lifetime_tpot_count,
              peak_parallel = MAX(peak_parallel, excluded.peak_parallel),
              last_used = CASE
                WHEN excluded.lifetime_prompt + excluded.lifetime_generation + excluded.lifetime_requests > 0
                THEN excluded.last_used ELSE last_used END
            """,
            (
                model,
                port,
                d_prompt,
                d_gen,
                d_req,
                busy_seconds,
                d_ttft_sum,
                d_ttft_count,
                d_tpot_sum,
                d_tpot_count,
                running,
                now if (d_prompt + d_gen + d_req) > 0 else 0.0,
            ),
        )
        # Snapshot lifetime totals at the start of each calendar day for "today/yesterday".
        cur.execute(
            "SELECT 1 FROM day_baseline WHERE day=? AND model=? AND port=?",
            (day, model, port),
        )
        if cur.fetchone() is None:
            row = cur.execute(
                "SELECT lifetime_prompt, lifetime_generation, lifetime_requests FROM model_stats WHERE model=? AND port=?",
                (model, port),
            ).fetchone()
            # Baseline = totals BEFORE today's deltas (subtract what we just added).
            base_p = (row["lifetime_prompt"] if row else 0) - d_prompt
            base_g = (row["lifetime_generation"] if row else 0) - d_gen
            base_r = (row["lifetime_requests"] if row else 0) - d_req
            cur.execute(
                """
                INSERT INTO day_baseline (day, model, port, prompt, generation, requests)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (day, model, port, max(0.0, base_p), max(0.0, base_g), max(0.0, base_r)),
            )
        self._conn.commit()

    def set_live_aggregate(
        self,
        *,
        now: float,
        online: list[dict[str, Any]],
        active: float,
        waiting: float,
        kv_pct: float,
        out_tok_s: float,
    ) -> None:
        with self.lock:
            self._live = {
                "updated_at": now,
                "online": online,
                "active_requests": active,
                "waiting_requests": waiting,
                "kv_cache_pct": kv_pct,
                "output_tok_s_now": out_tok_s,
            }

    def prune(self, now: float) -> None:
        with self.lock:
            cur = self._conn.cursor()
            cur.execute("DELETE FROM samples WHERE ts < ?", (now - SAMPLE_KEEP_SECONDS,))
            cutoff = int(now) - BUCKET_KEEP_DAYS * 86400
            cur.execute("DELETE FROM minute_buckets WHERE minute_ts < ?", (cutoff,))
            self._conn.commit()

    def snapshot(self, model_filter: str | None = None) -> dict[str, Any]:
        with self.lock:
            now = time.time()
            local = time.localtime(now)
            today = time.strftime("%Y-%m-%d", local)
            # Yesterday calendar day
            yday = time.strftime("%Y-%m-%d", time.localtime(now - 86400))
            day_start = time.mktime(time.strptime(today, "%Y-%m-%d"))
            yday_start = time.mktime(time.strptime(yday, "%Y-%m-%d"))
            h24 = now - 86400

            models = self._conn.execute("SELECT * FROM model_stats ORDER BY last_used DESC, model").fetchall()
            if model_filter and model_filter != "all":
                models = [m for m in models if m["model"] == model_filter]

            def sum_buckets(since_ts: float) -> tuple[float, float, float]:
                q = """
                  SELECT COALESCE(SUM(prompt_tokens),0), COALESCE(SUM(generation_tokens),0), COALESCE(SUM(requests),0)
                  FROM minute_buckets WHERE minute_ts >= ?
                """
                args: list[Any] = [int(since_ts)]
                if model_filter and model_filter != "all":
                    q += " AND model = ?"
                    args.append(model_filter)
                row = self._conn.execute(q, args).fetchone()
                return float(row[0]), float(row[1]), float(row[2])

            def day_totals(day: str) -> tuple[float, float, float]:
                # lifetime now - baseline at day start, for matching models
                total_p = total_g = total_r = 0.0
                for m in models:
                    base = self._conn.execute(
                        "SELECT prompt, generation, requests FROM day_baseline WHERE day=? AND model=? AND port=?",
                        (day, m["model"], m["port"]),
                    ).fetchone()
                    if base is None:
                        # No baseline yet for that day — fall back to minute buckets for that calendar day.
                        continue
                    total_p += max(0.0, m["lifetime_prompt"] - base["prompt"])
                    total_g += max(0.0, m["lifetime_generation"] - base["generation"])
                    total_r += max(0.0, m["lifetime_requests"] - base["requests"])
                if total_p == 0 and total_g == 0 and total_r == 0:
                    # Fallback for days without baseline rows
                    if day == today:
                        return sum_buckets(day_start)
                    if day == yday:
                        p, g, r = sum_buckets(yday_start)
                        p2, g2, r2 = sum_buckets(day_start)
                        return p - p2, g - g2, r - r2
                return total_p, total_g, total_r

            today_p, today_g, today_r = day_totals(today)
            yday_p, yday_g, yday_r = day_totals(yday)
            h24_p, h24_g, h24_r = sum_buckets(h24)
            all_p = sum(m["lifetime_prompt"] for m in models)
            all_g = sum(m["lifetime_generation"] for m in models)
            all_r = sum(m["lifetime_requests"] for m in models)

            # Hourly series last 24h (local-time hour boundaries)
            hours: list[dict[str, Any]] = []
            hour_now = time.mktime(
                (
                    local.tm_year,
                    local.tm_mon,
                    local.tm_mday,
                    local.tm_hour,
                    0,
                    0,
                    local.tm_wday,
                    local.tm_yday,
                    local.tm_isdst,
                )
            )
            for i in range(23, -1, -1):
                hs = hour_now - i * 3600
                he = hs + 3600
                q = """
                  SELECT COALESCE(SUM(prompt_tokens),0), COALESCE(SUM(generation_tokens),0)
                  FROM minute_buckets WHERE minute_ts >= ? AND minute_ts < ?
                """
                args: list[Any] = [hs, he]
                if model_filter and model_filter != "all":
                    q += " AND model = ?"
                    args.append(model_filter)
                row = self._conn.execute(q, args).fetchone()
                hours.append(
                    {
                        "ts": int(hs),
                        "label": time.strftime("%I:%M %p", time.localtime(hs)).lstrip("0"),
                        "prompt": float(row[0]),
                        "generation": float(row[1]),
                    }
                )

            # 1-minute throughput over last 3h
            throughput: list[dict[str, Any]] = []
            t_start = now - 3 * 3600
            q = """
              SELECT CAST(ts / 60 AS INTEGER) * 60 AS minute_ts,
                     COALESCE(SUM(generation_tok_s), 0) AS tok_s
              FROM samples WHERE ts >= ?
            """
            args = [t_start]
            if model_filter and model_filter != "all":
                q += " AND model = ?"
                args.append(model_filter)
            q += " GROUP BY minute_ts ORDER BY minute_ts"
            for row in self._conn.execute(q, args):
                throughput.append({"ts": int(row["minute_ts"]), "tok_s": float(row["tok_s"])})

            # Per-model table (lifetime + today)
            model_rows = []
            online_ports = {(o["model"], o["port"]) for o in self._live.get("online", [])}
            for m in models:
                req = m["lifetime_requests"]
                prompt = m["lifetime_prompt"]
                gen = m["lifetime_generation"]
                busy = m["lifetime_busy_seconds"]
                ttft = (m["lifetime_ttft_sum"] / m["lifetime_ttft_count"]) if m["lifetime_ttft_count"] else None
                writing = None
                if m["lifetime_tpot_count"] and m["lifetime_tpot_sum"] > 0:
                    writing = m["lifetime_tpot_count"] / m["lifetime_tpot_sum"]
                out_busy = (gen / busy) if busy > 0 else None
                reading = None
                if m["lifetime_ttft_sum"] > 0 and prompt > 0:
                    reading = prompt / m["lifetime_ttft_sum"]
                elif busy > 0 and prompt > 0:
                    reading = prompt / busy
                base = self._conn.execute(
                    "SELECT prompt, generation, requests FROM day_baseline WHERE day=? AND model=? AND port=?",
                    (today, m["model"], m["port"]),
                ).fetchone()
                if base:
                    today_prompt = max(0.0, prompt - base["prompt"])
                    today_gen = max(0.0, gen - base["generation"])
                    today_req = max(0.0, req - base["requests"])
                else:
                    row = self._conn.execute(
                        """
                        SELECT COALESCE(SUM(prompt_tokens),0), COALESCE(SUM(generation_tokens),0), COALESCE(SUM(requests),0)
                        FROM minute_buckets WHERE minute_ts >= ? AND model=? AND port=?
                        """,
                        (int(day_start), m["model"], m["port"]),
                    ).fetchone()
                    today_prompt, today_gen, today_req = float(row[0]), float(row[1]), float(row[2])
                model_rows.append(
                    {
                        "model": m["model"],
                        "port": m["port"],
                        "running": (m["model"], m["port"]) in online_ports,
                        "requests": req,
                        "prompt_tokens": prompt,
                        "generation_tokens": gen,
                        "avg_tokens_per_request": ((prompt + gen) / req) if req else None,
                        "ttft_s": ttft,
                        "reading_tok_s": reading,
                        "writing_tok_s": writing,
                        "output_while_busy_tok_s": out_busy,
                        "peak_parallel": m["peak_parallel"],
                        "last_used": m["last_used"] or None,
                        "today": {
                            "requests": today_req,
                            "prompt_tokens": today_prompt,
                            "generation_tokens": today_gen,
                            "avg_tokens_per_request": ((today_prompt + today_gen) / today_req) if today_req else None,
                        },
                    }
                )

            known_models = sorted({m["model"] for m in self._conn.execute("SELECT DISTINCT model FROM model_stats")})
            for o in self._live.get("online", []):
                if o["model"] not in known_models:
                    known_models.append(o["model"])

            return {
                "updated_at": self._live.get("updated_at", now),
                "online": self._live.get("online", []),
                "models": known_models,
                "kpis": {
                    "today": {"prompt": today_p, "generation": today_g, "total": today_p + today_g, "requests": today_r},
                    "yesterday": {"prompt": yday_p, "generation": yday_g, "total": yday_p + yday_g, "requests": yday_r},
                    "last_24h": {"prompt": h24_p, "generation": h24_g, "total": h24_p + h24_g, "requests": h24_r},
                    "all_time": {"prompt": all_p, "generation": all_g, "total": all_p + all_g, "requests": all_r},
                },
                "live": {
                    "requests_today": today_r,
                    "avg_tokens_per_request": ((today_p + today_g) / today_r) if today_r else None,
                    "output_tok_s_now": self._live.get("output_tok_s_now", 0.0),
                    "active_requests": self._live.get("active_requests", 0),
                    "waiting_requests": self._live.get("waiting_requests", 0),
                    "kv_cache_pct": self._live.get("kv_cache_pct", 0.0),
                },
                "hourly": hours,
                "throughput": throughput,
                "table": model_rows,
                "system_dashboard_port": int(os.environ.get("SYSTEM_DASHBOARD_PORT", "8787")),
            }


class Scraper(threading.Thread):
    def __init__(self, store: Store, ports: list[int]) -> None:
        super().__init__(daemon=True, name="token-scraper")
        self.store = store
        self.ports = ports
        self._stop = threading.Event()

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        while not self._stop.is_set():
            now = time.time()
            online: list[dict[str, Any]] = []
            active = waiting = kv = out_s = 0.0
            for port in self.ports:
                metrics = http_get(f"http://127.0.0.1:{port}/metrics")
                if metrics is None:
                    continue
                models_json = http_get(f"http://127.0.0.1:{port}/v1/models")
                # Parse quickly for live aggregates before ingest mutates.
                rows = parse_prometheus(metrics)
                port_online: dict[str, dict[str, float]] = {}
                for name, labels, value in rows:
                    model = labels.get("model_name") or labels.get("model")
                    if not model:
                        continue
                    slot = port_online.setdefault(model, {"running": 0.0, "waiting": 0.0, "kv": 0.0, "gen": 0.0})
                    if name == "vllm:num_requests_running":
                        slot["running"] += value
                    elif name == "vllm:num_requests_waiting":
                        slot["waiting"] += value
                    elif name == "vllm:kv_cache_usage_perc":
                        slot["kv"] = max(slot["kv"], value * 100.0)
                self.store.ingest_port(port, metrics, models_json, now)
                for model, slot in port_online.items():
                    online.append({"model": model, "port": port, "running": slot["running"]})
                    active += slot["running"]
                    waiting += slot["waiting"]
                    kv = max(kv, slot["kv"])
            # output tok/s from recent samples (last scrape window)
            with self.store.lock:
                row = self.store._conn.execute(
                    "SELECT COALESCE(SUM(generation_tok_s),0) FROM samples WHERE ts >= ?",
                    (now - SCRAPE_INTERVAL_S * 1.5,),
                ).fetchone()
                out_s = float(row[0]) if row else 0.0
            self.store.set_live_aggregate(
                now=now, online=online, active=active, waiting=waiting, kv_pct=kv, out_tok_s=out_s
            )
            if int(now) % 300 < SCRAPE_INTERVAL_S:
                self.store.prune(now)
            self._stop.wait(SCRAPE_INTERVAL_S)


def make_handler(store: Store) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "SparkTokenDashboard/1.0"

        def log_message(self, fmt: str, *args: Any) -> None:
            return

        def _send(self, code: int, body: bytes, content_type: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, code: int, payload: Any) -> None:
            self._send(code, json.dumps(payload).encode("utf-8"), "application/json; charset=utf-8")

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            path = parsed.path
            if path in ("/api/health", "/health"):
                self._json(200, {"status": "ok", "service": "spark-token-dashboard"})
                return
            if path == "/api/summary":
                qs = parse_qs(parsed.query)
                model = (qs.get("model") or ["all"])[0]
                self._json(200, store.snapshot(None if model == "all" else model))
                return
            # static
            rel = "index.html" if path in ("/", "") else path.lstrip("/")
            if ".." in rel or rel.startswith("/"):
                self._send(400, b"bad path", "text/plain")
                return
            file_path = (STATIC_DIR / rel).resolve()
            if not str(file_path).startswith(str(STATIC_DIR.resolve())) or not file_path.is_file():
                self._send(404, b"not found", "text/plain")
                return
            data = file_path.read_bytes()
            ctype = {
                ".html": "text/html; charset=utf-8",
                ".js": "application/javascript; charset=utf-8",
                ".css": "text/css; charset=utf-8",
                ".svg": "image/svg+xml",
                ".png": "image/png",
                ".ico": "image/x-icon",
            }.get(file_path.suffix.lower(), "application/octet-stream")
            self._send(200, data, ctype)

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description="Spark token usage dashboard")
    parser.add_argument("--host", default=os.environ.get("TOKEN_DASH_BIND", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("TOKEN_DASH_PORT", "8788")))
    parser.add_argument(
        "--ports",
        default=os.environ.get("TOKEN_DASH_LLM_PORTS", ",".join(str(p) for p in DEFAULT_PORTS)),
        help="Comma-separated LLM ports to scrape",
    )
    parser.add_argument(
        "--db",
        default=os.environ.get(
            "TOKEN_DASH_DB",
            str(Path.home() / ".local/share/spark-token-dashboard/ledger.sqlite"),
        ),
    )
    args = parser.parse_args()
    llm_ports = [int(p.strip()) for p in args.ports.split(",") if p.strip()]
    store = Store(Path(args.db))
    scraper = Scraper(store, llm_ports)
    scraper.start()
    handler = make_handler(store)
    httpd = ThreadingHTTPServer((args.host, args.port), handler)
    print(f"[spark-token-dashboard] http://{args.host}:{args.port}  db={args.db}  llm={llm_ports}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        scraper.stop()
        httpd.server_close()
        store.close()


if __name__ == "__main__":
    main()
