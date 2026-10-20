/* Culling Bay Mobile: cull a day from the NAS on the phone, in two passes.
   Plain JavaScript, no build step. Talks to /m/api (review/mobile.py); every tap is saved on the
   PC at once, through a retry queue that survives a dropped connection or a reload.
   One pass per day: days -> cards (details, burst picker, focus check) -> rejects review, with
   a soft budget of 10 kept stacks an hour of shooting. */
(() => {
'use strict';

const $ = (s, el = document) => el.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const stem = f => f.replace(/\.[^.]+$/, '');
const view = $('#view');
const reduced = () => window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
const NOTE_PREFIX = 'Burst reject · kept ';
const THRESH = 80;          // px of vertical drag that commits a keep or reject
const PICKER_STRIP_MAX = 6; // bursts up to this size open as a filmstrip; bigger ones as a knock-out grid
const BAND_MIN = 80;        // px: a 1:1 band shorter than this isn't worth showing

const IC = {
  x: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/></svg>',
  check: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  undo: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 14L4 9l5-5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
  star: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.8l-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z" fill="currentColor"/></svg>',
  info: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M12 11v6M12 7.5v.01" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>',
  back: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  stack: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="4" width="13" height="11" rx="2" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M4 8v10a2 2 0 0 0 2 2h10" fill="none" stroke="currentColor" stroke-width="1.9"/></svg>',
  focus: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="6.5" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M16 16l4.5 4.5" stroke="currentColor" stroke-width="2.1" stroke-linecap="round"/></svg>',
  restart: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><path d="M4.5 4.5v3.7h3.7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  grid: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="4" width="7" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.9"/><rect x="13" y="4" width="7" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.9"/><rect x="4" y="13" width="7" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.9"/><rect x="13" y="13" width="7" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.9"/></svg>',
};

const S = {
  screen: 'days', days: null, day: null, stacks: [], dec: {},
  pass: 2, cursor: 0, hist: [], picker: null,
  chrome: true, busy: false, sheet: false, focus: null, gridFrom: null, gridFilter: 'all',
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
  const st = S.stacks[S.cursor], day = S.day.day, body = { pass: S.pass, cursor: st ? st.id : 0, finished: !!finished };
  if (st && typeof st.lead === 'number') body.lead = st.lead;
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
// A flag you set in Lightroom by hand (reported back by the plugin's catalog file). Flags the
// plugin set from the phone come back as by 'phone' and are already in S.dec.
// A reject flag rejects; a pick flag, or a star rating without a reject, means you have already
// been through the photo there.
function lrMark(f) {
  if (!f.lr) return null;
  if (f.lr.by === 'you' && f.lr.pick === -1) return 'reject';
  if (f.lr.by === 'you' && f.lr.pick === 1) return 'pick';
  if (f.lr.stars_by === 'you' && f.lr.rating > 0) return 'rated';
  return null;
}
const lrWord = f => ({ pick: 'Picked in Lightroom', reject: 'Rejected in Lightroom', rated: '★' + (f.lr && f.lr.rating) + ' in Lightroom' })[lrMark(f)];
const lrShort = f => ({ pick: 'Picked in LR', reject: 'Rejected in LR', rated: '★' + (f.lr && f.lr.rating) + ' in LR' })[lrMark(f)] || 'Kept as you set it';
function status(s) {
  const ds = s.frames.map(f => S.dec[f.id]);
  const kept = ds.find(isPick);
  if (kept) return { done: true, v: ds.some(d => isPick(d) && d.stars === 5) ? 'hero' : 'keep', src: 'phone' };
  if (ds.every(d => d && d.flag === 'reject')) return { done: true, v: 'reject', src: 'phone' };
  const lr = s.frames.map(lrMark);
  if (lr.includes('pick') || lr.includes('rated')) return { done: true, v: 'keep', src: 'lr', frame: s.frames.find(f => lrMark(f) === 'pick') || s.frames.find(f => lrMark(f) === 'rated') };
  if (lr.every(m => m === 'reject')) return { done: true, v: 'reject', src: 'lr' };
  return { done: false };
}
// How many of these changes disagree with a flag you set in Lightroom (that flag will win).
function lrClashes(changes) {   // only flags clash: Lightroom keeps a flag you set by hand
  return changes.filter(c => { const m = lrMark(frameById(c.id)); return (m === 'pick' || m === 'reject') && c.flag !== 'none' && m !== c.flag; }).length;
}
function lrRatedRejects(changes) {   // a reject lands on a rated photo; the stars stay
  return changes.filter(c => c.flag === 'reject' && lrMark(frameById(c.id)) === 'rated').length;
}
const clashNote = (n, rated) => (n ? ' · Lightroom keeps your own flag on ' + (n > 1 ? n + ' of them' : 'it') : '') +
  (rated ? ' · ' + (rated > 1 ? rated + ' had' : 'it had') + ' your stars in Lightroom' : '');
const firstOpen = (from = 0) => {
  const n = S.stacks.length;
  for (let k = 0; k < n; k++) { const i = (from + k) % n; if (!status(S.stacks[i]).done) return i; }
  return -1;
};
const markOf = f => (S.dec[f.id] ? S.dec[f.id].flag : 'none');
// One frame's decision for the marks on a photo: the phone's, else your Lightroom flag or stars.
function frameMark(f) {
  const d = S.dec[f.id], lrStars = (f.lr && f.lr.rating) || 0;
  if (d && d.flag === 'reject') return { v: 'reject', text: 'Rejected', stars: 0 };
  if (d && d.flag === 'pick') return { v: d.stars === 5 ? 'hero' : 'keep', text: d.stars === 5 ? 'Hero' : 'Kept', stars: d.stars || lrStars };
  const m = lrMark(f);
  if (m === 'reject') return { v: 'reject', text: 'Rejected in Lightroom', stars: 0 };
  if (m) return { v: 'keep', text: m === 'pick' ? 'Picked in Lightroom' : 'Rated in Lightroom', stars: lrStars };
  return null;
}
const starText = n => (n ? '★'.repeat(n) : '');
const doneCount = () => S.stacks.filter(s => status(s).done).length;
const lrDone = () => S.stacks.filter(s => status(s).src === 'lr').length;
function dayTitle(d) {
  if (!d.date) return d.folder;
  const [y, m, dd] = d.date.split('-').map(Number);
  return new Date(y, m - 1, dd).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
}

// The gesture hint goes once you have culled on three different days.
const HINT_DAYS = 3;
const hintDays = () => recall('cbm-hint-days', []);
function noteHintDay() {
  const d = new Date().toISOString().slice(0, 10), days = hintDays();
  if (!days.includes(d) && days.length < HINT_DAYS) store('cbm-hint-days', days.concat(d));
}

/* one action = one tap; saved to the server and to the undo history */
function act(label, changes, extra) {
  const before = changes.map(c => [c.id, S.dec[c.id] ? Object.assign({}, S.dec[c.id]) : null]);
  for (const c of changes) {
    S.dec[c.id] = { flag: c.flag, stars: c.flag === 'pick' ? (c.stars || null) : null, note: c.note || '', state: 'draft', outcome: null };
  }
  noteHintDay();
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
  toast(label + clashNote(lrClashes(changes), lrRatedRejects(changes)) + (changes.some(c => c.flag === 'pick') ? overNote() : ''), true);
  advance();
}
function advance() {
  const i = firstOpen(S.cursor + 1);
  if (i < 0) { S.screen = 'summary'; saveProgress(true); }
  else { S.cursor = i; S.screen = 'cull'; saveProgress(); }
  draw('dec');
}
// rates: {frame id: stars} from the star row; a frame without one is kept unrated.
function keepFrames(s, keeps, rates, via) {
  rates = rates || {};
  const changes = keeps.map(f => ({ id: f.id, flag: 'pick', stars: rates[f.id] || null, note: '', via }));
  const others = s.frames.filter(f => !keeps.includes(f));
  const note = NOTE_PREFIX + keeps.map(f => stem(f.file)).join(', ');
  for (const f of others) changes.push({ id: f.id, flag: 'reject', note, via });
  const head = 'Kept ' + (keeps.length > 1 ? keeps.length + ' frames' : stem(keeps[0].file) + (rates[keeps[0].id] ? ' ' + starText(rates[keeps[0].id]) : ''));
  commit(others.length ? head + ' · ' + others.length + ' rejected with a note' : head, changes);
}
function decide(a, stars) {   // stars: from the star row, keeping the photo with that rating
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
  const f = shown(s);
  keepFrames(s, [f], stars ? { [f.id]: stars } : null, 'card');
}
// The star row: one tap keeps the photo with that rating (as in Thumbs). In the burst picker it
// rates the frame you are looking at, and ticks it.
const starRow = (rated, label) => '<div class="stars" role="group" aria-label="' + (label || 'Keep with stars') + '">' + [1, 2, 3, 4, 5].map(n =>
  '<button data-act="star" data-n="' + n + '" class="' + (n <= rated ? 'on' : '') + '" aria-label="' + n + ' star' + (n > 1 ? 's' : '') + '">' + IC.star + '</button>').join('') + '</div>';

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
  if (f.lr && (f.lr.pick || f.lr.rating)) {
    const bits = [];
    if (f.lr.pick) bits.push((f.lr.pick === 1 ? 'picked' : 'rejected') + (f.lr.by === 'you' ? ' by you' : ' from the phone'));
    if (f.lr.rating) bits.push(f.lr.rating + ' star' + (f.lr.rating > 1 ? 's' : '') + (f.lr.stars_by === 'you' ? ' by you' : ' from the phone'));
    lines.push('In Lightroom at the last sync: ' + bits.join(', ') + '.');
  }
  if (s.kind === 'bracket') lines.push('Looks like an exposure bracket: dark, normal and bright frames together. Keep all to merge it in Lightroom.');
  if (s.kind === 'pano') lines.push('The frames slide one way, like a panorama, so Keep all is suggested.');
  const html = '<div class="sheet" role="dialog" aria-label="Photo details"><div class="sh-grab"></div>' +
    '<p class="sh-id">' + esc(files) + '</p>' +
    (f.lens || f.place ? '<p class="sh-muted">' + esc([f.lens, f.place ? 'near ' + f.place : ''].filter(Boolean).join(' · ')) + '</p>' : '') +
    lines.map(l => '<p class="sh-why">' + esc(l) + '</p>').join('') +
    (d && d.note ? '<p class="sh-why">Lightroom note: ' + esc(d.note) + '</p>' : '') +
    (f.caption ? '<p class="sh-cap">“' + esc(f.caption) + '”</p>' : '') +
    '<p class="sh-muted">The AI’s caption. Its keep, review and reject verdicts stay off the phone.</p>' +
    '<button class="pb2" data-act="like" data-id="' + f.id + '" data-name="' + esc(stem(f.file)) + '">More like this: days with similar photos</button>' +
    '<button class="pb2" data-act="close-sheet">Close</button></div>';
  const el = $('#sheet');
  el.innerHTML = html;
  el.hidden = false;
  S.sheet = true;
}
$('#sheet').addEventListener('click', e => { if (e.target.id === 'sheet') closeSheet(); });

/* ---------------------------------------------------------------- photo boxes */
// Every large photo sits in a box sized to the photo's own shape, fitted into the space around
// it, so outlines, the status line and badges land on the photo, not on letterbox bars. Shapes
// are learned from any image of the frame that has loaded (thumbnails, prefetches).
const AR = {};
function noteAR(id, im) { if (im.naturalWidth && im.naturalHeight) AR[id] = im.naturalWidth / im.naturalHeight; }
document.addEventListener('load', e => { const t = e.target; if (t.tagName === 'IMG' && t.dataset.fid) noteAR(t.dataset.fid, t); }, true);
const photo = (f, inner) => '<div class="photo" data-fid="' + f.id + '"><img src="' + img(f.id, 'view') + '" alt="' + esc(f.file) +
  '" draggable="false" data-fid="' + f.id + '">' + (inner || '') + '</div>';
const thumb = (f, cls) => '<img src="' + img(f.id, 'thumb') + '" alt="" data-fid="' + f.id + '"' + (cls ? ' class="' + cls + '"' : '') + ' loading="lazy">';
function fitPhoto(p) {
  const box = p.parentElement, W = box.clientWidth, H = box.clientHeight, ar = AR[p.dataset.fid] || 1.5;
  if (!W || !H) return;
  let w = W, h = W / ar;
  if (h > H) { h = H; w = H * ar; }
  p.style.width = Math.floor(w) + 'px';
  p.style.height = Math.floor(h) + 'px';
}
// A card is as tall as a landscape photo needs; a vertical photo takes all the height there is.
function shapeCard(card, id) {
  const ar = AR[id];
  if (!card || !ar) return;
  card.classList.toggle('k-fill', ar < 1);
  card.classList.toggle('k-land', ar >= 1);
  card.style.aspectRatio = ar < 1 ? '' : ar.toFixed(4);
  if (ar < 1) dropBand();   // a vertical photo uses the height itself
}
// timing (perf-client.js): on the cull card, how long from drawing it to its photo being ready,
// so a decision followed by a wait for the next photo shows up; and a day's first photo.
function bindPhotos(root, perfT) {
  let first = root.dataset.screen === 'cull' && perfT !== undefined;
  for (const p of root.querySelectorAll('.photo')) {
    const im = p.querySelector('img'), id = p.dataset.fid, timed = first;
    first = false;
    const ready = () => {
      noteAR(id, im); shapeCard(p.closest('.card'), id); fitPhoto(p);
      if (timed && window.cbPerf) {
        const ms = performance.now() - perfT, waited = !preloaded;
        cbPerf.mark('card_photo', ms, { name: img(id, 'view'), detail: waited ? 'waited' : 'prefetched' });
        if (S.perfDay !== undefined) { cbPerf.mark('day_open', performance.now() - S.perfDay, { detail: S.day && S.day.day }); S.perfDay = undefined; }
      }
    };
    const preloaded = im.complete && im.naturalWidth;
    if (preloaded) ready(); else { im.addEventListener('load', ready, { once: true }); fitPhoto(p); }
  }
}
window.addEventListener('resize', () => { for (const p of view.querySelectorAll('.photo')) fitPhoto(p); });
// Turning the phone swaps layouts (app.css); redraw so the 1:1 band is measured for the new one.
if (window.matchMedia) matchMedia('(orientation: landscape)').addEventListener('change', () => { if (S.screen === 'cull') draw(); });
function loadShape(id, ms) {   // the photo's shape before its card is drawn, so it doesn't jump
  if (AR[id]) return Promise.resolve();
  return new Promise(res => {
    const im = new Image(), t = setTimeout(res, ms);
    im.onload = () => { noteAR(id, im); clearTimeout(t); res(); };
    im.onerror = () => { clearTimeout(t); res(); };
    im.src = img(id, 'view');
  });
}

// What a decided stack shows when you come back to it: a line on the photo, and its outline.
function stLine(s, st) {
  if (!st.done) return '';
  const n = s.frames.length, f = shown(s);
  let t, stars = 0;
  if (st.src === 'lr') {
    const m = frameMark(st.frame || f) || { text: 'Rejected in Lightroom', stars: 0 };
    t = st.v === 'reject' && n > 1 ? 'Rejected in Lightroom · all ' + n + ' frames' : m.text;
    stars = m.stars;
  } else if (st.v === 'reject') {
    t = n > 1 ? 'Rejected · all ' + n + ' frames' : 'Rejected';
  } else {
    const k = s.frames.filter(x => isPick(S.dec[x.id])).length;
    t = n === 1 ? (st.v === 'hero' ? 'Hero' : 'Kept')
      : k === n ? 'Kept all ' + n + (s.kind === 'bracket' ? ' · bracket' : s.kind === 'pano' ? ' · panorama' : '')
      : k > 1 ? 'Kept ' + k + ' of ' + n + ' · ' + (n - k) + ' rejected'
      : 'Kept ' + stem(f.file) + ' · ' + (n - 1) + ' other' + (n > 2 ? 's' : '') + ' rejected';
    stars = (frameMark(f) || {}).stars || 0;
  }
  if (s.frames.some(x => S.dec[x.id] && S.dec[x.id].state === 'conflict')) t += ' · your Lightroom flag won';
  return '<div class="stline ' + st.v + '"><i>' + (st.v === 'reject' ? IC.x : IC.check) + '</i><span>' + esc(t) + '</span>' +
    (stars ? '<em>' + starText(stars) + '</em>' : '') + '</div>';
}

/* ---------------------------------------------------------------- views */
const top = (left, title, sub, right, subHtml) =>
  '<div class="top">' + left + '<div class="t">' + esc(title) + (sub ? '<small>' + esc(sub) + '</small>' : subHtml ? '<small>' + subHtml + '</small>' : '') + '</div>' + (right || '<span class="sp"></span>') + '</div>' +
  '<div class="net"' + (Q.offline ? '' : ' hidden') + '>Offline · ' + Q.items.length + ' waiting to save</div>';
const backBtn = (act, label) => '<button class="tbtn" data-act="' + act + '">' + IC.back + '<span>' + label + '</span></button>';

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const store = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} };
const recall = (k, d) => { try { const v = JSON.parse(localStorage.getItem(k)); return v === null ? d : v; } catch (_) { return d; } };
S.dayView = recall('cbm-dayview', 'date');
S.daySearch = '';
S.yearsOpen = null;   // set of open years; the newest starts open
const yearOf = d => d.day.slice(0, 4);
const town = p => (p ? p.split(', ').slice(0, 2).join(', ') : '');
const regionOf = p => { const parts = p.split(', '); return parts.length > 1 ? parts.slice(1).join(', ') : p; };
const lrCulled = d => !d.decided && !d.finished && d.stacks && d.lr_done >= d.stacks;

// A shoot under 48 hours old is marked as resting: a nudge to cull it with fresh eyes, never a block.
const resting = d => !d.decided && !d.finished && d.last_ts && Date.now() / 1000 - d.last_ts < 48 * 3600;
function dayRow(d, hit) {   // hit: a search result for the day, {why, ids}
  if (!hit || typeof hit !== 'object') hit = null;
  const pct = d.frames ? Math.round(d.decided / d.frames * 100) : 0;
  const tag = d.conflicts ? '<span class="tag warn">' + d.conflicts + ' conflict' + (d.conflicts > 1 ? 's' : '') + '</span>'
    : d.landed ? '<span class="tag quiet">Synced</span>'
    : d.sent_at ? '<span class="tag quiet">Sent</span>'
    : d.finished ? '<span class="tag quiet">Done</span>'
    : lrCulled(d) ? '<span class="tag quiet">In Lightroom</span>'
    : d.decided ? '<span class="tag">' + pct + '%</span>'
    : resting(d) ? '<span class="tag quiet" title="Shot in the last two days">Resting</span>' : '';
  const meta = [d.frames + ' frames', d.stacks + ' stacks'];
  if (d.lr_done && d.lr_done < d.stacks) meta.push(d.lr_done + ' done in Lightroom');
  if (!d.date) meta.push(d.day);
  // a search hit shows its matching photos first, topped up from the day's own
  const thumbs = hit && hit.ids.length ? hit.ids.concat(d.thumbs.filter(id => !hit.ids.includes(id))).slice(0, 3) : d.thumbs;
  return '<button class="day" data-act="open-day" data-day="' + esc(d.day) + '"><span class="mos">' +
    thumbs.map(id => '<img src="' + img(id, 'thumb') + '" alt="" loading="lazy">').join('') + '</span>' +
    '<span class="day-b"><b>' + esc(dayTitle(d)) + '</b><span>' + esc(meta.join(' · ')) + '</span>' +
    (d.place ? '<span class="place">' + esc(town(d.place)) + '</span>' : '') +
    (hit && hit.why ? '<span class="why">' + esc(hit.why) + '</span>'
      : d.summary ? '<span class="dsum">' + d.summary.split('\n').map(esc).join('<br>') + '</span>' : '') +
    (d.decided ? '<span class="day-bar"><i style="width:' + pct + '%"></i></span>' : '') + '</span>' + tag + '</button>';
}

function daysByDate(list, searching) {
  const years = [];
  for (const d of list) { const y = yearOf(d); if (!years.includes(y)) years.push(y); }
  if (!S.yearsOpen) S.yearsOpen = new Set(recall('cbm-years-open', years.slice(0, 1)));
  return years.map(y => {
    const days = list.filter(d => yearOf(d) === y), open = searching || S.yearsOpen.has(y);
    const frames = days.reduce((n, d) => n + d.frames, 0), done = days.filter(d => d.finished || lrCulled(d)).length;
    const head = '<button class="year" data-act="toggle-year" data-year="' + y + '" id="year-' + y + '" aria-expanded="' + open + '">' +
      '<b>' + y + '</b><span>' + days.length + ' day' + (days.length > 1 ? 's' : '') + ' · ' + frames.toLocaleString() + ' frames' + (done ? ' · ' + done + ' done' : '') + '</span><i>' + (open ? '−' : '+') + '</i></button>';
    if (!open) return head;
    const months = [];
    for (const d of days) { const m = d.date ? MONTHS[+d.date.slice(5, 7) - 1] : 'Other folders'; if (!months.includes(m)) months.push(m); }
    return head + months.map(m => {
      const md = days.filter(d => (d.date ? MONTHS[+d.date.slice(5, 7) - 1] : 'Other folders') === m);
      return '<p class="sec">' + m + ' · ' + md.length + '</p>' + md.map(d => dayRow(d)).join('');
    }).join('');
  }).join('');
}

function daysByPlace(list) {
  const placed = list.filter(d => d.place), regions = [];
  for (const d of placed) { const r = regionOf(d.place); if (!regions.includes(r)) regions.push(r); }
  const unplaced = list.length - placed.length;
  return regions.map(r => {
    const rd = placed.filter(d => regionOf(d.place) === r);
    return '<p class="sec">' + esc(r) + ' · ' + rd.length + '</p>' + rd.map(d => dayRow(d)).join('');
  }).join('') + '<p class="note">' + (placed.length ? '' : 'No locations yet. ') + unplaced + ' day' + (unplaced === 1 ? '' : 's') +
    ' without a location: GPS comes only from the Sony when it is paired with your phone, and from iPhone shots.</p>';
}

// On this day: unculled days from this week in earlier years, so the backlog comes back a few
// days at a time.
function onThisDay() {
  const now = new Date(), md = Date.UTC(2000, now.getMonth(), now.getDate()), year = 366 * 864e5;
  return S.days.filter(d => {
    if (!d.date || +d.date.slice(0, 4) >= now.getFullYear() || d.decided || d.finished || lrCulled(d)) return false;
    const diff = Math.abs(Date.UTC(2000, +d.date.slice(5, 7) - 1, +d.date.slice(8, 10)) - md);
    return Math.min(diff, year - diff) <= 3 * 864e5;
  }).slice(0, 4);
}
function dayListHTML() {
  if (S.like || S.daySearch.trim()) return resultsHTML();
  const going = S.days.filter(d => d.decided && !d.finished);
  const rest = S.days.filter(d => !(d.decided && !d.finished));
  const lane = onThisDay();
  return (going.length ? '<p class="sec">In progress</p>' + going.map(d => dayRow(d)).join('') : '') +
    (lane.length ? '<p class="sec">On this day · earlier years</p>' + lane.map(d => dayRow(d)).join('') : '') +
    (S.dayView === 'place' ? daysByPlace(rest) : daysByDate(rest, false));
}

/* ---------------------------------------------------------------- search */
// The box asks the server (review/search.py): words, places and dates, plus meaning from the
// captions and from the pictures. Results are days, each with its matching photos, which open
// first. More like this, from a photo's details, lists days with similar pictures.
S.found = null;   // the last search answered: {q, days: [{day, n, ids, match_ids, why}], photos, signals, notes}
S.like = null;    // {id, name, found} while showing More like this
let searchT = 0, searchSeq = 0;
function runSearch() {
  clearTimeout(searchT);
  const q = S.daySearch.trim();
  if (q) searchT = setTimeout(async () => {
    const seq = ++searchSeq;
    let r;
    try { r = await getJSON('/m/api/search?q=' + encodeURIComponent(q)); }
    catch (e) { r = { days: [], photos: 0, signals: [], notes: ['Search failed: ' + e.message] }; }
    if (seq !== searchSeq || S.daySearch.trim() !== q) return;
    S.found = Object.assign(r, { q });
    refreshDays();
  }, 280);
  refreshDays();
}
function refreshDays() {
  const el = $('#days-list');
  if (el) el.innerHTML = dayListHTML();
  const x = $('#search-x');
  if (x) x.hidden = !(S.daySearch || S.like);
}
const SIGNALS = { words: 'words', captions: 'captions', pictures: 'what’s in the pictures' };
const andList = a => (a.length > 1 ? a.slice(0, -1).join(', ') + ' and ' + a[a.length - 1] : a[0] || '');
function hitsHTML(found, head) {
  const byDay = {};
  for (const d of S.days) byDay[d.day] = d;
  const hits = found.days.filter(h => byDay[h.day]), n = hits.length;
  const sig = (found.signals || []).filter(x => SIGNALS[x]).map(x => SIGNALS[x]);
  return '<p class="rnote">' + head + (n ? n + ' day' + (n === 1 ? '' : 's') +
      (found.photos ? ' · ' + found.photos.toLocaleString() + ' photo' + (found.photos === 1 ? '' : 's') : '') +
      (sig.length ? ', by ' + andList(sig) : '') + '.' : 'No days match.') + '</p>' +
    (found.notes || []).map(t => '<p class="note">' + esc(t) + '</p>').join('') +
    hits.map(h => dayRow(byDay[h.day], h)).join('');
}
function resultsHTML() {
  if (S.like) {
    const head = '<b>More like this:</b> days with photos like ' + esc(S.like.name) + '. ';
    return S.like.found ? hitsHTML(S.like.found, head) : '<p class="rnote">' + head + 'Looking…</p>';
  }
  const f = S.found;
  if (!f) return '<p class="rnote">Searching…</p>';
  return (f.q !== S.daySearch.trim() ? '<p class="rnote">Searching…</p>' : '') + hitsHTML(f, '');
}
async function showLike(id, name) {
  closeSheet();
  S.like = { id, name, found: null };
  S.daySearch = ''; S.found = null;
  showDays();
  let r;
  try { r = await getJSON('/m/api/like/' + id); }
  catch (e) { r = { days: [], photos: 0, signals: [], notes: ['More like this failed: ' + e.message] }; }
  if (S.like && S.like.id === id) { S.like.found = r; refreshDays(); }
}
function clearSearch() {
  S.daySearch = ''; S.like = null; S.found = null;
  const i = $('#day-search');
  if (i) i.value = '';
  refreshDays();
}

function vDays() {
  if (!S.days) return top('<span class="sp"></span>', 'Culling Bay') + '<div class="empty-state">Loading days…</div>';
  const years = [];
  for (const d of S.days) { const y = yearOf(d); if (!years.includes(y)) years.push(y); }
  return '<div class="head"><h1>Days</h1><span>mycloud · Pictures · ' + S.days.length + ' days</span>' +
    '<a class="glink" href="/m/gallery.html">Gallery ›</a></div>' +
    '<div class="net"' + (Q.offline ? '' : ' hidden') + '>Offline · ' + Q.items.length + ' waiting to save</div>' +
    '<div class="dtools"><label class="sbox"><input class="search" id="day-search" type="search" placeholder="Search what, where, when" value="' + esc(S.daySearch) + '" autocomplete="off" enterkeyhint="search" aria-label="Search days">' +
    '<button class="sx" id="search-x" data-act="q-clear" aria-label="Clear the search"' + (S.daySearch || S.like ? '' : ' hidden') + '>×</button></label>' +
    '<div class="seg" role="tablist"><button data-act="day-view" data-v="date" aria-selected="' + (S.dayView !== 'place') + '">Date</button>' +
    '<button data-act="day-view" data-v="place" aria-selected="' + (S.dayView === 'place') + '">Place</button></div></div>' +
    (S.dayView !== 'place' ? '<div class="yearbar">' + years.map(y => '<button data-act="jump-year" data-year="' + y + '">' + y + '</button>').join('') + '</div>' : '') +
    '<div class="scroll" id="days-list">' + dayListHTML() + '</div>';
}

function vLoading(msg) { return top(backBtn('days', 'Days'), 'Culling Bay') + '<div class="empty-state">' + esc(msg) + '</div>'; }

// The budget: 10 stacks an hour of shooting (from the server), counted per stack, so a whole
// panorama or bracket is one. Stacks you kept in Lightroom count too. It is soft: going over
// shows in amber, and the review lists your kept stacks to trim.
const budgetOf = () => (S.day && S.day.budget ? S.day.budget.stacks : 0);
const keptCount = () => S.stacks.filter(s => { const st = status(s); return st.done && st.v !== 'reject'; }).length;
function budgetBar() {
  const b = budgetOf();
  if (!b) return '';
  const n = keptCount(), over = n - b;
  return '<div class="budget' + (over > 0 ? ' over' : '') + '" id="budget" title="' + esc(S.day.budget.per_hour + ' stacks an hour of shooting (' + S.day.budget.hours + ' h)') + '"><span>' +
    (over > 0 ? 'Kept ' + n + ' · ' + over + ' over ' + b : 'Kept ' + n + ' of ' + b) + '</span><span class="budget-bar"><i style="width:' + Math.min(100, n / b * 100).toFixed(1) + '%"></i></span></div>';
}
const overNote = () => { const b = budgetOf(), over = keptCount() - b; return b && over > 0 ? ' · ' + over + ' over this shoot’s ' + b : ''; };

function vCull() {
  const s = S.stacks[S.cursor], f = shown(s), st = status(s), n = S.stacks.length;
  const burst = s.frames.length > 1, sugg = s.kind === 'pano' || s.kind === 'bracket';
  const lrHere = st.src !== 'lr' && lrMark(f) ? '<span class="bd bd-lr">' + esc(lrWord(f)) + '</span>' : '';
  const chip = burst ? '<button class="chip" data-act="picker" aria-label="Open burst of ' + s.frames.length + '">' + IC.stack + '<span>' + s.frames.length + '</span></button>'
    : f.partners.length ? '<span class="chip static">RAW + ' + esc(f.partners.map(p => p.split('.').pop().toUpperCase()).join(' + ')) + '</span>' : '';
  const badges = (s.kind === 'pano' ? '<span class="bd bd-dot">Looks like a panorama</span>'
    : s.kind === 'bracket' ? '<span class="bd bd-dot">Looks like a bracket</span>'
    : burst && f.id === s.lead ? '<span class="bd bd-dot">Sharpest</span>' : '') +
    f.badges.map(b => '<span class="bd">' + esc(b) + '</span>').join('') + lrHere;
  const strip = burst ? '<button class="strip" data-act="picker">' + s.frames.slice(0, 6).map(x => thumb(x, 'm-' + markOf(x))).join('') +
      (s.frames.length > 6 ? '<span class="more">+' + (s.frames.length - 6) + '</span>' : '') + '<span class="strip-l">Choose</span></button>'
    : '<div class="strip empty" aria-hidden="true"></div>';   // keeps the buttons still between cards
  // The button that made the decision shows pressed when you come back to the stack.
  const kept = s.frames.filter(x => isPick(S.dec[x.id])).length;
  const pressed = a => !st.done ? false : a === 'reject' ? st.v === 'reject' : st.v === 'reject' ? false
    : a === 'hero' ? st.v === 'hero'
    : a === 'keep-all' ? st.src !== 'lr' && kept === s.frames.length
    : st.v !== 'hero' && (st.src === 'lr' || !burst || kept < s.frames.length);
  const on = a => (pressed(a) ? ' on' : '');
  const ar = AR[f.id] || 1.5;
  const cls = 'card ' + (ar < 1 ? 'k-fill' : 'k-land') + (burst ? ' is-stack' : '') + (st.done ? ' st-' + st.v : '');
  const left = n - doneCount(), togo = left + (left === 1 ? ' stack' : ' stacks') + ' to go';
  // Under a landscape photo, the RAW at 1:1 where the camera focused (or the centre), in the
  // space an upright phone leaves; loadBand() sizes it and drops it when there's no room.
  const band = ar >= 1 ? '<div class="band" id="band"><img alt="" draggable="false"><span class="bd">1:1 at ' +
    (f.af ? 'the AF point' : 'the centre') + '</span><span class="band-load">Decoding the RAW…</span></div>' : '';
  return top(backBtn('days', 'Days'), dayTitle(S.day), S.matches ? '' : togo,
      '<div class="tools"><button class="ico" data-act="grid" aria-label="Show every photo in a grid">' + IC.grid + '</button><button class="ico" data-act="info" aria-label="Photo details">' + IC.info + '</button></div>',
      S.matches ? '<button class="mchip" data-act="matches">' + S.matches.n + ' match' + (S.matches.n === 1 ? '' : 'es') + ' first</button> · ' + left + ' to go' : '') +
    '<div class="prog"><i style="width:' + (doneCount() / n * 100).toFixed(1) + '%"></i></div>' + budgetBar() +
    '<div class="stage' + (band ? ' has-band' : '') + '" id="stage"><div class="' + cls + '"' + (ar < 1 ? '' : ' style="aspect-ratio:' + ar.toFixed(4) + '"') + '>' +
      photo(f, '<div class="tint"></div>' + afBox(f) + stLine(s, st) + '<div class="badges">' + badges + '</div>' + chip + '<div class="stamp"><span>KEEP</span></div>') + '</div>' +
      band + '<div class="fname">' + esc([f.file].concat(f.partners).join(' + ')) + ' · ' + (S.cursor + 1) + '/' + n + '</div>' +
      // turned sideways the top bar goes; these stand in for it (app.css)
      '<button class="ov ov-back" data-act="days">' + IC.back + 'Days</button><span class="ov ov-left">' + esc(togo) + (budgetOf() ? ' · kept ' + keptCount() + ' of ' + budgetOf() : '') + '</span></div>' +
    (burst || !band ? strip : '') + '<div class="rcol">' + (burst ? '' : starRow(st.done && st.v !== 'reject' ? (frameMark(f) || {}).stars || 0 : 0)) +
    '<div class="bar"><button class="pb pb-rej' + on('reject') + '" data-act="reject">' + IC.x + '<span>Reject</span></button>' +
      '<button class="pb pb-undo" data-act="undo"' + (S.hist.length ? '' : ' disabled') + '>' + IC.undo + '<span>Undo</span></button>' +
      (burst ? '<button class="pb pb-all' + (sugg && !st.done ? ' sugg' : '') + on('keep-all') + '" data-act="keep-all">' + IC.stack + '<span>Keep all ' + s.frames.length + '</span></button>' : '') +
      (burst ? '<button class="pb pb-keep' + on('keep') + '" data-act="choose">' + IC.stack + '<span>Choose</span></button></div>'
        : '<button class="pb pb-keep' + on('keep') + on('hero') + '" data-act="keep">' + IC.check + '<span>Keep</span></button></div>') + '</div>' +
    (hintDays().length < HINT_DAYS ? '<div class="hint">Swipe ↑ ' + (burst ? 'open' : 'keep') + ' · ↓ reject · ← → browse · tap: full screen · double-tap: focus</div>' : '');
}

function vStrip() {
  const s = S.stacks[S.cursor], fr = s.frames, pk = S.picker, f = fr[pk.view], on = pk.sel.has(f.id);
  const n = pk.sel.size, m = frameMark(f);
  const lrBadge = lrMark(f) && !(m && m.text.endsWith('in Lightroom')) ? '<span class="bd bd-lr">' + esc(lrWord(f)) + '</span>' : '';
  // Linked 1:1: every frame shows the RAW at the same spot, the lead frame's AF point, so a swipe
  // flips frames with the crop held still (loadLinked fills it in).
  const main = pk.linked && pk.box ? '<div class="pk-box lk"><img alt="" draggable="false">' +
      '<span class="lk-load">Decoding the RAW…</span></div><span class="bd pk-cap">1:1 · the same spot on every frame</span>'
    : '<div class="pk-box">' + photo(f, afBox(f)) + '</div>';
  return top('<button class="tbtn" data-act="close-picker">Cancel</button>', 'Burst of ' + fr.length, 'Tick the keepers',
      '<div class="tools"><button class="pk-11' + (pk.linked ? ' on' : '') + '" data-act="linked" aria-pressed="' + !!pk.linked + '" aria-label="Compare at 1:1">1:1</button></div>') +
    '<div class="pk-main' + (pk.linked ? ' is-linked' : '') + '" id="pk-main">' + main +
      '<div class="pk-bd">' + (f.id === s.lead ? '<span class="bd bd-dot">Sharpest</span>' : '') + f.badges.map(b => '<span class="bd">' + esc(b) + '</span>').join('') + lrBadge + '</div>' +
      (m ? '<span class="pk-flag ' + m.v + '">' + esc(m.text) + (m.stars ? ' ' + starText(m.stars) : '') + '</span>' : '') +
      '<button class="pk-tick' + (on ? ' on' : '') + '" data-act="tick" aria-pressed="' + on + '" aria-label="Keep ' + esc(f.file) + '">' + IC.check + '</button>' +
      '<span class="pk-id">' + esc(stem(f.file)) + ' · ' + (pk.view + 1) + '/' + fr.length + '</span></div>' +
    '<div class="pk-strip">' + fr.map((x, i) => '<button class="pk-th' + (i === pk.view ? ' cur' : '') + '" data-act="view" data-i="' + i + '" aria-label="Show ' + esc(x.file) + '">' +
      thumb(x) + (x.id === s.lead ? '<i class="dot"></i>' : '') + (pk.sel.has(x.id) ? '<b>' + IC.check + '</b>' : '') + '</button>').join('') + '</div>' +
    starRow(pk.rate[f.id] || (isPick(S.dec[f.id]) && S.dec[f.id].stars) || 0, 'Rate this frame') +
    '<p class="pk-note">A dot marks the sharpest frame. Swipe to look, 1:1 to compare the same spot, ✓ or a star to keep.</p>' +
    '<div class="foot"><button class="pb2" data-act="pk-reject">Reject all ' + fr.length + '</button>' +
      '<button class="pb2 pri" data-act="pk-keep"' + (n ? '' : ' disabled') + '>' + (n ? 'Keep ' + n + ' · reject ' + (fr.length - n) : 'Tick a keeper') + '</button></div>';
}

// Bursts of more than six: every frame at once, tap the weak ones out, keep what is left (like
// Lightroom's Survey view). A double-tap checks a frame's focus instead.
function vKnock() {
  const s = S.stacks[S.cursor], fr = s.frames, pk = S.picker, left = fr.length - pk.out.size;
  return top('<button class="tbtn" data-act="close-picker">Cancel</button>', 'Burst of ' + fr.length, left + ' left · tap the weaker frames out') +
    '<div class="ko">' + fr.map((f, i) => '<button class="ko-t' + (pk.out.has(f.id) ? ' out' : '') + '" style="aspect-ratio:' + (AR[f.id] || 1.5).toFixed(4) +
      '" data-act="ko" data-i="' + i + '" aria-pressed="' + pk.out.has(f.id) + '" aria-label="' + esc(f.file) + (pk.out.has(f.id) ? ', out' : '') + '">' +
      thumb(f) + (f.id === s.lead ? '<i class="dot"></i>' : '') + '<b>' + IC.x + '</b></button>').join('') + '</div>' +
    '<p class="pk-note">The dot marks the sharpest. Tap again to bring a frame back; double-tap to check its focus.</p>' +
    '<div class="foot"><button class="pb2" data-act="pk-reject">Reject all ' + fr.length + '</button>' +
      '<button class="pb2 pri" data-act="ko-keep"' + (left ? '' : ' disabled') + '>Keep the ' + left + ' left</button></div>';
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
  const f = frameById(S.focus.id), fromCard = S.focus.ret === 'cull', m = frameMark(f);
  const atAF = f.af && Math.abs(f.af[0] - S.focus.u) < 1e-3 && Math.abs(f.af[1] - S.focus.v) < 1e-3;
  return top(backBtn('close-focus', 'Back'), 'Focus · ' + stem(f.file), (atAF ? 'At the camera’s AF point' : '1:1 from the RAW') + ' · drag to look around') +
    (m ? '<div class="fz-st ' + m.v + '">' + (m.v === 'reject' ? '✕ ' : '✓ ') + esc(m.text) + (m.stars ? ' ' + starText(m.stars) : '') + '</div>' : '') +
    '<div class="fz" id="fz"><img alt="" draggable="false"><div class="fz-load">Decoding the RAW…</div></div>' +
    '<div class="fz-cap">Double-tap the photo to go back.</div>' +
    (fromCard ? '<div class="foot"><button class="pb2' + (m && m.v === 'reject' ? ' on-rej' : '') + '" data-act="reject">Reject</button>' +
      '<button class="pb2 pri' + (m && m.v !== 'reject' ? ' on-keep' : '') + '" data-act="keep">Keep</button></div>' : '');
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

// The day grid: every photo, with what it ends up as -- the phone's decision, or your
// Lightroom flag where there is none or where yours won. Picks outlined, rejects greyed.
function finalMark(f) {
  const d = S.dec[f.id];
  if (d && d.state !== 'conflict' && d.flag !== 'none') return d.flag === 'reject' ? 'reject' : d.stars === 5 ? 'hero' : 'pick';
  if (f.lr && f.lr.pick) return f.lr.pick === 1 ? 'pick' : 'reject';
  return 'none';
}
const GRID_FILTERS = { all: 'All', picks: 'Picks', rejects: 'Rejects', none: 'Unflagged' };
function vGrid() {
  const all = S.stacks.flatMap((s, si) => s.frames.map((f, fi) => ({ f, s, si, fi, m: finalMark(f) })));
  const n = { pick: 0, reject: 0, none: 0 };
  for (const x of all) n[x.m === 'hero' ? 'pick' : x.m]++;
  const keep = x => S.gridFilter === 'all' || (S.gridFilter === 'picks' ? (x.m === 'pick' || x.m === 'hero') : S.gridFilter === 'rejects' ? x.m === 'reject' : x.m === 'none');
  const tile = x => {
    const stars = (x.f.lr && x.f.lr.rating) || (S.dec[x.f.id] && S.dec[x.f.id].stars) || 0;
    return '<button class="gv-t m-' + x.m + '" data-act="grid-open" data-stack="' + x.si + '" aria-label="' + esc(x.f.file + ', ' + ({ pick: 'picked', hero: 'hero', reject: 'rejected', none: 'unflagged' })[x.m]) + '">' +
      thumb(x.f) +
      (x.s.frames.length > 1 ? '<span class="gv-n">' + (x.fi + 1) + '/' + x.s.frames.length + '</span>' : '') +
      (stars ? '<span class="gv-s">' + '★'.repeat(stars) + '</span>' : '') +
      (x.m === 'pick' || x.m === 'hero' ? '<b>' + (x.m === 'hero' ? IC.star : IC.check) + '</b>' : '') + '</button>';
  };
  const shown = all.filter(keep);
  return top(backBtn('grid', S.gridFrom === 'summary' ? 'Review' : 'Cards'), dayTitle(S.day),
      n.pick + ' picked · ' + n.reject + ' rejected · ' + n.none + ' unflagged',
      '<div class="tools"><button class="ico on" data-act="grid" aria-label="Back to the cards">' + IC.grid + '</button></div>') +
    '<div class="dtools gv-tools"><div class="seg" role="tablist">' + Object.entries(GRID_FILTERS).map(([k, label]) =>
      '<button data-act="grid-filter" data-f="' + k + '" aria-selected="' + (S.gridFilter === k) + '">' + label + '</button>').join('') + '</div></div>' +
    '<div class="scroll"><div class="gv-grid">' + shown.map(tile).join('') + '</div>' +
    (shown.length ? '' : '<p class="note">Nothing here.</p>') +
    '<p class="note">The phone’s decisions, or your Lightroom flags from the last sync where the phone has none. Tap a photo to open its card.</p>' +
    '<p class="note"><button class="link" data-act="reset-ask">Start this day over</button></p></div>';
}

function vSummary() {
  let keep = 0, hero = 0, rej = 0, none = 0;
  const all = S.stacks.flatMap(s => s.frames);
  const inLr = new Set(S.stacks.filter(s => status(s).src === 'lr').flatMap(s => s.frames.map(f => f.id)));
  for (const f of all) {
    const d = S.dec[f.id];
    if (!d || d.flag === 'none') { if (!inLr.has(f.id)) none++; }
    else if (d.flag === 'reject') rej++;
    else if (d.stars === 5) hero++;
    else keep++;
  }
  const rejects = all.filter(f => S.dec[f.id] && S.dec[f.id].flag === 'reject' && S.dec[f.id].state !== 'conflict');
  const won = all.filter(f => S.dec[f.id] && S.dec[f.id].state === 'conflict');
  const wonGrid = '<div class="sm-grid">' + won.map(f => '<div class="sm-th won" title="' + esc(f.file) + '"><img src="' + img(f.id, 'thumb') + '" alt="" loading="lazy">' +
    '<span class="sm-lab">' + esc(lrShort(f)) + '</span></div>').join('') + '</div>';
  const skipped = lrDone();
  const fromBurst = rejects.filter(f => S.dec[f.id].note), outright = rejects.filter(f => !S.dec[f.id].note);
  const order = fromBurst.concat(outright).map(f => f.id);   // the large view steps through them in this order
  const grid = list => '<div class="sm-grid">' + list.map(f => '<button class="sm-th" data-act="look" data-id="' + f.id + '" data-order="' + order.join(',') + '" aria-label="Look at ' + esc(f.file) + '">' +
    thumb(f) + '<b>' + IC.x + '</b></button>').join('') + '</div>';
  const open = firstOpen(0);
  const decided = all.map(f => S.dec[f.id]).filter(Boolean);
  const by = st => decided.filter(d => d.state === st).length;
  const unsent = by('draft') + by('missing'), queued = by('queued'), landed = by('landed'), conflicts = by('conflict');
  const lr = [];
  if (landed) lr.push(landed + ' in Lightroom');
  if (queued) lr.push(queued + ' waiting for the next Sync AI Cull Data');
  if (by('missing')) lr.push(by('missing') + ' not found in the last sync, will go again');
  if (skipped) lr.push(skipped + ' stack' + (skipped > 1 ? 's were' : ' was') + ' already flagged or rated in Lightroom and skipped');
  const b = budgetOf(), keptN = keptCount(), over = b ? keptN - b : 0;
  const mine = S.stacks.filter(s => { const st = status(s); return st.done && st.v !== 'reject' && st.src !== 'lr'; });
  const trim = over > 0 ? '<p class="sec">Kept · ' + keptN + ' of ' + b + '</p><div class="sm-grid">' + mine.map(s => '<button class="sm-th kept" data-act="drop" data-stack="' + S.stacks.indexOf(s) +
      '" aria-label="Drop ' + esc(stem(shown(s).file)) + '"><img src="' + img(shown(s).id, 'thumb') + '" alt="" loading="lazy"><b>' + IC.x + '</b>' +
      (s.frames.length > 1 ? '<span class="sm-lab">' + s.frames.filter(f => isPick(S.dec[f.id])).length + ' of ' + s.frames.length + '</span>' : '') + '</button>').join('') +
      '</div><p class="note">' + over + ' over this shoot’s budget of ' + b + ' (' + S.day.budget.per_hour + ' stacks an hour of shooting). Tap a stack to drop it.</p>'
    : b ? '<p class="note">Kept ' + keptN + ' of this shoot’s budget of ' + b + '.</p>' : '';
  const sendLabel = unsent ? 'Send ' + unsent + ' to Lightroom' : queued ? 'Waiting for Lightroom' : landed ? 'In Lightroom' : 'Send to Lightroom';
  return top(backBtn('back-cull', 'Cards'), dayTitle(S.day), open < 0 ? 'Day finished' : 'Rejects so far',
      '<div class="tools"><button class="ico" data-act="grid" aria-label="Show every photo in a grid">' + IC.grid + '</button></div>') +
    '<div class="scroll">' + (S.day.summary ? '<p class="dsum-top">' + S.day.summary.split('\n').map(esc).join('<br>') + '</p>' : '') +
      '<div class="counts"><div><b>' + keep + '</b><span>Kept</span></div><div><b>' + hero + '</b><span>Hero</span></div>' +
      '<div><b>' + rej + '</b><span>Rejected</span></div><div><b>' + none + '</b><span>Unflagged</span></div></div>' + trim +
      (lr.length ? '<p class="sec">Lightroom</p>' + lr.map(t => '<p class="note">' + esc(t) + '</p>').join('') : '') +
      (won.length ? '<p class="sec">Your Lightroom flag won</p>' + wonGrid +
        '<p class="note">The phone said otherwise, but you had flagged ' + (won.length > 1 ? 'these' : 'this') + ' in Lightroom yourself, so Lightroom kept your flag. Change it there if the phone was right.</p>' : '') +
      (rejects.length ? (fromBurst.length ? '<p class="sec">From bursts · similar frame kept</p>' + grid(fromBurst) : '') +
        (outright.length ? '<p class="sec">Rejected outright</p>' + grid(outright) : '') + '<p class="note">Tap a frame to look at it large and rescue it.</p>'
        : '<p class="note">No rejects today.</p>') +
      '<p class="note"><button class="link" data-act="reset-ask">Start this day over</button></p></div>' +
    '<div class="foot"><button class="pb2" data-act="days">Back to days</button><button class="pb2 pri" data-act="send"' + (unsent ? '' : ' disabled') + '>' + sendLabel + '</button></div>';
}

// A reject, large, from the review: swipe through the day's rejects, rescue the ones that deserve
// it, double-tap to check focus. Rescued frames stay in the run with a ✓ until you go back.
function vLarge() {
  const L = S.large, f = frameById(L.ids[L.i]), d = S.dec[f.id], rejected = !!d && d.flag === 'reject';
  return top(backBtn('close-large', 'Review'), stem(f.file), (L.i + 1) + ' of ' + L.ids.length + ' · swipe for the next') +
    '<div class="lg" id="lg"><div class="pk-box">' + photo(f, afBox(f)) + '</div>' +
      '<span class="pk-flag ' + (rejected ? 'reject">Rejected' : 'keep">Rescued ✓') + '</span>' +
      (rejected && d.note ? '<span class="lg-note">' + esc(d.note.replace(NOTE_PREFIX, 'Similar frame kept: ')) + '</span>' : '') + '</div>' +
    '<div class="foot"><button class="pb2" data-act="close-large">Back</button>' +
      '<button class="pb2 pri" data-act="rescue" data-id="' + f.id + '"' + (rejected ? '' : ' disabled') + '>' + (rejected ? 'Rescue' : 'Rescued ✓') + '</button></div>';
}
function largeStep(d) {
  const L = S.large;
  L.i = Math.max(0, Math.min(L.ids.length - 1, L.i + d));
  draw();
}
function bindLarge() {
  const m = $('#lg', view);
  if (!m) return;
  let sx = null, lastAt = 0;
  m.addEventListener('pointerdown', e => { sx = e.clientX; });
  m.addEventListener('pointerup', e => {
    if (sx === null) return;
    const d = e.clientX - sx; sx = null;
    if (Math.abs(d) > 50) return largeStep(d < 0 ? 1 : -1);
    const now = performance.now();
    if (now - lastAt < 300) { lastAt = 0; const f = frameById(S.large.ids[S.large.i]), sp = spotOf(f); return openFocus(f.id, sp[0], sp[1]); }
    lastAt = now;
  });
}

function draw(anim) {
  const perfT = performance.now();
  if (S.screen === 'picker' && !S.picker) S.screen = 'cull';
  if ((S.screen === 'cull' || S.screen === 'picker') && !S.stacks[S.cursor]) S.screen = 'summary';
  const scr = S.screen;
  view.innerHTML = scr === 'days' ? vDays() : scr === 'loading' ? vLoading('Loading the day…')
    : scr === 'error' ? vLoading(S.error || 'Something went wrong')
    : scr === 'picker' ? (S.picker.m === 'strip' ? vStrip() : vKnock())
    : scr === 'summary' ? vSummary() : scr === 'focus' ? vFocus() : scr === 'grid' ? vGrid() : scr === 'large' ? vLarge() : vCull();
  view.classList.toggle('no-chrome', !S.chrome);
  view.dataset.screen = scr;
  bindPhotos(view, perfT);
  if (scr === 'cull') {
    bindStage();
    const c = $('.card', view);
    if (c && anim && !reduced()) c.classList.add('enter-' + anim);
    loadBand();
    setTimeout(prefetch, 80);
  }
  if (scr === 'picker' && S.picker.m === 'strip') { bindPickerSwipe(); loadLinked(); }
  else if (scr !== 'cull') keepCrops([]);
  if (scr === 'focus') requestAnimationFrame(loadFocus);
  if (scr === 'large') bindLarge();
}
function prefetch() {
  for (let k = 1; k <= 10; k++) {
    const s = S.stacks[S.cursor + k];
    if (!s) break;
    const v = shown(s), im = new Image();
    if (!AR[v.id]) im.onload = () => noteAR(v.id, im);   // so its card is drawn the right shape
    im.src = img(v.id, 'view');
    if (k <= 3) for (const f of s.frames.slice(0, 6)) new Image().src = img(f.id, 'thumb');
  }
}
function bandUrls() {   // this card's band and the next two landscape cards', for keepCrops
  const out = [];
  for (let k = 0; k <= 2 && S.bandSize; k++) {
    const s = S.stacks[S.cursor + k];
    if (!s) break;
    const v = shown(s);
    if ((AR[v.id] || 1.5) >= 1) out.push(cropUrl(v, spotOf(v), S.bandSize));
  }
  return out;
}

/* ---------------------------------------------------------------- 1:1 crops */
// A crop is a full RAW decode on the PC, a second or more each. They go through one queue, one at
// a time, and the ones for cards you've moved past are cancelled: a browser opens only six
// connections to the PC, and saving a tap must never wait behind them.
const CROPS = { done: new Map(), queue: [], live: null };
function getCrop(url, urgent) {
  if (CROPS.done.has(url)) return Promise.resolve(CROPS.done.get(url));
  let job = (CROPS.live && CROPS.live.url === url ? CROPS.live : null) || CROPS.queue.find(j => j.url === url);
  if (!job) {
    job = { url, waiters: [] };
    if (urgent) CROPS.queue.unshift(job); else CROPS.queue.push(job);
  } else if (urgent && CROPS.queue.includes(job)) {
    CROPS.queue.splice(CROPS.queue.indexOf(job), 1); CROPS.queue.unshift(job);
  }
  const p = new Promise((res, rej) => job.waiters.push({ res, rej }));
  pumpCrops();
  return p;
}
function keepCrops(urls) {   // cancel every crop not in urls
  const keep = new Set(urls);
  for (const j of CROPS.queue.filter(j => !keep.has(j.url))) j.waiters.forEach(w => w.rej(new Error('cancelled')));
  CROPS.queue = CROPS.queue.filter(j => keep.has(j.url));
  if (CROPS.live && !keep.has(CROPS.live.url)) CROPS.live.ctrl.abort();
}
async function pumpCrops() {
  if (CROPS.live || !CROPS.queue.length) return;
  const job = CROPS.live = CROPS.queue.shift();
  job.ctrl = new AbortController();
  try {
    const r = await fetch(job.url, { signal: job.ctrl.signal });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const u = URL.createObjectURL(await r.blob());
    CROPS.done.set(job.url, u);
    while (CROPS.done.size > 24) { const [k, old] = CROPS.done.entries().next().value; URL.revokeObjectURL(old); CROPS.done.delete(k); }
    job.waiters.forEach(w => w.res(u));
  } catch (e) {
    job.waiters.forEach(w => w.rej(e));
  }
  CROPS.live = null;
  pumpCrops();
}
const spotOf = f => f.af || [0.5, 0.5];
const cropUrl = (f, spot, sz) => '/m/api/crop/' + f.id + '?x=' + spot[0].toFixed(4) + '&y=' + spot[1].toFixed(4) + '&w=' + sz.w + '&h=' + sz.h;
const afBox = f => (f.af ? '<span class="af" style="left:' + (f.af[0] * 100).toFixed(2) + '%;top:' + (f.af[1] * 100).toFixed(2) + '%"></span>' : '');
function devSize(el) {   // an element's size in device pixels: one RAW pixel each is 1:1
  const r = el.getBoundingClientRect(), dpr = Math.min(3, window.devicePixelRatio || 1);
  return { w: Math.min(2400, Math.round(r.width * dpr)), h: Math.min(2400, Math.round(r.height * dpr)) };
}
function dropBand() {
  const band = $('#band', view);
  if (band) { band.remove(); $('#stage', view).classList.remove('has-band'); }
}
function showCrop(box, url, urgent) {
  const im = $('img', box), load = $('.band-load, .lk-load', box);
  getCrop(url, urgent).then(u => {
    if (!box.isConnected) return;
    im.onload = () => { load.hidden = true; };
    im.src = u;
  }).catch(e => { if (box.isConnected && e.message !== 'cancelled' && e.name !== 'AbortError') load.textContent = 'Could not decode this frame'; });
}
function loadBand() {
  const band = $('#band', view), s = S.stacks[S.cursor];
  if (!band || !s) { keepCrops([]); return; }
  if (band.getBoundingClientRect().height < BAND_MIN) { keepCrops([]); return dropBand(); }
  const f = shown(s);
  S.bandSize = devSize(band);
  const urls = bandUrls();
  keepCrops(urls);
  showCrop(band, cropUrl(f, spotOf(f), S.bandSize), true);
  for (const u of urls.slice(1)) getCrop(u).catch(() => {});   // so the next bands are there on arrival
}
function linkedUrls() {
  const s = S.stacks[S.cursor], pk = S.picker, spot = spotOf(leadOf(s));
  const order = s.frames.slice(pk.view).concat(s.frames.slice(0, pk.view));   // nearest first
  return order.map(f => cropUrl(f, spot, pk.box));
}
function loadLinked() {
  const box = $('.pk-box.lk', view);
  if (!box) { keepCrops([]); return; }
  const urls = linkedUrls();
  keepCrops(urls);
  showCrop(box, urls[0], true);
  for (const u of urls.slice(1)) getCrop(u).catch(() => {});
}
function toggleLinked() {
  const pk = S.picker;
  pk.linked = !pk.linked;
  if (pk.linked) pk.box = devSize($('#pk-main', view));
  draw();
}

/* ---------------------------------------------------------------- gestures */
function setStamp(card, a, k) {
  const st = $('.stamp', card), tint = $('.tint', card);
  if (!st) return;
  st.dataset.a = a;
  st.firstChild.textContent = a === 'reject' ? 'REJECT' : a === 'hero' ? 'HERO' : a === 'all' ? 'KEEP ALL' : a === 'open' ? 'CHOOSE' : 'KEEP';
  st.style.opacity = k;
  tint.style.background = a === 'reject' ? 'var(--reject)' : 'var(--keep)';
  tint.style.opacity = k * .25;
}
function flyOut(a, stars) {
  if (S.busy) return;
  const card = $('.card', view);
  if (S.screen !== 'cull' || !card || reduced()) return decide(a, stars);
  S.busy = true;
  setStamp(card, a, 1);
  card.style.transition = 'transform .1s ease-in, opacity .1s ease-in';
  card.style.transform = 'translateY(' + (a === 'reject' ? 115 : -115) + '%)';
  card.style.opacity = '0';
  setTimeout(() => { S.busy = false; decide(a, stars); }, 100);
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
  if (now - lastTap < 300) {            // double-tap: 1:1 from the RAW where the camera focused, else there
    clearTimeout(tapT); lastTap = 0;
    const el = $('.card img', view), s = S.stacks[S.cursor];
    if (el && s) {
      const f = shown(s), p = f.af ? { u: f.af[0], v: f.af[1] } : imagePoint(el, x, y);
      openFocus(f.id, p.u, p.v);
    }
    return;
  }
  lastTap = now;
  tapT = setTimeout(() => {
    S.chrome = !S.chrome;
    view.classList.toggle('no-chrome', !S.chrome);
    for (const p of view.querySelectorAll('.photo')) fitPhoto(p);
    if (S.chrome) loadBand();
  }, 300);
}
function bindStage() {
  const stage = $('#stage', view), card = $('.card', view);
  if (!stage || !card) return;
  let st = null;
  const reset = () => { card.style.transition = 'transform .12s cubic-bezier(.2,.8,.2,1)'; card.style.transform = ''; setStamp(card, 'keep', 0); };
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
      setStamp(card, dy >= 0 ? 'reject' : isBurst() ? 'open' : 'keep', Math.min(1, Math.abs(dy) / THRESH));
    } else {
      st.d = dx; st.kind = 'browse';
      card.style.transform = 'translateX(' + dx * .7 + 'px)';
    }
  });
  stage.addEventListener('pointerup', () => {
    if (!st) return;
    const s = st; st = null;
    if (!s.axis) { reset(); return tap(s.x, s.y); }
    if (s.kind === 'decide' && s.d <= -THRESH && isBurst()) { reset(); return openPicker(true); }
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
      const el = $('.photo img', m), f = S.stacks[S.cursor].frames[S.picker.view];
      if (S.picker.linked) { const sp = spotOf(leadOf(S.stacks[S.cursor])); openFocus(f.id, sp[0], sp[1]); }
      else if (el) { const p = f.af ? { u: f.af[0], v: f.af[1] } : imagePoint(el, e.clientX, e.clientY); openFocus(f.id, p.u, p.v); }
      return;
    }
    lastAt = now;
  });
}
function stripView(i) { const n = S.stacks[S.cursor].frames.length; S.picker.view = Math.max(0, Math.min(n - 1, i)); draw(); }

/* ---------------------------------------------------------------- navigation */
async function showDays() {
  S.screen = 'days'; S.day = null; S.stacks = []; S.hist = [];
  if (location.hash !== '#/') history.replaceState(null, '', '#/');
  draw();
  try { S.days = (await getJSON('/m/api/days')).days; }
  catch (e) { S.screen = 'error'; S.error = 'Could not load days: ' + e.message; }
  if (S.screen === 'days' || S.screen === 'error') draw();
}
async function openDay(day, match) {   // match: {ids, label} from a search, whose stacks go first
  S.perfDay = performance.now();
  S.screen = 'loading'; draw();
  let body;
  try { body = await getJSON('/m/api/day/' + dayPath(day)); }
  catch (e) { S.screen = 'error'; S.error = 'Could not load ' + day + ': ' + e.message; return draw(); }
  S.day = body; S.stacks = body.stacks; S.dec = {}; S.hist = []; S.picker = null; S.matches = null;
  for (const s of S.stacks) for (const f of s.frames) if (f.decision) S.dec[f.id] = f.decision;
  if (match) {
    const ids = new Set(match.ids), first = S.stacks.filter(s => s.frames.some(f => ids.has(f.id)));
    if (first.length && first.length < S.stacks.length) {
      S.stacks = first.concat(S.stacks.filter(s => !first.includes(s)));
      S.matches = { n: first.length, label: match.label };
    }
  }
  const p = body.progress;
  S.pass = 2;                       // one pass now; the server still records pass and position
  S.cursor = S.matches || !p ? 0 : Math.max(0, S.stacks.findIndex(s => s.id === p.cursor));
  const i = status(S.stacks[S.cursor]).done ? firstOpen(S.cursor) : S.cursor;
  if (i < 0) S.screen = 'summary'; else { S.cursor = i; S.screen = 'cull'; await loadShape(shown(S.stacks[i]).id, 1500); }
  const hash = '#/day/' + day;
  if (location.hash !== hash) history.replaceState(null, '', hash);
  draw();
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

// Start a day over: clears the phone's decisions for it. Allowed until any of them reach
// Lightroom; rows already queued in the inbox are taken back out.
function resetAsk() {
  const ds = Object.values(S.dec), applied = ds.filter(d => d.state === 'landed' || d.state === 'conflict').length;
  const queued = ds.filter(d => d.state === 'queued').length;
  const el = $('#sheet');
  el.innerHTML = '<div class="sheet" role="dialog" aria-label="Start this day over"><div class="sh-grab"></div>' + (applied
    ? '<p class="sh-q">Already in Lightroom</p><p class="sh-muted">' + applied + ' decision' + (applied > 1 ? 's' : '') +
      ' from this day reached Lightroom in a sync. The phone can’t take ' + (applied > 1 ? 'them' : 'it') + ' back: change ' + (applied > 1 ? 'those photos' : 'that photo') + ' in Lightroom.</p>' +
      '<div class="sh-row"><button class="pb2" data-act="close-sheet">Close</button></div>'
    : '<p class="sh-q">Start ' + esc(dayTitle(S.day)) + ' over?</p><p class="sh-muted">Clears the ' + ds.length + ' decision' + (ds.length === 1 ? '' : 's') +
      ' you made on the phone for this day' + (queued ? ', and takes the ' + queued + ' waiting for Lightroom back out of the inbox' : '') +
      '. Flags and stars you set in Lightroom aren’t touched. This can’t be undone.</p>' +
      '<div class="sh-row"><button class="pb2" data-act="close-sheet">Cancel</button><button class="pb2 danger" data-act="reset-do">Start over</button></div>') + '</div>';
  el.hidden = false;
  S.sheet = true;
}
async function resetDo(btn) {
  btn.disabled = true;
  clearTimeout(progressT);                          // a position save still pending would bring the day back
  pump();                                           // taps still in the queue must land first
  for (let i = 0; i < 40 && Q.items.length; i++) await new Promise(r => setTimeout(r, 250));
  if (Q.items.length) { btn.disabled = false; return toast('Still offline: ' + Q.items.length + ' taps waiting to save. Try again once they are in.'); }
  const day = S.day.day;
  let body;
  try {
    const r = await fetch('/m/api/day/' + dayPath(day) + '/reset', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Culling-Bay': '1' }, body: '{}' });
    body = await r.json();
    if (!r.ok) throw new Error(body.error || 'HTTP ' + r.status);
  } catch (e) { btn.disabled = false; closeSheet(); return toast('Not reset: ' + e.message); }
  closeSheet();
  await openDay(day);
  toast('Started over: cleared ' + body.cleared + (body.withdrawn ? ', took ' + body.withdrawn + ' back out of the inbox' : ''));
}

const isBurst = () => { const s = S.stacks[S.cursor]; return !!s && s.frames.length > 1; };
// A swipe up or Choose opens a burst on its first frame in shooting order: you see every frame
// before keeping one (the Sharpest was your pick in only 41% of one-pick bursts).
function openPicker(fromStart) {
  const s = S.stacks[S.cursor];
  if (!s || s.frames.length < 2) return;
  const picked = s.frames.filter(f => isPick(S.dec[f.id]));
  if (s.frames.length <= PICKER_STRIP_MAX) {
    S.picker = { m: 'strip', sel: new Set(picked.map(f => f.id)), view: fromStart ? 0 : s.frames.indexOf(shown(s)), rate: {} };
  } else {   // coming back to a decided burst, the frames you didn't keep start out
    S.picker = { m: 'knock', out: new Set(picked.length ? s.frames.filter(f => !isPick(S.dec[f.id])).map(f => f.id) : []) };
  }
  S.screen = 'picker';
  draw();
}
let koTap = { i: -1, at: 0 };
function knockTap(i) {
  const s = S.stacks[S.cursor], f = s.frames[i], out = S.picker.out, now = performance.now();
  if (koTap.i === i && now - koTap.at < 300) {   // double-tap: undo the first tap's toggle, check focus
    koTap = { i: -1, at: 0 };
    out.has(f.id) ? out.delete(f.id) : out.add(f.id);
    const sp = spotOf(f);
    return openFocus(f.id, sp[0], sp[1]);
  }
  koTap = { i, at: now };
  out.has(f.id) ? out.delete(f.id) : out.add(f.id);
  draw();
}

/* ---------------------------------------------------------------- input */
document.addEventListener('click', e => {
  const b = e.target.closest('[data-act]');
  if (!b || b.disabled) return;
  const a = b.dataset.act, s = S.stacks[S.cursor];
  switch (a) {
    case 'open-day': {
      const f = S.like ? S.like.found : S.daySearch.trim() ? S.found : null, h = f && f.days.find(x => x.day === b.dataset.day);
      return openDay(b.dataset.day, h && h.match_ids.length ? { ids: h.match_ids, label: S.like ? 'photos like ' + S.like.name : '“' + S.daySearch.trim() + '”' } : null);
    }
    case 'q-clear': e.preventDefault(); return clearSearch();
    case 'like': return showLike(+b.dataset.id, b.dataset.name);
    case 'matches': return toast(S.matches.n + ' stack' + (S.matches.n === 1 ? '' : 's') + ' matched ' + S.matches.label + ', so they come first. The rest of the day follows.');
    case 'toggle-year': {
      const y = b.dataset.year;
      S.yearsOpen.has(y) ? S.yearsOpen.delete(y) : S.yearsOpen.add(y);
      store('cbm-years-open', [...S.yearsOpen]);
      $('#days-list').innerHTML = dayListHTML();
      return;
    }
    case 'jump-year': {
      const y = b.dataset.year;
      S.yearsOpen.add(y); store('cbm-years-open', [...S.yearsOpen]);
      $('#days-list').innerHTML = dayListHTML();
      const h = $('#year-' + y); if (h) h.scrollIntoView({ block: 'start' });
      return;
    }
    case 'day-view': S.dayView = b.dataset.v; store('cbm-dayview', S.dayView); return draw();
    case 'days': return showDays();
    case 'choose': return openPicker(true);
    case 'linked': return toggleLinked();
    case 'ko': return knockTap(+b.dataset.i);
    case 'ko-keep': { const keeps = s.frames.filter(f => !S.picker.out.has(f.id)); if (keeps.length) keepFrames(s, keeps, null, 'burst'); return; }
    case 'star': {
      const n = +b.dataset.n;
      if (S.screen === 'picker') { const f = s.frames[S.picker.view]; S.picker.rate[f.id] = n; S.picker.sel.add(f.id); return draw(); }
      return flyOut('keep', n);
    }
    case 'keep': case 'reject':
      if (S.screen === 'focus') { S.focus = null; S.screen = 'cull'; return decide(a); }
      return flyOut(a);
    case 'keep-all': return flyOut('all');
    case 'undo': return undo();
    case 'info': return openSheet();
    case 'close-sheet': return closeSheet();
    case 'close-focus': return closeFocus();
    case 'grid':                       // the toggle: into the grid, and back to where you were
      if (S.screen === 'grid') { S.screen = S.gridFrom || 'cull'; S.gridFrom = null; }
      else { S.gridFrom = S.screen; S.screen = 'grid'; }
      return draw();
    case 'grid-filter': S.gridFilter = b.dataset.f; return draw();
    case 'grid-open': S.cursor = +b.dataset.stack; S.gridFrom = null; S.screen = 'cull'; return draw();
    case 'reset-ask': return resetAsk();
    case 'reset-do': return resetDo(b);
    case 'picker': return openPicker();
    case 'close-picker': S.picker = null; S.screen = 'cull'; return draw();
    case 'view': return stripView(+b.dataset.i);
    case 'tick': { const f = s.frames[S.picker.view]; S.picker.sel.has(f.id) ? S.picker.sel.delete(f.id) : S.picker.sel.add(f.id); return draw(); }
    case 'pk-keep': { const keeps = s.frames.filter(f => S.picker.sel.has(f.id)); if (keeps.length) keepFrames(s, keeps, S.picker.rate, 'burst'); return; }
    case 'pk-reject': return decide('reject');
    case 'drop': {
      const st = S.stacks[+b.dataset.stack], name = stem(shown(st).file);
      act('Dropped ' + name, st.frames.map(f => ({ id: f.id, flag: 'reject', note: '', via: 'card' })), { screen: 'summary' });
      toast('Dropped ' + name + ' · kept ' + keptCount() + ' of ' + budgetOf(), true);
      return draw();
    }
    case 'back-cull': { const i = firstOpen(S.cursor); if (i >= 0) S.cursor = i; S.screen = 'cull'; return draw(); }
    case 'look': S.large = { ids: b.dataset.order.split(',').map(Number), i: 0 }; S.large.i = S.large.ids.indexOf(+b.dataset.id); S.screen = 'large'; return draw();
    case 'close-large': S.large = null; S.screen = 'summary'; return draw();
    case 'rescue': {
      const f = frameById(+b.dataset.id);
      const change = [{ id: f.id, flag: 'pick', note: '', via: 'rescue' }];
      act('Rescued ' + stem(f.file), change, { screen: 'summary' });
      toast('Rescued ' + stem(f.file) + clashNote(lrClashes(change), 0), true);
      return draw();
    }
    case 'send': return sendDay(b);
  }
});
document.addEventListener('input', e => {
  if (e.target.id !== 'day-search') return;
  S.daySearch = e.target.value;
  S.like = null;
  runSearch();
});
document.addEventListener('keydown', e => {
  if (e.target.matches('input, textarea')) return;
  const k = e.key;
  if (k === 'Escape') { if (S.sheet) closeSheet(); else if (S.screen === 'focus') closeFocus(); else if (S.screen === 'picker') { S.picker = null; S.screen = 'cull'; draw(); }
    else if (S.screen === 'large') { S.large = null; S.screen = 'summary'; draw(); } return; }
  if (S.screen === 'large' && (k === 'ArrowLeft' || k === 'ArrowRight')) { e.preventDefault(); return largeStep(k === 'ArrowRight' ? 1 : -1); }
  if (S.sheet) return;
  if (k === 'z' || k === 'Z' || k === 'Backspace') { e.preventDefault(); return undo(); }
  if (S.screen === 'picker' && S.picker.m === 'strip') { if (k === 'ArrowLeft' || k === 'ArrowRight') { e.preventDefault(); stripView(S.picker.view + (k === 'ArrowRight' ? 1 : -1)); } return; }
  if (S.screen !== 'cull') return;
  const s = S.stacks[S.cursor], burst = s && s.frames.length > 1;
  if (k === 'ArrowUp' || k === 'k') { e.preventDefault(); burst ? openPicker(true) : flyOut('keep'); }
  else if (k === 'ArrowDown' || k === 'x') { e.preventDefault(); flyOut('reject'); }
  else if (k === 'ArrowRight') { e.preventDefault(); go(1); }
  else if (k === 'ArrowLeft') { e.preventDefault(); go(-1); }
  else if (k === 'a' && burst) flyOut('all');
  else if (k >= '1' && k <= '5' && !burst) flyOut('keep', +k);   // stars, as in Lightroom
  else if (k === 'b' || k === 'Enter') openPicker();
  else if (k === 'i') openSheet();
  else if (k === 'f') { const sp = spotOf(shown(s)); openFocus(shown(s).id, sp[0], sp[1]); }
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
