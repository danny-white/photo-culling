"use strict";
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const api = (p) => fetch(p).then(r => r.json());
const post = (p, b) => fetch(p, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(b)}).then(r => r.json());
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[c]));
const fmt = (x) => x == null ? "&mdash;" : (Math.round(x * 10) / 10);
const dash = (s) => esc(s) || "&mdash;";
function debounce(fn, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }
function toast(m) { const t = $("#toast"); t.textContent = m; t.classList.add("show"); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("show"), 1700); }

const S = { view: "review", filter: "all", scene: "", stars: "", exposure: "", sort: "capture", order: "asc", q: "",
  offset: 0, limit: 120, items: [], loupeIdx: -1, current: null, summary: null };

/* ------------------------------------------------ summary + filters */
async function loadSummary() {
  S.summary = await api("/api/summary");
  $("#scope").textContent = S.summary.total.toLocaleString() + " frames";
  const sc = $("#scene");
  sc.innerHTML = '<option value="">all scenes</option>' +
    S.summary.scenes.map(s => `<option value="${esc(s.scene)}">${esc(s.scene)} (${s.c})</option>`).join("");
  renderFilters();
}
function renderFilters() {
  const v = S.summary.verdicts || {}, st = S.summary.by_status || {};
  const pills = [["all", "All", st.ok || 0], ["keep", "Keep", v.keep || 0], ["review", "Review", v.review || 0],
    ["reject", "Reject", v.reject || 0], ["errors", "Errors", S.summary.errors || 0]];
  $("#filters").innerHTML = pills.map(([k, l, n]) =>
    `<span class="pill ${k === S.filter ? "on" : ""}" data-f="${k}">${l}<span class="n">${(n || 0).toLocaleString()}</span></span>`).join("");
  $$("#filters .pill").forEach(p => p.onclick = () => { S.filter = p.dataset.f; renderFilters(); loadList(true); });
}

/* ------------------------------------------------ grid */
async function loadList(reset) {
  if (reset) { S.offset = 0; S.items = []; $("#grid").innerHTML = ""; }
  const qs = new URLSearchParams({ filter: S.filter, scene: S.scene, stars: S.stars, exposure: S.exposure, q: S.q, sort: S.sort, order: S.order, limit: S.limit, offset: S.offset });
  const d = await api("/api/list?" + qs);
  const start = S.items.length;
  S.items = S.items.concat(d.items);
  $("#grid").insertAdjacentHTML("beforeend", d.items.map((it, k) => card(it, start + k)).join(""));
  S.offset += d.items.length;
  $("#more").style.display = d.items.length < S.limit ? "none" : "";
  if (reset && !d.items.length) $("#grid").innerHTML = '<div class="muted" style="padding:20px">No frames match.</div>';
}
function card(it, i) {
  const v = it.ai_verdict, vv = ["keep", "review", "reject"].includes(v) ? v : null;
  const hv = it.annotation && it.annotation.human_verdict;
  const badges = [];
  if (it.status === "error") badges.push('<span class="mini reject">ERR</span>');
  else if (vv) badges.push(`<span class="mini ${vv}">${vv[0].toUpperCase()}</span>`);
  if (hv) badges.push(`<span class="mini human">&#10003;${hv[0].toUpperCase()}</span>`);
  const stars = it.quality_stars ? `<span class="stars-mini">${"&#9733;".repeat(it.quality_stars)}</span>` : "";
  return `<div class="card" data-i="${i}">
    ${vv ? `<div class="rail-v" style="background:var(--${vv})"></div>` : ""}
    <div class="badges">${badges.join("")}</div><div class="corner">${stars}</div>
    <div class="thumb" style="background-image:url('/api/thumb/${it.id}?s=grid')"></div>
    <div class="cap"><span class="fn">${esc(it.filename)}</span>${it.status === "error"
      ? `<span class="sub err">${esc((it.error_class || "error") + ": " + (it.error_msg || ""))}</span>`
      : `<span class="sub">${dash(it.subject)}</span>`}</div>
  </div>`;
}
function refreshCard(i) {
  const c = $(`#grid .card[data-i="${i}"]`); if (!c || !S.items[i]) return;
  const tmp = document.createElement("div"); tmp.innerHTML = card(S.items[i], i);
  c.replaceWith(tmp.firstElementChild);
}

/* ------------------------------------------------ loupe */
async function openLoupe(i) {
  if (i < 0) { toast("first frame"); return; }
  if (i >= S.items.length) { toast("last frame"); return; }
  S.loupeIdx = i;
  const it = await api("/api/item/" + S.items[i].id);
  S.current = it;
  $("#grid").style.display = "none"; $("#review-tools").style.display = "none"; $("#more").parentElement.style.display = "none";
  const L = $("#loupe"); L.style.display = "block"; L.innerHTML = loupeHTML(it, i); wireLoupe(); loadFilmstrip(it.id);
}
async function openLoupeById(id) {
  let gi = S.items.findIndex(x => x.id === id);
  if (gi < 0) { S.items.push({ id }); gi = S.items.length - 1; }
  openLoupe(gi);
}
function closeLoupe() {
  $("#loupe").style.display = "none"; $("#grid").style.display = ""; $("#review-tools").style.display = ""; $("#more").parentElement.style.display = "";
  const i = S.loupeIdx; S.loupeIdx = -1; S.current = null;
  if (i >= 0) refreshCard(i);
}
function loupeHTML(it, i) {
  const v = it.ai_verdict, ann = it.annotation || {}, hv = ann.human_verdict, hs = ann.human_stars || 0, stars = it.quality_stars || 0;
  const tags = (it.tags || []).map(t => `<span class="tag">${esc(t)}</span>`).join("");
  const issues = (it.issues || []).map(t => `<span class="tag issue">${esc(t)}</span>`).join("");
  const flags = ["confabulated detail", "wrong subject", "wrong genre", "over-rated", "under-rated", "missed issue", "keyword noise", "missed eyes-closed"];
  const cur = new Set(ann.flags || []);
  const ok = it.exposure_flag === "ok";
  return `<div class="bay">
    <section class="stage">
      <button class="btn backbtn" id="lp-back">Grid <span class="k">Esc</span></button>
      <div class="verdict-badge"><span class="chip ${v}" id="lp-chip">${esc(v || "?")}</span>
        <span class="badge-stars">${"&#9733;".repeat(stars)}${"&#9734;".repeat(5 - stars)}</span></div>
      <img src="/api/thumb/${it.id}?s=loupe" alt="${esc(it.filename)}">
      <div class="navarrows"><button id="lp-prev" title="Previous">&lsaquo;</button><button id="lp-next" title="Next">&rsaquo;</button></div>
      <div class="reasoline"><b>AI:</b> ${esc(it.reason || "")}</div>
    </section>
    <aside class="inspector">
      <div class="insp-head"><span class="fn">${esc(it.filename)}</span>
        <span class="pos">#${i + 1} / ${S.items.length}${it.burst_size > 1 ? " &middot; burst " + it.burst_size : ""}</span></div>
      <div class="insp-body">
        ${it.status === "error" ? `<div class="sec"><div class="lbl">Load error</div><div class="errbox"><b>${esc(it.error_class || "error")}</b><br>${esc(it.error_msg || "(no message)")}</div></div>` : ""}
        <div class="sec"${it.status === "error" ? ' style="display:none"' : ""}><div class="lbl">AI read</div>
          <p class="cap">${esc(it.caption || "")}</p>
          <dl class="kv" style="margin-top:9px">
            <dt>subject</dt><dd>${dash(it.subject)}</dd>
            <dt>scene</dt><dd>${dash(it.scene)}</dd>
            <dt>people</dt><dd>${it.people_count || 0}${it.eyes_closed ? " &middot; eyes closed" : ""}</dd>
            <dt>aesthetic</dt><dd>${it.aesthetic == null ? "&mdash;" : it.aesthetic} / 10</dd></dl>
          <div class="tags" style="margin-top:9px">${tags}${issues}</div></div>
        <div class="sec"${it.status === "error" ? ' style="display:none"' : ""}><div class="lbl">Technical &middot; measured</div>
          <dl class="kv">
            <dt>sharpness</dt><dd>${fmt(it.sharpness)}</dd>
            <dt>exposure</dt><dd class="${ok ? "ok" : "warn"}">${dash(it.exposure_flag)}</dd>
            <dt>blown / crushed</dt><dd>${fmt(it.blown_pct)}% / ${fmt(it.crushed_pct)}%</dd>
            <dt>camera</dt><dd>${dash(it.camera)}</dd>
            <dt>lens</dt><dd>${dash(it.lens)}</dd>
            <dt>model</dt><dd>${dash(it.model_used)}</dd></dl></div>
        <div class="sec"><div class="lbl">Your call <span class="saved" id="lp-saved">saved</span></div>
          <div class="verdict-set" id="lp-vset">
            <button class="vbtn ${hv === "keep" ? "on" : ""}" data-v="keep">Keep<span class="k">K</span></button>
            <button class="vbtn ${hv === "review" ? "on" : ""}" data-v="review">Review<span class="k">U</span></button>
            <button class="vbtn ${hv === "reject" ? "on" : ""}" data-v="reject">Reject<span class="k">X</span></button></div>
          <div class="starset" id="lp-stars">${[1, 2, 3, 4, 5].map(n =>
            `<span class="s ${hs >= n ? "on" : ""}" data-n="${n}">&#9733;</span>`).join("")}
            <span style="margin-left:auto;font-size:11px;color:var(--ink-3)">your rating</span></div>
          <button class="btn agree" id="lp-agree">&#10003; Agree with AI (${esc(v)}${stars ? " &middot; " + stars + "&#9733;" : ""}) <span class="k">Enter</span></button></div>
        <div class="sec"><div class="lbl">Flag what's wrong &rarr; prompt</div>
          <div class="flags" id="lp-flags">${flags.map(f =>
            `<span class="flag ${cur.has(f) ? "on" : ""}" data-f="${esc(f)}">${esc(f)}</span>`).join("")}</div>
          <textarea class="note" id="lp-note" placeholder="Note (optional)">${esc(ann.note || "")}</textarea></div>
      </div></aside></div>
    <div class="filmstrip" id="lp-strip" style="display:none"></div>`;
}
function wireLoupe() {
  $("#lp-back").onclick = closeLoupe;
  $("#lp-prev").onclick = () => openLoupe(S.loupeIdx - 1);
  $("#lp-next").onclick = () => openLoupe(S.loupeIdx + 1);
  const im = $(".stage img"); if (im) im.onclick = () => $(".stage").classList.toggle("zoom");
  $$("#lp-vset .vbtn").forEach(b => b.onclick = () => setVerdict(b.dataset.v));
  $$("#lp-stars .s").forEach(s => s.onclick = () => setStars(+s.dataset.n));
  $("#lp-agree").onclick = agreeAndNext;
  $$("#lp-flags .flag").forEach(f => f.onclick = () => { f.classList.toggle("on"); saveCurrent(); });
  $("#lp-note").onchange = saveCurrent;
}
const currentFlags = () => $$("#lp-flags .flag.on").map(f => f.dataset.f);
function applyAnno(i, a) { if (S.items[i]) S.items[i].annotation = { human_verdict: a.human_verdict, human_stars: a.human_stars, agree: a.agree, flags: a.flags, note: a.note }; }
function flashSaved() { const s = $("#lp-saved"); if (!s) return; s.classList.add("show"); clearTimeout(s._h); s._h = setTimeout(() => s.classList.remove("show"), 1100); }
async function saveCurrent() {
  const on = $("#lp-vset .vbtn.on");
  const a = { id: S.current.id, human_verdict: on ? on.dataset.v : null,
    human_stars: $$("#lp-stars .s.on").length || null, agree: 0, flags: currentFlags(), note: $("#lp-note").value };
  applyAnno(S.loupeIdx, a); flashSaved(); await post("/api/annotate", a);
}
function setVerdict(v) {
  $$("#lp-vset .vbtn").forEach(b => b.classList.toggle("on", b.dataset.v === v));
  const chip = $("#lp-chip"); chip.className = "chip " + v; chip.textContent = v;
  saveCurrent();
}
function setStars(n) { $$("#lp-stars .s").forEach(s => s.classList.toggle("on", +s.dataset.n <= n)); saveCurrent(); }
async function agreeAndNext() {
  const v = S.current.ai_verdict, s = S.current.quality_stars;
  const a = { id: S.current.id, human_verdict: v, human_stars: s, agree: 1, flags: currentFlags(), note: $("#lp-note").value };
  applyAnno(S.loupeIdx, a); await post("/api/annotate", a); toast("Agreed · " + v);
  openLoupe(S.loupeIdx + 1);
}
async function loadFilmstrip(id) {
  const strip = $("#lp-strip"); if (!strip) return;
  const d = await api("/api/burst_of/" + id);
  if (!d.frames || d.frames.length <= 1) { strip.style.display = "none"; return; }
  const pick = d.frames.find(f => f.is_best) || {};
  strip.style.display = "";
  strip.innerHTML = `<div class="fs-head"><span>Burst &middot; <b>${d.frames.length} frames</b> &middot; AI pick <b>${esc(pick.filename || "")}</b></span></div>
    <div class="rail">` + d.frames.map(f => `<div class="frame ${f.id === id ? "cur" : ""}" data-id="${f.id}">
      ${f.is_best ? '<span class="mini pick pk">PICK</span>' : ""}
      <div class="img" style="background-image:url('/api/thumb/${f.id}?s=strip')"></div>
      <div class="meta"><span>${esc(String(f.filename).slice(-10))}</span><span>${fmt(f.sharpness)}</span></div></div>`).join("") + "</div>";
  $$("#lp-strip .frame").forEach(fr => fr.onclick = () => openLoupeById(+fr.dataset.id));
}

/* ------------------------------------------------ bursts view */
async function loadBursts() {
  const idx = $("#bursts-index"), cmp = $("#bursts-compare");
  cmp.style.display = "none"; idx.style.display = ""; idx.innerHTML = '<div class="muted">Loading&hellip;</div>';
  const d = await api("/api/bursts");
  if (!d.bursts.length) { idx.innerHTML = '<div class="panel muted">No multi-frame bursts detected yet (frames within 2s, same camera). More appear as the run progresses.</div>'; return; }
  idx.innerHTML = `<div class="muted" style="margin-bottom:10px">${d.total} bursts &middot; click to compare and pick the best</div><div class="burst-list">` +
    d.bursts.map(b => `<div class="burst-card" data-bid="${b.bid}">
      <div class="row">${('<div class="t" style="background-image:url(/api/thumb/' + b.rep + '?s=strip)"></div>').repeat(Math.min(b.n, 4))}</div>
      <div class="m"><span>${dash(b.subject)}</span><span>${b.n} frames &middot; ${b.keeps} keep</span></div></div>`).join("") + "</div>";
  $$("#bursts-index .burst-card").forEach(x => x.onclick = () => openBurst(+x.dataset.bid));
}
async function openBurst(bid) {
  const d = await api("/api/burst/" + bid);
  $("#bursts-index").style.display = "none";
  const c = $("#bursts-compare"); c.style.display = "";
  c.innerHTML = `<button class="btn" id="b-back">&larr; all bursts</button>
    <h2 class="h" style="margin-top:12px">Burst #${bid} &middot; ${d.frames.length} frames &mdash; pick the best</h2>
    <div class="compare">` + d.frames.map(f => `<div class="cframe ${f.is_best ? "best" : ""} ${f.human_verdict === "keep" ? "mine" : ""}">
      <img src="/api/thumb/${f.id}?s=grid" alt="">
      <div class="b"><span class="fn">${esc(f.filename)}${f.is_best ? " &middot; AI pick" : ""}</span>
        <span class="st">sharp ${fmt(f.sharpness)} &middot; aes ${f.aesthetic == null ? "&mdash;" : f.aesthetic} &middot; ${esc(f.base_verdict)}</span>
        <button class="btn pickbtn" data-id="${f.id}">${f.human_verdict === "keep" ? "&#10003; your pick" : "Pick as best"}</button></div></div>`).join("") + "</div>";
  $("#b-back").onclick = loadBursts;
  $$("#bursts-compare .pickbtn").forEach(btn => btn.onclick = async () => {
    await post("/api/annotate", { id: +btn.dataset.id, human_verdict: "keep", human_stars: null, agree: 0, flags: [], note: "" });
    toast("Picked best"); openBurst(bid);
  });
}

/* ------------------------------------------------ feedback view */
async function loadFeedback() {
  const d = await api("/api/feedback"), body = $("#feedback-body");
  const f = d.suggestions, maxc = Math.max(1, ...f.map(x => x.count));
  body.innerHTML = `<div class="cols"><div>
    <h2 class="h">What you flagged</h2>
    ${f.length ? '<div class="bars">' + f.map(x => `<div class="b"><span>${esc(x.flag)}</span><span class="track"><i style="width:${100 * x.count / maxc}%"></i></span><span class="num">${x.count}</span></div>`).join("") + "</div>"
      : '<div class="muted">No flags yet &mdash; flag issues in Review and they aggregate here.</div>'}
    <h2 class="h" style="margin-top:20px">Model vs. you</h2>
    <div class="stat-row">
      <div class="s"><div class="n">${d.labeled}</div><div class="l">frames you judged</div></div>
      <div class="s"><div class="n">${d.disagreements}</div><div class="l">disagreements</div></div>
      <div class="s"><div class="n">${d.disagree_rate == null ? "&mdash;" : d.disagree_rate + "%"}</div><div class="l">disagree rate</div></div></div>
    ${d.disagree_by_scene.length ? '<div class="muted">by scene: ' + d.disagree_by_scene.map(x => esc(x[0]) + " " + x[1]).join(" &middot; ") + "</div>" : ""}
    </div><div>
    <h2 class="h">Suggested prompt edits</h2>
    ${f.length ? f.map(x => `<div class="sug"><div class="h"><span>${esc(x.flag)}</span><span class="c">&times;${x.count}</span></div><div class="s">${esc(x.suggestion)}</div></div>`).join("")
      : '<div class="muted">Flag frames to generate suggestions.</div>'}
    ${d.prompt_addendum ? `<h2 class="h" style="margin-top:18px">Draft addendum for VLM_PROMPT</h2><pre class="code">${esc(d.prompt_addendum)}</pre><button class="btn" id="copy-prompt">Copy</button>` : ""}
    </div></div>`;
  if ($("#copy-prompt")) $("#copy-prompt").onclick = () => { navigator.clipboard.writeText(d.prompt_addendum); toast("Copied"); };
}

/* ------------------------------------------------ tune view */
function loadTune() {
  const body = $("#tune-body");
  const defs = { sharp_floor: 30, blown_severe: 15, aesthetic_keep: 7, aesthetic_reject: 3 };
  const specs = [["sharp_floor", "SHARP_FLOOR (blur cutoff)", 0, 150, 1], ["blown_severe", "Blown % → reject", 0, 40, 1],
    ["aesthetic_keep", "Aesthetic &ge; keep", 5, 10, 1], ["aesthetic_reject", "Aesthetic &le; reject", 1, 6, 1]];
  body.innerHTML = `<h2 class="h">Threshold sandbox</h2>
    <div class="muted" style="margin-bottom:14px">Re-derives verdicts from the stored measurements with candidate thresholds and compares to your corrections &mdash; no VLM re-run. (keep_hint isn't stored, so keeps are a slight approximation.)</div>
    <div id="sliders">` + specs.map(([k, l, mn, mx, st]) =>
      `<div class="slider"><label>${l}</label><input type="range" id="t-${k}" min="${mn}" max="${mx}" step="${st}" value="${defs[k]}"><span class="val" id="v-${k}">${defs[k]}</span></div>`).join("") + `</div>
    <div class="stat-row" id="tune-stats"></div><div class="bars" id="tune-dist"></div>
    <button class="btn" id="t-reset">Reset to defaults</button>`;
  const run = async () => {
    const p = {}; specs.forEach(([k]) => { p[k] = $("#t-" + k).value; $("#v-" + k).textContent = $("#t-" + k).value; });
    const d = await api("/api/tune?" + new URLSearchParams(p));
    $("#tune-stats").innerHTML = `
      <div class="s"><div class="n">${d.distribution.keep.toLocaleString()}</div><div class="l">keep</div></div>
      <div class="s"><div class="n">${d.distribution.review.toLocaleString()}</div><div class="l">review</div></div>
      <div class="s"><div class="n">${d.distribution.reject.toLocaleString()}</div><div class="l">reject</div></div>
      <div class="s"><div class="n">${d.flips_vs_ai.toLocaleString()}</div><div class="l">changed vs AI</div></div>
      <div class="s"><div class="n">${d.agreement_pct == null ? "&mdash;" : d.agreement_pct + "%"}</div><div class="l">agree w/ you (${d.labeled})</div></div>`;
    const tot = d.n || 1;
    $("#tune-dist").innerHTML = ["keep", "review", "reject"].map(k =>
      `<div class="b"><span>${k}</span><span class="track"><i style="width:${100 * d.distribution[k] / tot}%;background:var(--${k})"></i></span><span class="num">${Math.round(100 * d.distribution[k] / tot)}%</span></div>`).join("");
  };
  specs.forEach(([k]) => $("#t-" + k).oninput = debounce(run, 150));
  $("#t-reset").onclick = () => { specs.forEach(([k]) => $("#t-" + k).value = defs[k]); run(); };
  run();
}

/* ------------------------------------------------ monitor view + poll */
async function loadMonitor() {
  const d = await api("/api/monitor"), c = d.counts, rp = d.run_pos;
  const pct = (d.running && rp && rp.n) ? 100 * rp.i / rp.n : (c.total ? 100 * c.ok / c.total : 0);
  $("#monitor-body").innerHTML = `<div class="cols">
    <div class="panel"><h2 class="h">Run</h2>
      <div class="stat-row">
        <div class="s"><div class="n">${c.ok.toLocaleString()}</div><div class="l">done</div></div>
        <div class="s"><div class="n">${c.pending.toLocaleString()}</div><div class="l">pending</div></div>
        <div class="s"><div class="n" style="color:var(--reject)">${c.error}</div><div class="l">errors</div></div>
        <div class="s"><div class="n">${d.img_per_hr || "&mdash;"}</div><div class="l">img/hr</div></div>
        <div class="s"><div class="n">${d.eta_hours == null ? "&mdash;" : d.eta_hours + "h"}</div><div class="l">eta</div></div></div>
      <div class="bar" style="height:9px"><i style="display:block;height:100%;width:${pct}%;background:linear-gradient(90deg,var(--accent),#6fd0e4)"></i></div>
      <div class="muted" style="margin-top:8px">${d.running ? '<span style="color:var(--keep)">&#9679; running</span>' + (rp ? " &middot; frame " + rp.i.toLocaleString() + "/" + rp.n.toLocaleString() : "") : "&#9675; not running"}${d.gpu ? " &middot; GPU " + d.gpu.used_mb + "/" + d.gpu.total_mb + "MB &middot; " + d.gpu.util + "%" : ""}</div>
      <div style="display:flex;gap:8px;margin-top:14px;flex-wrap:wrap">
        <button class="btn warn" id="i-pause" ${d.running ? "" : "disabled"}>Pause run</button>
        <button class="btn" id="i-resume" ${d.running ? "disabled" : ""}>Resume</button>
        <button class="btn" id="i-redrive" ${d.running || !c.error ? "disabled" : ""}>Redrive ${c.error} errors</button>
        <button class="btn" id="i-export">Export snapshot</button></div></div>
    <div class="panel"><h2 class="h">Errors by class</h2>
      ${d.errors_by_class.length ? '<table class="errtable">' + d.errors_by_class.map(e => `<tr><td>${esc(e.error_class)}</td><td class="n">${e.c}</td></tr>`).join("") + "</table>" : '<div class="muted">none</div>'}</div>
    </div>
    <div class="panel" style="margin-top:14px"><h2 class="h">Recent log</h2><div class="logbox">${d.recent.map(esc).join("\n")}</div></div>`;
  const act = async (a, confirmMsg) => { if (confirmMsg && !confirm(confirmMsg)) return; const r = await post("/api/intervene", { action: a }); toast(r.msg || (r.ok ? "ok" : "failed")); setTimeout(loadMonitor, 900); };
  $("#i-pause").onclick = () => act("pause", "Stop the run? It's safe — resumes exactly where it left off.");
  $("#i-resume").onclick = () => act("resume");
  $("#i-redrive").onclick = () => act("redrive");
  $("#i-export").onclick = () => act("export");
}
async function pollMonitor() {
  try {
    const d = await api("/api/monitor"), c = d.counts;
    $("#monitor").classList.toggle("dead", !d.running);
    $("#mon-label").textContent = d.running ? "run · 9b" : "idle";
    const rp = d.run_pos, pi = (d.running && rp) ? rp.i : c.ok, pn = (d.running && rp) ? rp.n : c.total;
    $("#mon-count").textContent = pi.toLocaleString() + " / " + pn.toLocaleString();
    $("#mon-bar").style.width = (pn ? 100 * pi / pn : 0) + "%";
    $("#mon-rate").textContent = d.img_per_hr || "--";
    $("#mon-err").textContent = c.error + " err";
    $("#mon-eta").textContent = d.eta_hours == null ? "--" : "ETA " + d.eta_hours + "h";
  } catch (e) { /* run may not be up yet */ }
}

/* ------------------------------------------------ router + keys + init */
function show(view) {
  S.view = view;
  $$("#tabs .tab").forEach(t => t.classList.toggle("on", t.dataset.view === view));
  $$(".view").forEach(v => v.classList.toggle("on", v.id === "view-" + view));
  $("#keybar").style.display = view === "review" ? "" : "none";
  if (view === "bursts") loadBursts();
  else if (view === "feedback") loadFeedback();
  else if (view === "tune") loadTune();
  else if (view === "monitor") loadMonitor();
}
function onKey(e) {
  if (S.view !== "review" || S.loupeIdx < 0) return;
  if (["TEXTAREA", "INPUT"].includes(e.target.tagName)) return;
  const k = e.key.toLowerCase();
  if (k === "escape") return closeLoupe();
  if (k === "arrowleft") return openLoupe(S.loupeIdx - 1);
  if (k === "arrowright") return openLoupe(S.loupeIdx + 1);
  if (k === "k") return setVerdict("keep");
  if (k === "u") return setVerdict("review");
  if (k === "x") return setVerdict("reject");
  if (k === "enter") { e.preventDefault(); return agreeAndNext(); }
  if (k === "z") { const st = $(".stage"); if (st) st.classList.toggle("zoom"); return; }
  if (k >= "1" && k <= "5") return setStars(+k);
}
$$("#tabs .tab").forEach(t => t.onclick = () => show(t.dataset.view));
$("#grid").addEventListener("click", e => { const c = e.target.closest(".card"); if (c) openLoupe(+c.dataset.i); });
$("#more").onclick = () => loadList(false);
$("#scene").onchange = () => { S.scene = $("#scene").value; loadList(true); };
$("#stars").onchange = () => { S.stars = $("#stars").value; loadList(true); };
$("#exposure").onchange = () => { S.exposure = $("#exposure").value; loadList(true); };
$("#sort").onchange = () => { S.sort = $("#sort").value; loadList(true); };
$("#order").onclick = () => { S.order = S.order === "asc" ? "desc" : "asc"; $("#order").innerHTML = S.order === "asc" ? "&uarr; asc" : "&darr; desc"; loadList(true); };
$("#search").oninput = debounce(() => { S.q = $("#search").value.trim(); loadList(true); }, 300);
document.addEventListener("keydown", onKey);
loadSummary().then(() => loadList(true));
pollMonitor();
setInterval(pollMonitor, 5000);
