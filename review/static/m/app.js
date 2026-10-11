/* Culling Bay Mobile: cull a day from the NAS on the phone, in two passes.
   Plain JavaScript, no build step. Talks to /m/api (review/mobile.py); every tap is saved on the
   PC at once, through a retry queue that survives a dropped connection or a reload.
   The screens follow the planning mock: days -> sweep (pass 1) -> cards (pass 2) <-> burst
   picker -> rejects review. */
(() => {
'use strict';

const $ = (s, el = document) => el.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const stem = f => f.replace(/\.[^.]+$/, '');
const view = $('#view');
const reduced = () => window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
const NOTE_PREFIX = 'Burst reject · kept ';
const THRESH = 80;          // px of vertical drag that commits a keep or reject
const PICKER_STRIP_MAX = 6; // bursts up to this size open as a filmstrip; bigger ones as a duel

const IC = {
  x: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/></svg>',
  check: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  undo: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 14L4 9l5-5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
  star: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.8l-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z" fill="currentColor"/></svg>',
  info: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M12 11v6M12 7.5v.01" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>',
  back: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  stack: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="4" width="13" height="11" rx="2" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M4 8v10a2 2 0 0 0 2 2h10" fill="none" stroke="currentColor" stroke-width="1.9"/></svg>',
  focus: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="6.5" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M16 16l4.5 4.5" stroke="currentColor" stroke-width="2.1" stroke-linecap="round"/></svg>',
};

const S = {
  screen: 'days', days: null, day: null, stacks: [], dec: {},
  pass: 2, cursor: 0, hist: [], picker: null, sweepSel: new Set(),
  chrome: true, busy: false, sheet: false, focus: null,
};

/* ---------------------------------------------------------------- server */
const img = (id, size) => '/m/api/img/' + id + '?s=' + size;
const dayPath = day => day.split('/').map(encodeURIComponent).join('/');
function newId() {
  const b = new Uint8Array(12);
  crypto.getRandomValues(b);                  // randomUUID needs HTTPS; this works over plain http
  return Date.now().toString(36) + '-' + Array.from(b, x => x.toString(16).padStart(2, '0')).join('');
}
async function getJSON(url) {
  const r = await fetch(url, { cache: 'no-store' });
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || 'HTTP ' + r.status);
  return r.json();
}

// Writes go through a queue kept in localStorage, sent strictly in order, so a decide followed
// by its undo can never arrive the other way round. 4xx means the request itself is wrong: it
// is dropped and reported. Anything else (offline, 5xx) is retried.
const Q = { items: [], busy: false, offline: false };
try { Q.items = JSON.parse(localStorage.getItem('cbm-queue') || '[]'); } catch (_) { Q.items = []; }
function persistQueue() { try { localStorage.setItem('cbm-queue', JSON.stringify(Q.items)); } catch (_) {} }
function send(method, url, body) { Q.items.push({ method, url, body }); persistQueue(); pump(); }
async function pump() {
  if (Q.busy) return;
  Q.busy = true;
  while (Q.items.length) {
    const it = Q.items[0];
    let r;
    try {
      r = await fetch(it.url, { method: it.method, headers: { 'Content-Type': 'application/json', 'X-Culling-Bay': '1' }, body: JSON.stringify(it.body) });
    } catch (_) { r = null; }
    if (!r || r.status >= 500) {
      setOffline(true);
      Q.busy = false;
      setTimeout(pump, 4000);
      return;
    }
    if (!r.ok) {
      const e = await r.json().catch(() => ({}));
      toast('Not saved: ' + (e.error || 'HTTP ' + r.status));
    }
    Q.items.shift();
    persistQueue();
  }
  setOffline(false);
  Q.busy = false;
}
function setOffline(on) {
  if (Q.offline === on && !on) return;
  Q.offline = on;
  const el = $('.net', view);
  if (el) { el.hidden = !on; el.textContent = 'Offline · ' + Q.items.length + ' waiting to save'; }
}
let progressT;
function saveProgress(finished) {
  if (!S.day) return;
  clearTimeout(progressT);
  const day = S.day.day, body = { pass: S.pass, cursor: S.cursor, finished: !!finished };
  progressT = setTimeout(() => send('PUT', '/m/api/day/' + dayPath(day) + '/progress', body), finished ? 0 : 600);
}
window.addEventListener('online', pump);
document.addEventListener('visibilitychange', () => { if (!document.hidden) pump(); });

/* ---------------------------------------------------------------- model */
const isPick = d => !!d && d.flag === 'pick';
const frameById = id => { for (const s of S.stacks) for (const f of s.frames) if (f.id === id) return f; return null; };
const leadOf = s => s.frames.find(f => f.id === s.lead) || s.frames[0];
function shown(s) {   // the frame a card shows: the kept one, else the lead
  if (s.frames.length === 1) return s.frames[0];
  return s.frames.find(f => isPick(S.dec[f.id])) || leadOf(s);
}
function status(s) {
  const ds = s.frames.map(f => S.dec[f.id]);
  const kept = ds.find(isPick);
  if (kept) return { done: true, v: ds.some(d => isPick(d) && d.stars === 5) ? 'hero' : 'keep' };
  if (ds.every(d => d && d.flag === 'reject')) return { done: true, v: 'reject' };
  return { done: false };
}
const firstOpen = (from = 0) => {
  const n = S.stacks.length;
  for (let k = 0; k < n; k++) { const i = (from + k) % n; if (!status(S.stacks[i]).done) return i; }
  return -1;
};
const markOf = f => (S.dec[f.id] ? S.dec[f.id].flag : 'none');
const doneCount = () => S.stacks.filter(s => status(s).done).length;
function dayTitle(d) {
  if (!d.date) return d.folder;
  const [y, m, dd] = d.date.split('-').map(Number);
  return new Date(y, m - 1, dd).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
}

/* one action = one tap; saved to the server and to the undo history */
function act(label, changes, extra) {
  const before = changes.map(c => [c.id, S.dec[c.id] ? Object.assign({}, S.dec[c.id]) : null]);
  for (const c of changes) {
    S.dec[c.id] = { flag: c.flag, stars: c.flag === 'pick' ? (c.stars || null) : null, note: c.note || '', state: 'draft', outcome: null };
  }
  const action_id = newId();
  S.hist.push(Object.assign({ action_id, label, before, cursor: S.cursor, pass: S.pass, screen: 'cull' }, extra || {}));
  send('POST', '/m/api/decide', { action_id, day: S.day.day, label, changes });
}
function undo() {
  const h = S.hist.pop();
  if (!h) { toast('Nothing to undo'); return; }
  for (const [id, d] of h.before) { if (d) S.dec[id] = d; else delete S.dec[id]; }
  send('POST', '/m/api/undo', { action_id: h.action_id });
  S.pass = h.pass;
  S.picker = null;
  closeSheet();
  toast('Undone: ' + h.label);
  if (h.screen === 'sweep') { S.screen = 'sweep'; S.sweepSel = new Set(h.sel); saveProgress(); return draw(); }
  if (h.screen === 'summary') { S.screen = 'summary'; return draw(); }
  S.cursor = Math.min(h.cursor, S.stacks.length - 1);
  S.screen = 'cull';
  saveProgress();
  draw('prev');
}
function commit(label, changes) {
  act(label, changes);
  S.picker = null;
  closeSheet();
  toast(label, true);
  advance();
}
function advance() {
  const i = firstOpen(S.cursor + 1);
  if (i < 0) { S.screen = 'summary'; saveProgress(true); }
  else { S.cursor = i; S.screen = 'cull'; saveProgress(); }
  draw('dec');
}
function keepFrames(s, keeps, hero, via) {
  const changes = keeps.map((f, i) => ({ id: f.id, flag: 'pick', stars: hero && i === 0 ? 5 : null, note: '', via }));
  const others = s.frames.filter(f => !keeps.includes(f));
  const note = NOTE_PREFIX + keeps.map(f => stem(f.file)).join(', ');
  for (const f of others) changes.push({ id: f.id, flag: 'reject', note, via });
  const head = (hero ? 'Hero ' : 'Kept ') + (keeps.length > 1 ? keeps.length + ' frames' : stem(keeps[0].file));
  commit(others.length ? head + ' · ' + others.length + ' rejected with a note' : head, changes);
}
function decide(a) {
  const s = S.stacks[S.cursor];
  if (!s) return;
  if (a === 'reject') {
    return commit(s.frames.length > 1 ? 'Rejected all ' + s.frames.length : 'Rejected ' + stem(s.frames[0].file),
      s.frames.map(f => ({ id: f.id, flag: 'reject', note: '', via: 'card' })));
  }
  if (a === 'all') {
    return commit('Kept all ' + s.frames.length + (s.kind === 'pano' ? ' · panorama' : s.kind === 'bracket' ? ' · bracket' : ''),
      s.frames.map(f => ({ id: f.id, flag: 'pick', note: '', via: 'card' })));
  }
  keepFrames(s, [shown(s)], a === 'hero', 'card');
}

/* ---------------------------------------------------------------- toast and sheet */
let toastT;
function toast(msg, withUndo) {
  const t = $('#toast');
  t.innerHTML = '<span>' + esc(msg) + '</span>' + (withUndo ? '<button data-act="undo">Undo</button>' : '');
  t.classList.add('show');
  clearTimeout(toastT);
  toastT = setTimeout(() => t.classList.remove('show'), 2800);
}
function closeSheet() { S.sheet = false; const el = $('#sheet'); el.hidden = true; el.innerHTML = ''; }
function openSheet() {
  const s = S.stacks[S.cursor];
  if (!s) return;
  const f = shown(s), lead = leadOf(s), d = S.dec[f.id];
  const files = [f.file].concat(f.partners || []).join(' + ');
  const lines = [];
  if (s.frames.length > 1 && f.sharpness != null && lead.sharpness != null) {
    lines.push(f.id === lead.id ? 'The sharpest frame in its burst (measured ' + Math.round(f.sharpness) + ').'
      : 'Measured sharpness ' + Math.round(f.sharpness) + ', against ' + Math.round(lead.sharpness) + ' for ' + stem(lead.file) + ', the sharpest in this burst.');
  }
  if (f.badges.includes('Blown')) lines.push('Blown: ' + Math.round(f.blown_pct) + '% of the pixels are pure white.');
  if (f.badges.includes('Dark')) lines.push('Dark: mean brightness ' + Math.round(f.mean_lum) + ' of 255.');
  if (s.kind === 'bracket') lines.push('Looks like an exposure bracket: dark, normal and bright frames together. Keep all to merge it in Lightroom.');
  if (s.kind === 'pano') lines.push('The frames slide one way, like a panorama, so Keep all is suggested.');
  const html = '<div class="sheet" role="dialog" aria-label="Photo details"><div class="sh-grab"></div>' +
    '<p class="sh-id">' + esc(files) + '</p>' +
    (f.lens ? '<p class="sh-muted">' + esc(f.lens) + '</p>' : '') +
    lines.map(l => '<p class="sh-why">' + esc(l) + '</p>').join('') +
    (d && d.note ? '<p class="sh-why">Lightroom note: ' + esc(d.note) + '</p>' : '') +
    (f.caption ? '<p class="sh-cap">“' + esc(f.caption) + '”</p>' : '') +
    '<p class="sh-muted">The AI’s caption. Its keep, review and reject verdicts stay off the phone.</p>' +
    '<button class="pb2" data-act="close-sheet">Close</button></div>';
  const el = $('#sheet');
  el.innerHTML = html;
  el.hidden = false;
  S.sheet = true;
}
$('#sheet').addEventListener('click', e => { if (e.target.id === 'sheet') closeSheet(); });

/* ---------------------------------------------------------------- views */
const top = (left, title, sub, right) =>
  '<div class="top">' + left + '<div class="t">' + esc(title) + (sub ? '<small>' + esc(sub) + '</small>' : '') + '</div>' + (right || '<span class="sp"></span>') + '</div>' +
  '<div class="net"' + (Q.offline ? '' : ' hidden') + '>Offline · ' + Q.items.length + ' waiting to save</div>';
const backBtn = (act, label) => '<button class="tbtn" data-act="' + act + '">' + IC.back + '<span>' + label + '</span></button>';

function vDays() {
  if (!S.days) return top('<span class="sp"></span>', 'Culling Bay') + '<div class="empty-state">Loading days…</div>';
  const row = d => {
    const pct = d.frames ? Math.round(d.decided / d.frames * 100) : 0;
    const tag = d.conflicts ? '<span class="tag warn">' + d.conflicts + ' conflict' + (d.conflicts > 1 ? 's' : '') + '</span>'
      : d.landed ? '<span class="tag quiet">In Lightroom</span>'
      : d.sent_at ? '<span class="tag quiet">Sent</span>'
      : d.finished ? '<span class="tag quiet">Done</span>'
      : d.decided ? '<span class="tag">' + pct + '%</span>' : '';
    return '<button class="day" data-act="open-day" data-day="' + esc(d.day) + '"><span class="mos">' +
      d.thumbs.map(id => '<img src="' + img(id, 'thumb') + '" alt="" loading="lazy">').join('') + '</span>' +
      '<span class="day-b"><b>' + esc(dayTitle(d)) + '</b><span>' + d.frames + ' frames · ' + d.stacks + ' stacks' + (d.date ? '' : ' · ' + esc(d.day)) + '</span>' +
      (d.decided ? '<span class="day-bar"><i style="width:' + pct + '%"></i></span>' : '') + '</span>' + tag + '</button>';
  };
  const going = S.days.filter(d => d.decided && !d.finished);
  const fresh = S.days.filter(d => !d.decided && !d.finished);
  const done = S.days.filter(d => d.finished);
  const sec = (title, list) => list.length ? '<p class="sec">' + title + '</p>' + list.map(row).join('') : '';
  return '<div class="head"><h1>Days</h1><span>mycloud · Pictures · ' + S.days.length + ' days</span></div>' +
    '<div class="net"' + (Q.offline ? '' : ' hidden') + '>Offline · ' + Q.items.length + ' waiting to save</div>' +
    '<div class="scroll">' + sec('In progress', going) + sec('Not started', fresh) + sec('Finished', done) + '</div>';
}

function vLoading(msg) { return top(backBtn('days', 'Days'), 'Culling Bay') + '<div class="empty-state">' + esc(msg) + '</div>'; }

const sweepLabel = () => S.sweepSel.size ? 'Reject ' + S.sweepSel.size + ', start pass 2' : 'Start pass 2';
function vSweep() {
  const tile = (s, i) => {
    const f = leadOf(s), st = status(s), on = S.sweepSel.has(i), multi = s.frames.length > 1;
    const bd = s.kind === 'bracket' ? 'Bracket' : s.kind === 'pano' ? 'Panorama' : (f.badges[0] || '');
    const what = (multi ? 'burst of ' + s.frames.length + ' led by ' : '') + stem(f.file);
    return '<button class="sw-t' + (on ? ' on' : '') + (st.done ? ' done' : '') + '" data-act="sweep-tick" data-i="' + i + '" aria-pressed="' + on + '" aria-label="' +
      esc(st.done ? what + ', already decided' : 'Reject ' + what) + '"' + (st.done ? ' disabled' : '') + '>' +
      '<img src="' + img(f.id, 'thumb') + '" alt="" draggable="false" loading="lazy">' +
      (multi ? '<span class="sw-n">' + IC.stack + s.frames.length + '</span>' : '') +
      (bd ? '<span class="sw-bd">' + esc(bd) + '</span>' : '') + '<b>' + IC.x + '</b></button>';
  };
  return top(backBtn('days', 'Days'), dayTitle(S.day), 'Pass 1 · tap the misses') +
    '<div class="scroll"><div class="sw-grid">' + S.stacks.map(tile).join('') + '</div>' +
    '<p class="note">' + S.stacks.length + ' stacks in shot order, nothing pre-selected. A burst tile rejects the whole burst. Press and hold a tile to see it large.</p></div>' +
    '<div class="foot"><button class="pb2 pri" data-act="sweep-done">' + sweepLabel() + '</button></div>';
}

function vCull() {
  const s = S.stacks[S.cursor], f = shown(s), st = status(s), n = S.stacks.length;
  const burst = s.frames.length > 1, sugg = s.kind === 'pano' || s.kind === 'bracket';
  const pill = st.done ? '<span class="pill p-' + st.v + '">' + ({ keep: 'Kept', hero: 'Hero', reject: 'Rejected' })[st.v] + '</span>' : '';
  const chip = burst ? '<button class="chip" data-act="picker" aria-label="Open burst of ' + s.frames.length + '">' + IC.stack + '<span>' + s.frames.length + '</span></button>'
    : f.partners.length ? '<span class="chip static">RAW + ' + esc(f.partners.map(p => p.split('.').pop().toUpperCase()).join(' + ')) + '</span>' : '';
  const badges = (s.kind === 'pano' ? '<span class="bd bd-dot">Looks like a panorama</span>'
    : s.kind === 'bracket' ? '<span class="bd bd-dot">Looks like a bracket</span>'
    : burst && f.id === s.lead ? '<span class="bd bd-dot">Sharpest</span>' : '') +
    f.badges.map(b => '<span class="bd">' + esc(b) + '</span>').join('');
  const strip = burst ? '<button class="strip" data-act="picker">' + s.frames.slice(0, 6).map(x =>
      '<img src="' + img(x.id, 'thumb') + '" alt="" class="m-' + markOf(x) + '">').join('') +
      (s.frames.length > 6 ? '<span class="more">+' + (s.frames.length - 6) + '</span>' : '') + '<span class="strip-l">Choose</span></button>'
    : '<div class="strip empty" aria-hidden="true"></div>';
  return top(backBtn('days', 'Days'), dayTitle(S.day), 'Pass 2 · ' + doneCount() + ' of ' + n + ' stacks done',
      '<div class="tools"><button class="ico" data-act="info" aria-label="Photo details">' + IC.info + '</button></div>') +
    '<div class="prog"><i style="width:' + (doneCount() / n * 100).toFixed(1) + '%"></i></div>' +
    '<div class="stage" id="stage"><div class="card' + (burst ? ' is-stack' : '') + '"><img src="' + img(f.id, 'view') + '" alt="' + esc(f.file) + '" draggable="false"><div class="tint"></div>' +
      '<div class="badges">' + badges + '</div>' + pill + chip + '<div class="stamp"><span>KEEP</span></div></div>' +
      '<div class="fname">' + esc([f.file].concat(f.partners).join(' + ')) + ' · ' + (S.cursor + 1) + '/' + n + '</div></div>' +
    strip +
    '<div class="bar"><button class="pb pb-rej" data-act="reject">' + IC.x + '<span>Reject</span></button>' +
      '<button class="pb pb-undo" data-act="undo"' + (S.hist.length ? '' : ' disabled') + '>' + IC.undo + '<span>Undo</span></button>' +
      (burst ? '<button class="pb pb-all' + (sugg ? ' sugg' : '') + '" data-act="keep-all">' + IC.stack + '<span>Keep all ' + s.frames.length + '</span></button>'
        : '<button class="pb pb-hero" data-act="hero">' + IC.star + '<span>Hero</span></button>') +
      '<button class="pb pb-keep" data-act="keep">' + IC.check + '<span>' + (burst ? 'Keep frame' : 'Keep') + '</span></button></div>' +
    '<div class="hint">Swipe ↑ keep · ↓ reject · ← → browse · double-tap for focus</div>';
}

function vStrip() {
  const s = S.stacks[S.cursor], fr = s.frames, pk = S.picker, f = fr[pk.view], on = pk.sel.has(f.id);
  const n = pk.sel.size;
  return top('<button class="tbtn" data-act="close-picker">Cancel</button>', 'Burst of ' + fr.length, 'Tick the keepers') +
    '<div class="pk-main" id="pk-main"><div class="pk-frame"><img src="' + img(f.id, 'view') + '" alt="' + esc(f.file) + '" draggable="false">' +
      '<div class="pk-bd">' + (f.id === s.lead ? '<span class="bd bd-dot">Sharpest</span>' : '') + f.badges.map(b => '<span class="bd">' + esc(b) + '</span>').join('') + '</div>' +
      '<button class="pk-tick' + (on ? ' on' : '') + '" data-act="tick" aria-pressed="' + on + '" aria-label="Keep ' + esc(f.file) + '">' + IC.check + '</button>' +
      '<span class="pk-id">' + esc(stem(f.file)) + ' · ' + (pk.view + 1) + '/' + fr.length + '</span></div></div>' +
    '<div class="pk-strip">' + fr.map((x, i) => '<button class="pk-th' + (i === pk.view ? ' cur' : '') + '" data-act="view" data-i="' + i + '" aria-label="Show ' + esc(x.file) + '">' +
      '<img src="' + img(x.id, 'thumb') + '" alt="">' + (x.id === s.lead ? '<i class="dot"></i>' : '') + (pk.sel.has(x.id) ? '<b>' + IC.check + '</b>' : '') + '</button>').join('') + '</div>' +
    '<p class="pk-note">A dot marks the sharpest frame. Swipe to look, double-tap to check focus, ✓ to keep.</p>' +
    '<div class="foot"><button class="pb2" data-act="pk-reject">Reject all ' + fr.length + '</button>' +
      '<button class="pb2 pri" data-act="pk-keep"' + (n ? '' : ' disabled') + '>' + (n ? 'Keep ' + n + ' · reject ' + (fr.length - n) : 'Tick a keeper') + '</button></div>';
}

function vDuel() {
  const s = S.stacks[S.cursor], fr = s.frames, pk = S.picker, A = fr[pk.champ], B = fr[pk.idx];
  const lab = (f, tag) => '<span class="du-tag">' + tag + '</span><span class="du-id">' + esc(stem(f.file)) + '</span>' +
    '<span class="du-bd">' + (f.id === s.lead ? '<span class="bd bd-dot">Sharpest</span>' : '') + f.badges.map(b => '<span class="bd">' + esc(b) + '</span>').join('') + '</span>';
  return top('<button class="tbtn" data-act="close-picker">Cancel</button>', 'Winner stays', 'Round ' + pk.idx + ' of ' + (fr.length - 1) + ' · tap the better frame') +
    '<div class="du"><button class="du-f" data-act="duel-win" data-w="champ" aria-label="' + esc(A.file) + ' is better"><img src="' + img(A.id, 'view') + '" alt="">' + lab(A, 'Holding') + '</button>' +
    '<button class="du-f" data-act="duel-win" data-w="chal" aria-label="' + esc(B.file) + ' is better"><img src="' + img(B.id, 'view') + '" alt="">' + lab(B, 'Challenger') + '</button></div>' +
    '<div class="du-kept">' + (pk.keepers.length ? 'Also keeping ' + pk.keepers.length : '') + '</div>' +
    '<div class="foot"><button class="pb2" data-act="duel-both">Keep both</button><button class="pb2 pri" data-act="duel-done">Finish: keep ' + (1 + pk.keepers.length) + '</button></div>';
}

const clamp01 = v => Math.min(1, Math.max(0, v));
// Where a screen point falls on the photo, as fractions of the frame (the image is letterboxed
// by object-fit: contain, so the element's box is not the photo's box).
function imagePoint(el, cx, cy) {
  const r = el.getBoundingClientRect(), nw = el.naturalWidth || 3, nh = el.naturalHeight || 2;
  const sc = Math.min(r.width / nw, r.height / nh), dw = nw * sc, dh = nh * sc;
  return { u: clamp01((cx - r.left - (r.width - dw) / 2) / dw), v: clamp01((cy - r.top - (r.height - dh) / 2) / dh) };
}
function openFocus(id, u, v) {
  S.focus = { id, u, v, ret: S.screen };
  S.screen = 'focus';
  draw();
}
function vFocus() {
  const f = frameById(S.focus.id), fromCard = S.focus.ret === 'cull';
  return top(backBtn('close-focus', 'Back'), 'Focus · ' + stem(f.file), '1:1 from the RAW · drag to look around') +
    '<div class="fz" id="fz"><img alt="" draggable="false"><div class="fz-load">Decoding the RAW…</div></div>' +
    '<div class="fz-cap">Double-tap the photo to go back.</div>' +
    (fromCard ? '<div class="foot"><button class="pb2" data-act="reject">Reject</button><button class="pb2 pri" data-act="keep">Keep</button></div>' : '');
}
function loadFocus() {
  const box = $('#fz', view);
  if (!box) return;
  const im = $('img', box), load = $('.fz-load', box), r = box.getBoundingClientRect();
  const dpr = Math.min(3, window.devicePixelRatio || 1);
  const w = Math.min(2400, Math.round(r.width * dpr * 1.6)), h = Math.min(2400, Math.round(r.height * dpr * 1.6));
  const { id, u, v } = S.focus;
  let pos = { x: 0, y: 0 }, cw = 0, ch = 0;
  const place = () => { im.style.transform = 'translate(' + pos.x + 'px,' + pos.y + 'px)'; };
  im.onload = () => {
    cw = im.naturalWidth / dpr; ch = im.naturalHeight / dpr;      // one image pixel per device pixel
    im.style.width = cw + 'px'; im.style.height = ch + 'px';
    pos = { x: (r.width - cw) / 2, y: (r.height - ch) / 2 };
    place();
    load.hidden = true;
  };
  im.onerror = () => { load.textContent = 'Could not decode this frame.'; };
  im.src = '/m/api/crop/' + id + '?x=' + u.toFixed(4) + '&y=' + v.toFixed(4) + '&w=' + w + '&h=' + h;
  let drag = null, lastTapAt = 0;
  box.addEventListener('pointerdown', e => {
    drag = { x: e.clientX, y: e.clientY, px: pos.x, py: pos.y, moved: false };
    try { box.setPointerCapture(e.pointerId); } catch (_) {}
  });
  box.addEventListener('pointermove', e => {
    if (!drag || !cw) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (Math.hypot(dx, dy) > 6) drag.moved = true;
    pos.x = cw < r.width ? (r.width - cw) / 2 : Math.min(0, Math.max(r.width - cw, drag.px + dx));
    pos.y = ch < r.height ? (r.height - ch) / 2 : Math.min(0, Math.max(r.height - ch, drag.py + dy));
    place();
  });
  box.addEventListener('pointerup', () => {
    const moved = drag && drag.moved;
    drag = null;
    if (moved) return;
    const now = performance.now();
    if (now - lastTapAt < 300) closeFocus();
    lastTapAt = now;
  });
}
function closeFocus() {
  const ret = S.focus ? S.focus.ret : 'cull';
  S.focus = null;
  S.screen = ret;
  draw();
}

function vSummary() {
  let keep = 0, hero = 0, rej = 0, none = 0;
  const all = S.stacks.flatMap(s => s.frames);
  for (const f of all) {
    const d = S.dec[f.id];
    if (!d || d.flag === 'none') none++;
    else if (d.flag === 'reject') rej++;
    else if (d.stars === 5) hero++;
    else keep++;
  }
  const rejects = all.filter(f => S.dec[f.id] && S.dec[f.id].flag === 'reject');
  const fromBurst = rejects.filter(f => S.dec[f.id].note), outright = rejects.filter(f => !S.dec[f.id].note);
  const grid = list => '<div class="sm-grid">' + list.map(f => '<button class="sm-th" data-act="rescue" data-id="' + f.id + '" aria-label="Rescue ' + esc(f.file) + '">' +
    '<img src="' + img(f.id, 'thumb') + '" alt="" loading="lazy"><b>' + IC.x + '</b></button>').join('') + '</div>';
  const open = firstOpen(0);
  const decided = all.map(f => S.dec[f.id]).filter(Boolean);
  const by = st => decided.filter(d => d.state === st).length;
  const unsent = by('draft') + by('missing'), queued = by('queued'), landed = by('landed'), conflicts = by('conflict');
  const lr = [];
  if (landed) lr.push(landed + ' in Lightroom');
  if (queued) lr.push(queued + ' waiting for the next Sync AI Cull Data');
  if (by('missing')) lr.push(by('missing') + ' not found in the last sync, will go again');
  if (conflicts) lr.push(conflicts + ' left alone: you had flagged ' + (conflicts > 1 ? 'them' : 'it') + ' yourself');
  const sendLabel = unsent ? 'Send ' + unsent + ' to Lightroom' : queued ? 'Waiting for Lightroom' : landed ? 'In Lightroom' : 'Send to Lightroom';
  return top(backBtn('back-cull', 'Cards'), dayTitle(S.day), open < 0 ? 'Day finished' : 'Rejects so far') +
    '<div class="scroll"><div class="counts"><div><b>' + keep + '</b><span>Kept</span></div><div><b>' + hero + '</b><span>Hero</span></div>' +
      '<div><b>' + rej + '</b><span>Rejected</span></div><div><b>' + none + '</b><span>Unflagged</span></div></div>' +
      (lr.length ? '<p class="sec">Lightroom</p>' + lr.map(t => '<p class="note">' + esc(t) + '</p>').join('') : '') +
      (rejects.length ? (fromBurst.length ? '<p class="sec">From bursts · similar frame kept</p>' + grid(fromBurst) : '') +
        (outright.length ? '<p class="sec">Rejected outright</p>' + grid(outright) : '') + '<p class="note">Tap a frame to rescue it.</p>'
        : '<p class="note">No rejects today.</p>') + '</div>' +
    '<div class="foot"><button class="pb2" data-act="days">Back to days</button><button class="pb2 pri" data-act="send"' + (unsent ? '' : ' disabled') + '>' + sendLabel + '</button></div>';
}

function draw(anim) {
  if (S.screen === 'picker' && !S.picker) S.screen = 'cull';
  if ((S.screen === 'cull' || S.screen === 'picker') && !S.stacks[S.cursor]) S.screen = 'summary';
  const scr = S.screen;
  view.innerHTML = scr === 'days' ? vDays() : scr === 'loading' ? vLoading('Loading the day…')
    : scr === 'error' ? vLoading(S.error || 'Something went wrong')
    : scr === 'sweep' ? vSweep() : scr === 'picker' ? (S.picker.m === 'strip' ? vStrip() : vDuel())
    : scr === 'summary' ? vSummary() : scr === 'focus' ? vFocus() : vCull();
  view.classList.toggle('no-chrome', !S.chrome);
  if (scr === 'cull') {
    bindStage();
    const c = $('.card', view);
    if (c && anim && !reduced()) c.classList.add('enter-' + anim);
    setTimeout(prefetch, 80);
  }
  if (scr === 'picker' && S.picker.m === 'strip') bindPickerSwipe();
  if (scr === 'sweep') bindSweep();
  if (scr === 'focus') requestAnimationFrame(loadFocus);
}
function prefetch() {
  for (let k = 1; k <= 10; k++) {
    const s = S.stacks[S.cursor + k];
    if (!s) break;
    new Image().src = img(shown(s).id, 'view');
    if (k <= 3) for (const f of s.frames.slice(0, 6)) new Image().src = img(f.id, 'thumb');
  }
}

/* ---------------------------------------------------------------- gestures */
function setStamp(card, a, k) {
  const st = $('.stamp', card), tint = $('.tint', card);
  if (!st) return;
  st.dataset.a = a;
  st.firstChild.textContent = a === 'reject' ? 'REJECT' : a === 'hero' ? 'HERO' : a === 'all' ? 'KEEP ALL' : 'KEEP';
  st.style.opacity = k;
  tint.style.background = a === 'reject' ? 'var(--reject)' : 'var(--keep)';
  tint.style.opacity = k * .25;
}
function flyOut(a) {
  if (S.busy) return;
  const card = $('.card', view);
  if (S.screen !== 'cull' || !card || reduced()) return decide(a);
  S.busy = true;
  setStamp(card, a, 1);
  card.style.transition = 'transform .2s ease-in, opacity .2s ease-in';
  card.style.transform = 'translateY(' + (a === 'reject' ? 115 : -115) + '%)';
  card.style.opacity = '0';
  setTimeout(() => { S.busy = false; decide(a); }, 190);
}
function go(d) {
  const n = S.stacks.length;
  if (d > 0 && S.cursor === n - 1) { S.screen = 'summary'; return draw(); }
  S.cursor = Math.max(0, Math.min(n - 1, S.cursor + d));
  saveProgress();
  draw(d > 0 ? 'next' : 'prev');
}
let lastTap = 0, tapT = null;
function tap(x, y) {
  const now = performance.now();
  if (now - lastTap < 300) {            // double-tap: a 1:1 crop of that spot from the RAW
    clearTimeout(tapT); lastTap = 0;
    const el = $('.card img', view), s = S.stacks[S.cursor];
    if (el && s) { const p = imagePoint(el, x, y); openFocus(shown(s).id, p.u, p.v); }
    return;
  }
  lastTap = now;
  tapT = setTimeout(() => { S.chrome = !S.chrome; view.classList.toggle('no-chrome', !S.chrome); }, 300);
}
function bindStage() {
  const stage = $('#stage', view), card = $('.card', view);
  if (!stage || !card) return;
  let st = null;
  const reset = () => { card.style.transition = 'transform .22s cubic-bezier(.2,.8,.2,1)'; card.style.transform = ''; setStamp(card, 'keep', 0); };
  stage.addEventListener('pointerdown', e => {
    if (S.busy || e.button > 0 || e.target.closest('button')) return;
    st = { x: e.clientX, y: e.clientY, axis: null, d: 0, kind: null };
    try { stage.setPointerCapture(e.pointerId); } catch (_) {}
    card.style.transition = 'none';
  });
  stage.addEventListener('pointermove', e => {
    if (!st) return;
    const dx = e.clientX - st.x, dy = e.clientY - st.y;
    if (!st.axis) { if (Math.hypot(dx, dy) < 8) return; st.axis = Math.abs(dx) > Math.abs(dy) ? 'x' : 'y'; }
    if (st.axis === 'y') {
      st.d = dy; st.kind = 'decide';
      card.style.transform = 'translateY(' + dy + 'px)';
      setStamp(card, dy < 0 ? 'keep' : 'reject', Math.min(1, Math.abs(dy) / THRESH));
    } else {
      st.d = dx; st.kind = 'browse';
      card.style.transform = 'translateX(' + dx * .7 + 'px)';
    }
  });
  stage.addEventListener('pointerup', () => {
    if (!st) return;
    const s = st; st = null;
    if (!s.axis) { reset(); return tap(s.x, s.y); }
    if (s.kind === 'decide' && Math.abs(s.d) >= THRESH) return flyOut(s.d < 0 ? 'keep' : 'reject');
    if (s.kind === 'browse' && Math.abs(s.d) >= 70) return go(s.d < 0 ? 1 : -1);
    reset();
  });
  stage.addEventListener('pointercancel', () => { st = null; reset(); });
}
function bindPickerSwipe() {
  const m = $('#pk-main', view);
  if (!m) return;
  let sx = null;
  let lastAt = 0;
  m.addEventListener('pointerdown', e => { if (e.target.closest('button')) return; sx = e.clientX; });
  m.addEventListener('pointerup', e => {
    if (sx === null) return;
    const d = e.clientX - sx; sx = null;
    if (Math.abs(d) > 50) return stripView(S.picker.view + (d < 0 ? 1 : -1));
    const now = performance.now();
    if (now - lastAt < 300) {           // double-tap: focus check on this frame
      lastAt = 0;
      const el = $('.pk-frame img', m), f = S.stacks[S.cursor].frames[S.picker.view];
      if (el) { const p = imagePoint(el, e.clientX, e.clientY); openFocus(f.id, p.u, p.v); }
      return;
    }
    lastAt = now;
  });
}
function stripView(i) { const n = S.stacks[S.cursor].frames.length; S.picker.view = Math.max(0, Math.min(n - 1, i)); draw(); }
function bindSweep() {
  const g = $('.sw-grid', view);
  if (!g) return;
  let t = null, sx = 0, sy = 0, peeked = false;
  const end = () => { clearTimeout(t); t = null; if (peeked) { const p = $('.peek', view); if (p) p.remove(); } };
  g.addEventListener('pointerdown', e => {
    const b = e.target.closest('.sw-t');
    if (!b || b.disabled || e.button > 0) return;
    peeked = false; sx = e.clientX; sy = e.clientY; clearTimeout(t);
    t = setTimeout(() => {
      t = null; peeked = true;
      const s = S.stacks[+b.dataset.i], f = leadOf(s);
      view.insertAdjacentHTML('beforeend', '<div class="peek" aria-hidden="true"><img src="' + img(f.id, 'view') + '" alt=""><span>' +
        esc(stem(f.file)) + (s.frames.length > 1 ? ' · burst of ' + s.frames.length : '') + '</span></div>');
    }, 380);
  });
  g.addEventListener('pointermove', e => { if (t && Math.hypot(e.clientX - sx, e.clientY - sy) > 8) { clearTimeout(t); t = null; } });
  for (const ev of ['pointerup', 'pointercancel', 'pointerleave']) g.addEventListener(ev, end);
  g.addEventListener('click', e => { if (peeked) { peeked = false; e.stopPropagation(); e.preventDefault(); } }, true);
  g.addEventListener('contextmenu', e => e.preventDefault());
}

/* ---------------------------------------------------------------- navigation */
async function showDays() {
  S.screen = 'days'; S.day = null; S.stacks = []; S.hist = [];
  if (location.hash !== '#/') history.replaceState(null, '', '#/');
  draw();
  try { S.days = (await getJSON('/m/api/days')).days; }
  catch (e) { S.screen = 'error'; S.error = 'Could not load days: ' + e.message; }
  if (S.screen === 'days' || S.screen === 'error') draw();
}
async function openDay(day) {
  S.screen = 'loading'; draw();
  let body;
  try { body = await getJSON('/m/api/day/' + dayPath(day)); }
  catch (e) { S.screen = 'error'; S.error = 'Could not load ' + day + ': ' + e.message; return draw(); }
  S.day = body; S.stacks = body.stacks; S.dec = {}; S.hist = []; S.picker = null; S.sweepSel = new Set();
  for (const s of S.stacks) for (const f of s.frames) if (f.decision) S.dec[f.id] = f.decision;
  const p = body.progress, any = Object.keys(S.dec).length > 0;
  S.pass = p ? p.pass : (any ? 2 : 1);
  S.cursor = p ? Math.min(p.cursor, S.stacks.length - 1) : 0;
  if (S.pass === 1) S.screen = 'sweep';
  else {
    const i = status(S.stacks[S.cursor] || {}).done ? firstOpen(S.cursor) : S.cursor;
    if (i < 0) S.screen = 'summary'; else { S.cursor = i; S.screen = 'cull'; }
  }
  const hash = '#/day/' + day;
  if (location.hash !== hash) history.replaceState(null, '', hash);
  draw();
}
function sweepDone() {
  const idx = [...S.sweepSel].sort((a, b) => a - b);
  const changes = idx.flatMap(i => S.stacks[i].frames.filter(f => !status(S.stacks[i]).done).map(f => ({ id: f.id, flag: 'reject', note: '', via: 'sweep' })));
  if (changes.length) act('swept ' + idx.length, changes, { screen: 'sweep', sel: idx });
  S.sweepSel = new Set(); S.pass = 2;
  const i = firstOpen(0);
  if (i < 0) { S.screen = 'summary'; saveProgress(true); } else { S.cursor = i; S.screen = 'cull'; saveProgress(); }
  toast((idx.length ? 'Rejected ' + idx.length + (idx.length === 1 ? ' stack' : ' stacks') + ' · ' : '') + 'Pass 2: choose what to keep', !!changes.length);
  draw('next');
}
// Send: every queued tap must reach the server first, so the day is sent whole.
async function sendDay(btn) {
  btn.disabled = true;
  pump();
  for (let i = 0; i < 40 && Q.items.length; i++) await new Promise(r => setTimeout(r, 250));
  if (Q.items.length) { btn.disabled = false; return toast('Still offline: ' + Q.items.length + ' taps waiting to save. Send once they are in.'); }
  let body;
  try {
    const r = await fetch('/m/api/day/' + dayPath(S.day.day) + '/send', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Culling-Bay': '1' }, body: '{}' });
    body = await r.json();
    if (!r.ok) throw new Error(body.error || 'HTTP ' + r.status);
  } catch (e) { btn.disabled = false; return toast('Not sent: ' + e.message); }
  for (const id in S.dec) if (S.dec[id].state === 'draft' || S.dec[id].state === 'missing') S.dec[id].state = 'queued';
  toast(body.queued ? 'Queued ' + body.queued + ' for Lightroom. On the Mac: Sync AI Cull Data.' : 'Nothing new to send.');
  draw();
}

function openPicker() {
  const s = S.stacks[S.cursor];
  if (!s || s.frames.length < 2) return;
  if (s.frames.length <= PICKER_STRIP_MAX) {
    S.picker = { m: 'strip', sel: new Set(s.frames.filter(f => isPick(S.dec[f.id])).map(f => f.id)), view: s.frames.indexOf(shown(s)) };
  } else {
    S.picker = { m: 'duel', champ: 0, idx: 1, keepers: [] };
  }
  S.screen = 'picker';
  draw();
}
function finishDuel() {
  const s = S.stacks[S.cursor], pk = S.picker;
  keepFrames(s, [s.frames[pk.champ]].concat(pk.keepers.map(i => s.frames[i])), false, 'burst');
}

/* ---------------------------------------------------------------- input */
document.addEventListener('click', e => {
  const b = e.target.closest('[data-act]');
  if (!b || b.disabled) return;
  const a = b.dataset.act, s = S.stacks[S.cursor];
  switch (a) {
    case 'open-day': return openDay(b.dataset.day);
    case 'days': return showDays();
    case 'keep': case 'reject': case 'hero':
      if (S.screen === 'focus') { S.focus = null; S.screen = 'cull'; return decide(a); }
      return flyOut(a);
    case 'keep-all': return flyOut('all');
    case 'undo': return undo();
    case 'info': return openSheet();
    case 'close-sheet': return closeSheet();
    case 'close-focus': return closeFocus();
    case 'picker': return openPicker();
    case 'close-picker': S.picker = null; S.screen = 'cull'; return draw();
    case 'view': return stripView(+b.dataset.i);
    case 'tick': { const f = s.frames[S.picker.view]; S.picker.sel.has(f.id) ? S.picker.sel.delete(f.id) : S.picker.sel.add(f.id); return draw(); }
    case 'pk-keep': { const keeps = s.frames.filter(f => S.picker.sel.has(f.id)); if (keeps.length) keepFrames(s, keeps, false, 'burst'); return; }
    case 'pk-reject': return decide('reject');
    case 'duel-win': { const pk = S.picker; if (b.dataset.w === 'chal') pk.champ = pk.idx; pk.idx++; return pk.idx >= s.frames.length ? finishDuel() : draw(); }
    case 'duel-both': { const pk = S.picker; pk.keepers.push(pk.idx); pk.idx++; return pk.idx >= s.frames.length ? finishDuel() : draw(); }
    case 'duel-done': return finishDuel();
    case 'sweep-tick': {
      const i = +b.dataset.i, on = !S.sweepSel.has(i);
      on ? S.sweepSel.add(i) : S.sweepSel.delete(i);
      b.classList.toggle('on', on); b.setAttribute('aria-pressed', String(on));
      const d = $('[data-act="sweep-done"]', view); if (d) d.textContent = sweepLabel();
      return;
    }
    case 'sweep-done': return sweepDone();
    case 'back-cull': { const i = firstOpen(S.cursor); if (i >= 0) S.cursor = i; S.screen = 'cull'; return draw(); }
    case 'rescue': {
      const f = frameById(+b.dataset.id);
      act('Rescued ' + stem(f.file), [{ id: f.id, flag: 'pick', note: '', via: 'rescue' }], { screen: 'summary' });
      toast('Rescued ' + stem(f.file), true);
      return draw();
    }
    case 'send': return sendDay(b);
  }
});
document.addEventListener('keydown', e => {
  if (e.target.matches('input, textarea')) return;
  const k = e.key;
  if (k === 'Escape') { if (S.sheet) closeSheet(); else if (S.screen === 'focus') closeFocus(); else if (S.screen === 'picker') { S.picker = null; S.screen = 'cull'; draw(); } return; }
  if (S.sheet) return;
  if (k === 'z' || k === 'Z' || k === 'Backspace') { e.preventDefault(); return undo(); }
  if (S.screen === 'picker' && S.picker.m === 'strip') { if (k === 'ArrowLeft' || k === 'ArrowRight') { e.preventDefault(); stripView(S.picker.view + (k === 'ArrowRight' ? 1 : -1)); } return; }
  if (S.screen !== 'cull') return;
  const s = S.stacks[S.cursor], burst = s && s.frames.length > 1;
  if (k === 'ArrowUp' || k === 'k') { e.preventDefault(); flyOut('keep'); }
  else if (k === 'ArrowDown' || k === 'x') { e.preventDefault(); flyOut('reject'); }
  else if (k === 'ArrowRight') { e.preventDefault(); go(1); }
  else if (k === 'ArrowLeft') { e.preventDefault(); go(-1); }
  else if (k === 'a' && burst) flyOut('all');
  else if (k === 'h' && !burst) flyOut('hero');
  else if (k === 'b' || k === 'Enter') openPicker();
  else if (k === 'i') openSheet();
  else if (k === 'f') openFocus(shown(s).id, 0.5, 0.5);
});

function route() {
  const m = location.hash.match(/^#\/day\/(.+)$/);
  if (m) openDay(decodeURIComponent(m[1])); else showDays();
}
window.addEventListener('popstate', route);
route();
pump();
// The service worker keeps the app shell for offline opens; browsers only allow it over HTTPS.
if ('serviceWorker' in navigator && window.isSecureContext) navigator.serviceWorker.register('sw.js').catch(() => {});
})();
