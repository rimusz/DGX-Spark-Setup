(() => {
  const POLL_MS = 5000;
  let tableRange = "all"; // all | today
  let lastPayload = null;

  const $ = (id) => document.getElementById(id);

  function fmtTokens(n) {
    if (n == null || Number.isNaN(n)) return "—";
    const abs = Math.abs(n);
    if (abs >= 1e9) return (n / 1e9).toFixed(1).replace(/\.0$/, "") + "B";
    if (abs >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
    if (abs >= 1e3) return (n / 1e3).toFixed(1).replace(/\.0$/, "") + "K";
    return String(Math.round(n));
  }

  function fmtTokS(n) {
    if (n == null || Number.isNaN(n)) return "—";
    if (n >= 100) return n.toFixed(0);
    return n.toFixed(1);
  }

  function fmtSeconds(n) {
    if (n == null || Number.isNaN(n)) return "—";
    if (n < 1) return (n * 1000).toFixed(0) + " ms";
    return n.toFixed(1) + " s";
  }

  function fmtAgo(ts) {
    if (!ts) return "—";
    const sec = Math.max(0, (Date.now() / 1000) - ts);
    if (sec < 60) return "just now";
    if (sec < 3600) return Math.floor(sec / 60) + "m ago";
    if (sec < 86400) return Math.floor(sec / 3600) + "h ago";
    return Math.floor(sec / 86400) + "d ago";
  }

  function fmtClock(ts) {
    if (!ts) return "";
    return new Date(ts * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  }

  function fmtHour(ts) {
    return new Date(ts * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  function card(label, value, subHtml) {
    return `<div class="card"><div class="label">${label}</div><div class="value">${value}</div>${
      subHtml ? `<div class="sub">${subHtml}</div>` : ""
    }</div>`;
  }

  function ioSub(prompt, generation) {
    return `<div class="sub-split"><span><i class="swatch in" aria-hidden="true"></i>${fmtTokens(prompt)} in</span><span><i class="swatch out" aria-hidden="true"></i>${fmtTokens(generation)} out</span></div>`;
  }

  function renderBarChart(el, values, color) {
    const max = Math.max(...values.map((v) => v.y), 1);
    const yTicks = [max, max * (2 / 3), max / 3, 0].map((v) => fmtTokens(v));
    const labelIdx = new Set([0, 6, 12, 18, values.length - 1].filter((i) => i >= 0 && i < values.length));
    const xLabels = [...labelIdx].sort((a, b) => a - b).map((i) => fmtHour(values[i].ts));

    const bars = values.map((v) => {
      const pct = v.y > 0 ? Math.max(2, (v.y / max) * 100) : 0;
      const zero = v.y <= 0 ? " is-zero" : "";
      const h = v.y > 0 ? pct : 1;
      const title = `${fmtHour(v.ts)} · ${fmtTokens(v.y)}`;
      return `<div class="bar-col" title="${title}"><div class="bar${zero}" style="height:${h}%;background:${color}"></div></div>`;
    }).join("");

    el.innerHTML = `
      <div class="bar-y">${yTicks.map((t) => `<span>${t}</span>`).join("")}</div>
      <div class="bar-plot">${bars}</div>
      <div class="bar-x">${xLabels.map((t) => `<span>${t}</span>`).join("")}</div>
    `;
  }

  function prepareCanvas(canvas) {
    const dpr = window.devicePixelRatio || 1;
    const cssW = Math.max(1, canvas.clientWidth || canvas.parentElement?.clientWidth || 600);
    const cssH = 140;
    canvas.style.width = cssW + "px";
    canvas.style.height = cssH + "px";
    canvas.width = Math.floor(cssW * dpr);
    canvas.height = Math.floor(cssH * dpr);
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, cssW, cssH);
    return { ctx, cssW, cssH };
  }

  function drawLine(canvas, values, color) {
    const { ctx, cssW, cssH } = prepareCanvas(canvas);
    const padL = 36, padR = 10, padT = 10, padB = 24;
    const w = cssW - padL - padR;
    const h = cssH - padT - padB;
    const max = Math.max(...values.map((v) => v.y), 1);
    for (let i = 0; i <= 3; i++) {
      const y = padT + (h * i) / 3;
      ctx.strokeStyle = "rgba(255,255,255,0.06)";
      ctx.beginPath();
      ctx.moveTo(padL, y);
      ctx.lineTo(padL + w, y);
      ctx.stroke();
      ctx.fillStyle = "#8b93a7";
      ctx.font = "10px ui-monospace, Menlo, monospace";
      ctx.textAlign = "right";
      ctx.fillText(fmtTokS(max * (1 - i / 3)), padL - 6, y + 3);
    }
    if (!values.length) return;
    ctx.beginPath();
    values.forEach((v, i) => {
      const x = padL + (i / Math.max(values.length - 1, 1)) * w;
      const y = padT + h - (v.y / max) * h;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.stroke();
    const first = values[0];
    const last = values[values.length - 1];
    ctx.fillStyle = "#8b93a7";
    ctx.font = "10px ui-monospace, Menlo, monospace";
    ctx.textAlign = "left";
    ctx.fillText(fmtClock(first.ts), padL, cssH - 6);
    ctx.textAlign = "right";
    ctx.fillText(fmtClock(last.ts), padL + w, cssH - 6);
  }

  function render(data) {
    lastPayload = data;
    const online = data.online || [];
    const status = $("status");
    const statusText = $("statusText");
    if (online.length) {
      status.classList.remove("is-off");
      const parts = online.map((o) => `${o.model} :${o.port}`).join(", ");
      statusText.textContent = `Online: ${parts} · updated ${fmtClock(data.updated_at)}`;
    } else {
      status.classList.add("is-off");
      statusText.textContent = `No LLM online · updated ${fmtClock(data.updated_at)}`;
    }

    const sel = $("modelFilter");
    const current = sel.value || "all";
    const models = data.models || [];
    sel.innerHTML = `<option value="all">All models</option>` + models.map((m) =>
      `<option value="${m}">${m}</option>`
    ).join("");
    sel.value = models.includes(current) || current === "all" ? current : "all";

    const sysPort = data.system_dashboard_port || 8787;
    const host = location.hostname || "127.0.0.1";
    $("systemLink").href = `http://${host}:${sysPort}`;

    const k = data.kpis;
    $("kpis").innerHTML = [
      card("Tokens today", fmtTokens(k.today.total), ioSub(k.today.prompt, k.today.generation)),
      card("Yesterday", fmtTokens(k.yesterday.total), ioSub(k.yesterday.prompt, k.yesterday.generation)),
      card("Last 24 hours", fmtTokens(k.last_24h.total), ioSub(k.last_24h.prompt, k.last_24h.generation)),
      card("All time", fmtTokens(k.all_time.total), ioSub(k.all_time.prompt, k.all_time.generation)),
    ].join("");

    const live = data.live;
    const waiting = live.waiting_requests || 0;
    $("live").innerHTML = [
      card(
        "Requests today",
        Math.round(live.requests_today || 0).toLocaleString(),
        live.avg_tokens_per_request != null
          ? `Average ${fmtTokens(live.avg_tokens_per_request)} tokens / request`
          : "No requests yet"
      ),
      card("Output speed now", fmtTokS(live.output_tok_s_now) + " tok/s", "last minute, all requests"),
      card(
        "Active requests",
        String(Math.round(live.active_requests || 0)),
        waiting ? `${Math.round(waiting)} waiting` : "none waiting"
      ),
      card("KV cache used", (live.kv_cache_pct || 0).toFixed(1) + "%", "context memory in use"),
    ].join("");

    const css = getComputedStyle(document.documentElement);
    const blue = (css.getPropertyValue("--blue") || "#2ea0ff").trim();
    const orange = (css.getPropertyValue("--orange") || "#ff9a2e").trim();

    const hourly = data.hourly || [];
    renderBarChart($("inChart"), hourly.map((h) => ({ y: h.prompt, ts: h.ts })), blue);
    renderBarChart($("outChart"), hourly.map((h) => ({ y: h.generation, ts: h.ts })), orange);

    const tp = data.throughput || [];
    const nowMin = Math.floor(Date.now() / 1000 / 60) * 60;
    const byTs = Object.fromEntries(tp.map((p) => [p.ts, p.tok_s]));
    const series = [];
    for (let t = nowMin - 3 * 3600; t <= nowMin; t += 60) {
      series.push({ ts: t, y: byTs[t] || 0 });
    }
    drawLine($("tpChart"), series, orange);

    renderTable(data);
  }

  function renderTable(data) {
    const body = $("modelBody");
    const rows = (data.table || []).slice().sort((a, b) => (b.last_used || 0) - (a.last_used || 0));
    if (!rows.length) {
      body.innerHTML = `<tr><td colspan="11" style="color:#8b93a7">No token traffic recorded yet — make a request to the serving model.</td></tr>`;
      return;
    }
    body.innerHTML = rows.map((r) => {
      const useToday = tableRange === "today";
      const src = useToday && r.today ? r.today : r;
      const req = src.requests;
      const inp = src.prompt_tokens;
      const out = src.generation_tokens;
      const avg = src.avg_tokens_per_request != null
        ? src.avg_tokens_per_request
        : (req ? (inp + out) / req : null);
      return `<tr>
        <td class="model-cell">${r.model}${r.running ? '<span class="running"><span class="dot" aria-hidden="true"></span>running</span>' : ""} <span style="color:#8b93a7;font-weight:400">:${r.port}</span></td>
        <td class="num">${Math.round(req).toLocaleString()}</td>
        <td class="num">${fmtTokens(inp)}</td>
        <td class="num">${fmtTokens(out)}</td>
        <td class="num">${avg != null ? fmtTokens(avg) : "—"}</td>
        <td class="num">${fmtSeconds(r.ttft_s)}</td>
        <td class="num">${r.reading_tok_s != null ? fmtTokS(r.reading_tok_s) + " tok/s" : "—"}</td>
        <td class="num">${r.writing_tok_s != null ? fmtTokS(r.writing_tok_s) + " tok/s" : "—"}</td>
        <td class="num">${r.output_while_busy_tok_s != null ? fmtTokS(r.output_while_busy_tok_s) + " tok/s" : "—"}</td>
        <td class="num">${Math.round(r.peak_parallel || 0)}</td>
        <td class="num">${fmtAgo(r.last_used)}</td>
      </tr>`;
    }).join("");
  }

  async function refresh() {
    const model = $("modelFilter").value || "all";
    const res = await fetch(`/api/summary?model=${encodeURIComponent(model)}`, { cache: "no-store" });
    if (!res.ok) throw new Error("summary " + res.status);
    render(await res.json());
  }

  $("modelFilter").addEventListener("change", () => { refresh().catch(console.error); });
  $("rangeAll").addEventListener("click", () => {
    tableRange = "all";
    $("rangeAll").classList.add("is-on");
    $("rangeToday").classList.remove("is-on");
    if (lastPayload) renderTable(lastPayload);
  });
  $("rangeToday").addEventListener("click", () => {
    tableRange = "today";
    $("rangeToday").classList.add("is-on");
    $("rangeAll").classList.remove("is-on");
    if (lastPayload) renderTable(lastPayload);
  });
  window.addEventListener("resize", () => { if (lastPayload) render(lastPayload); });

  refresh().catch((e) => {
    const status = $("status");
    status.classList.add("is-off");
    $("statusText").textContent = "Failed to load: " + e.message;
  });
  setInterval(() => refresh().catch(console.error), POLL_MS);
})();
