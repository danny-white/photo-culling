"use strict";
const $ = (s, r = document) => r.querySelector(s);
const api = (p) => fetch(p).then(r => r.json());
const post = (p, b) => fetch(p, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(b)}).then(r => r.json());
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[c]));
function toast(m) { const t = $("#toast"); t.textContent = m; t.classList.add("show"); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("show"), 1700); }

/* ------------------------------------------------ monitor view + poll */
function timeAgo(iso) {
  if (!iso) return "&mdash;";
  // processed_at is written by Python's isoformat() and already carries an explicit UTC
  // offset (e.g. "...+00:00") -- appending "Z" here would double up the offset and parse as NaN.
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (s < 5) return "just now";
  if (s < 90) return Math.round(s) + "s ago";
  if (s < 5400) return Math.round(s / 60) + "m ago";
  return Math.round(s / 3600) + "h ago";
}
function mdY(isoDate) {
  if (!isoDate) return "&mdash;";
  const [y, m, d] = isoDate.split("-");
  return `${m}/${d}/${y}`;
}
function folderBar(done, total) {
  const pct = total ? 100 * done / total : 0;
  return `<span class="track" style="width:70px;display:inline-block;vertical-align:middle"><i style="width:${pct}%"></i></span>`;
}
async function loadMonitor() {
  const d = await api("/api/monitor"), c = d.counts;
  const pct = c.total ? 100 * c.ok / c.total : 0;
  const srcLine = d.sources.length
    ? d.sources.map(s => `<span style="color:var(--keep)">&#9679;</span> ${s.folders.map(f => esc(f.split("/").slice(-2).join("/"))).join(", ") || "pid " + s.pid} <span class="muted">(${Math.round(s.elapsed_s / 60)}m)</span>`).join(" &middot; ")
    : '<span style="color:var(--ink-3)">&#9675; idle</span>';
  $("#monitor-body").innerHTML = `<div class="cols">
    <div class="panel"><h2 class="h">Across the library</h2>
      <div class="stat-row">
        <div class="s"><div class="n">${c.ok.toLocaleString()}</div><div class="l">done</div></div>
        <div class="s"><div class="n">${c.pending.toLocaleString()}</div><div class="l">pending</div></div>
        <div class="s"><div class="n" style="color:var(--reject)">${c.error}</div><div class="l">errors</div></div>
        <div class="s"><div class="n">${d.img_per_hr || "&mdash;"}</div><div class="l">img/hr</div></div>
        <div class="s"><div class="n">${d.eta_hours == null ? "&mdash;" : d.eta_hours + "h"}</div><div class="l">eta</div></div></div>
      <div class="bar" style="height:9px"><i style="display:block;height:100%;width:${pct}%;background:linear-gradient(90deg,var(--accent),#6fd0e4)"></i></div>
      <div class="muted" style="margin-top:8px">${srcLine}${d.gpu ? " &middot; GPU " + d.gpu.used_mb + "/" + d.gpu.total_mb + "MB &middot; " + d.gpu.util + "%" : ""}</div>
      <div style="display:flex;gap:8px;margin-top:14px;flex-wrap:wrap">
        <button class="btn warn" id="i-pause" ${d.running ? "" : "disabled"}>Pause all (${d.sources.length})</button>
        <button class="btn" id="i-resume" ${d.running ? "disabled" : ""}>Resume</button>
        <button class="btn" id="i-redrive" ${d.running || !c.error ? "disabled" : ""}>Redrive ${c.error} errors</button>
        <button class="btn" id="i-export">Export snapshot</button>
        <button class="btn ${d.timer.active ? "warn" : ""}" id="i-timer">${d.timer.active ? "Bulk runs: ON (turn off)" : "Bulk runs: OFF (turn on)"}</button></div>
      <div class="muted" style="margin-top:6px">${d.timer.active ? "Timer is armed -- polls the inbox every 15 min and uses the GPU when there's work." : "Timer is off -- nothing will auto-start until you turn it back on."}</div></div>
    <div class="panel"><h2 class="h">Last processed</h2>${lastProcessedHtml(d.last_processed)}</div>
    </div>
    <div class="panel" style="margin-top:14px"><h2 class="h">Timeline</h2>${timelineHtml(d.recent5, d.next5)}</div>
    <div class="cols" style="margin-top:14px">
    <div class="panel"><h2 class="h">By year</h2>
      <div class="foldertable-wrap"><table class="errtable foldertable"><tr><th>Year</th><th>Done</th><th></th><th>Pend.</th><th>Err</th></tr>
      ${d.by_year.map(y => `<tr><td>${esc(y.year)}</td><td class="n">${y.ok}/${y.total}</td>` +
        `<td>${folderBar(y.ok, y.total)}</td><td class="n">${y.pending || ""}</td>` +
        `<td class="n" style="color:var(--reject)">${y.error || ""}</td></tr>`).join("")}</table></div></div>
    <div class="panel"><h2 class="h">Errors by class</h2>
      ${d.errors_by_class.length ? '<table class="errtable">' + d.errors_by_class.map(e => `<tr><td>${esc(e.error_class)}</td><td class="n">${e.c}</td></tr>`).join("") + "</table>" : '<div class="muted">none</div>'}</div>
    </div>
    <div class="panel" style="margin-top:14px"><h2 class="h">Needs attention <span class="muted">(folders not fully done)</span></h2>
      ${d.attention.length ? '<div class="foldertable-wrap"><table class="errtable foldertable"><tr><th>Folder</th><th>Done</th><th></th><th>Pend.</th><th>Err</th><th>Last activity</th></tr>' +
        d.attention.map(f => `<tr><td>${esc(f.folder)}</td><td class="n">${f.ok}/${f.total}</td>` +
          `<td>${folderBar(f.ok, f.total)}</td><td class="n">${f.pending || ""}</td>` +
          `<td class="n" style="color:var(--reject)">${f.error || ""}</td><td class="muted">${timeAgo(f.last)}</td></tr>`).join("") +
        "</table></div>" + (d.attention_more ? `<div class="muted" style="margin-top:8px">+${d.attention_more} more folder(s) queued</div>` : "")
        : '<div class="muted">nothing queued — everything the DB knows about is fully processed</div>'}</div>`;
  const act = async (a, confirmMsg) => { if (confirmMsg && !confirm(confirmMsg)) return; const r = await post("/api/intervene", { action: a }); toast(r.msg || (r.ok ? "ok" : "failed")); setTimeout(loadMonitor, 900); };
  $("#i-pause").onclick = () => act("pause", "Stop all active runs? It's safe — resumes exactly where it left off.");
  $("#i-resume").onclick = () => act("resume");
  $("#i-redrive").onclick = () => act("redrive");
  $("#i-export").onclick = () => act("export");
  $("#i-timer").onclick = () => act(d.timer.active ? "timer_off" : "timer_on",
    d.timer.active ? "Turn off bulk runs? Any active run stops too (safe -- resumes exactly where it left off). Flip it back on any time." : null);
  const lpImg = $("#monitor-body .lp-thumb");
  if (lpImg) lpImg.onclick = () => openLightbox(d.last_processed.rowid, d.last_processed.filename);
}
function openLightbox(rowid, alt) {
  const ov = document.createElement("div");
  ov.className = "lightbox";
  ov.innerHTML = `<img src="/api/thumb/${rowid}?s=loupe" alt="${esc(alt || "")}">`;
  const close = () => { ov.remove(); document.removeEventListener("keydown", onKeyClose); };
  const onKeyClose = (e) => { if (e.key === "Escape") close(); };
  ov.onclick = close;
  document.addEventListener("keydown", onKeyClose);
  document.body.appendChild(ov);
}
function lastProcessedHtml(lp) {
  if (!lp) return '<div class="muted">nothing processed yet</div>';
  const when = timeAgo(lp.processed_at);
  if (lp.status !== "ok") {
    return `<div class="fn" style="font-family:var(--mono);font-size:12px;margin-bottom:6px">${esc(lp.filename)} <span class="muted">${lp.shoot_date || ""} &middot; ${when}</span></div>
      <div class="errbox">[${esc(lp.error_class || "?")}] ${esc(lp.error_msg || "")}</div>`;
  }
  const facts = [];
  if (lp.scene) facts.push(lp.scene);
  if (lp.indoor_outdoor && lp.indoor_outdoor !== "unknown") facts.push(lp.indoor_outdoor);
  if (lp.time_of_day && lp.time_of_day !== "unknown") facts.push(lp.time_of_day.replace("_", " "));
  if (lp.activity) facts.push(lp.activity);
  if (lp.content_type && lp.content_type !== "photo") facts.push(lp.content_type);
  if (lp.monochrome) facts.push("monochrome");
  const factsLine = facts.length
    ? `<div class="muted" style="margin-top:4px">${facts.map(esc).join(" &middot; ")}</div>` : "";
  const textLine = lp.visible_text
    ? `<div class="muted" style="margin-top:4px">&#128221; &ldquo;${esc(lp.visible_text)}&rdquo;</div>` : "";
  const chips = [...(lp.tags || []), ...(lp.animals || [])]
    .map(t => `<span class="tag">${esc(t)}</span>`).join("");

  return `<div style="display:flex;gap:12px">
    <img class="lp-thumb" src="/api/thumb/${lp.rowid}?s=grid" style="width:140px;height:auto;border-radius:var(--radius-sm);border:1px solid var(--line);flex:0 0 auto;cursor:zoom-in">
    <div style="min-width:0">
      <div class="fn" style="font-family:var(--mono);font-size:12px;margin-bottom:4px">${esc(lp.filename)} <span class="muted">${esc(lp.shoot_date || "")} &middot; ${when}</span></div>
      <div style="display:flex;gap:8px;align-items:center;margin-bottom:6px;flex-wrap:wrap">
        <span class="mini ${esc(lp.base_verdict)}">${esc(lp.base_verdict || "?")}</span>
        <span class="stars-mini">${"&#9733;".repeat(lp.quality_stars || 0)}</span>
        <span class="muted">${esc(lp.reason || "")}</span></div>
      <div class="cap" style="font-size:12.5px">${esc(lp.caption || lp.subject || "")}</div>
      ${factsLine}
      ${textLine}
      ${chips ? `<div class="tags" style="margin-top:6px">${chips}</div>` : ""}
    </div></div>`;
}
function timelineRow(r, muted) {
  return `<div class="tl-row${muted ? " muted" : ""}"><span class="fn">${esc(r.filename)}</span><span class="tl-date">${mdY(r.shoot_date)}</span></div>`;
}
function timelineHtml(recent5, next5) {
  const past = (recent5 || []).map(r => timelineRow(r, false)).join("")
    || '<div class="muted" style="padding:4px 0">none yet</div>';
  const next = (next5 || []).map(r => timelineRow(r, true)).join("")
    || '<div class="muted" style="padding:4px 0">queue empty</div>';
  const subhead = "font-size:10px;text-transform:uppercase;letter-spacing:.6px;color:var(--ink-3);margin-bottom:6px";
  return `<div class="cols">
    <div><div style="${subhead}">Recently processed</div>${past}</div>
    <div><div style="${subhead}">Up next</div>${next}</div></div>`;
}
async function pollMonitor() {
  try {
    const d = await api("/api/monitor"), c = d.counts;
    $("#monitor").classList.toggle("dead", !d.running);
    $("#mon-label").textContent = d.running ? d.sources.length + " active" : "idle";
    $("#mon-count").textContent = c.ok.toLocaleString() + " / " + c.total.toLocaleString();
    $("#mon-bar").style.width = (c.total ? 100 * c.ok / c.total : 0) + "%";
    $("#mon-rate").textContent = d.img_per_hr || "--";
    $("#mon-err").textContent = c.error + " err";
    $("#mon-eta").textContent = d.eta_hours == null ? "--" : "ETA " + d.eta_hours + "h";
  } catch (e) { /* run may not be up yet */ }
}
/* ------------------------------------------------ init */
loadMonitor();
pollMonitor();
setInterval(pollMonitor, 5000);
// The topbar widget polls every 5 s; the page body below it is a heavier re-render, so a bit less often.
setInterval(loadMonitor, 8000);
