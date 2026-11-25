/* Culling Bay on a computer: cull a day from the NAS beside Lightroom. (On the iPhone it is the
   native app; desktop.js gives a phone a page pointing there.)
   Plain JavaScript, no build step. Talks to /m/api (review/mobile.py); every tap is saved on the
   PC at once, through a retry queue that survives a dropped connection or a reload.
   One pass per day: days -> cards (details rail, burst picker, focus check) -> rejects review,
   with a soft budget of 10 kept stacks an hour of shooting. */
(() => {
'use strict';
if (window.cbPhone) return;   // a phone gets desktop.js's page pointing to the app

const $ = (s, el = document) => el.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const stem = f => f.replace(/\.[^.]+$/, '');
const view = $('#view');
let lastInputKey = false;   // after a mouse click focus stays off the controls, so Enter can save a burst
addEventListener('keydown', () => { lastInputKey = true; }, true);
addEventListener('pointerdown', () => { lastInputKey = false; }, true);
const NOTE_PREFIX = 'Burst reject · kept ';
const BAND_MIN = 80;        // px: a 1:1 band shorter than this isn't worth showing

const IC = {
  x: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/></svg>',
  check: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  undo: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 14L4 9l5-5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
  star: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.8l-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z" fill="currentColor"/></svg>',
  back: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  stack: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="4" width="13" height="11" rx="2" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M4 8v10a2 2 0 0 0 2 2h10" fill="none" stroke="currentColor" stroke-width="1.9"/></svg>',
  grid: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="4" width="7" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.9"/><rect x="13" y="4" width="7" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.9"/><rect x="4" y="13" width="7" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.9"/><rect x="13" y="13" width="7" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.9"/></svg>',
};

const S = {
  screen: 'days', days: null, day: null, stacks: [], dec: {},
  pass: 2, cursor: 0, hist: [], picker: null,
  sheet: false, focus: null, gridFrom: null, gridFilter: 'all',
};

/* ---------------------------------------------------------------- server */
const img = (id, size) => '/m/api/img/' + id + '?s=' + size;
const dayPath = day => day.split('/').map(encodeURIComponent).join('/');
function newId() {
  const b = new Uint8Array(12);
  crypto.getRandomValues(b);                  // randomUUID needs HTTPS; this works over plain http
  return Date.now().toString(36) + '-' + Array.from(b, x => x.toString(16).padStart(2, '0')).join('');
}
const store = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} };
const recall = (k, d) => { try { const v = JSON.parse(localStorage.getItem(k)); return v === null ? d : v; } catch (_) { return d; } };
const sleep = ms => new Promise(res => setTimeout(res, ms));
const WRITE_TIMEOUT = 15000;   // a PC that doesn't answer (asleep, in Windows) is Offline after this
const READ_TIMEOUT = 30000;
async function timed(url, opts, ms) {   // fetch, aborted after ms; null when nothing came back
  const ctrl = new AbortController(), t = setTimeout(() => ctrl.abort(), ms);
  try { return await fetch(url, Object.assign({ signal: ctrl.signal }, opts)); }
  catch (_) { return null; }
  finally { clearTimeout(t); }
}
const errorOf = async r => (await r.json().catch(() => ({}))).error || 'HTTP ' + r.status;
async function getJSON(url) {   // a read; no-cache revalidates, so the server's ETag can answer 304
  const r = await timed(url, { cache: 'no-cache' }, READ_TIMEOUT);
  if (!r) throw new Error('no answer from the PC');
  if (!r.ok) throw new Error(await errorOf(r));
  return r.json();
}
// One write, with the header the server asks for; null when the PC didn't answer.
const write = (method, url, body) => timed(url, { method, headers: { 'Content-Type': 'application/json', 'X-Culling-Bay': '1' },
  body: JSON.stringify(body) }, WRITE_TIMEOUT);

/* ---------------------------------------------------------------- the write queue
   Every tap goes through one queue in localStorage (cbm-queue), shared by all the app's tabs and
   sent strictly in order, so a decide followed by its undo can never arrive the other way round.
   Each item has an id, and every change re-reads the key, changes it and writes it back, so two
   tabs never wipe each other's taps. Only one tab sends at a time: navigator.locks where the
   browser has it (https or localhost), else a lease key the sending tab keeps renewing.
   - no answer in 15 s, or no connection: "Offline", tried again every 4 s;
   - 5xx: "PC refused: <its reason>", tried again every 4 s;
   - 409 on an undo: the tap is still in force (it reached Lightroom), so it goes back on the card
     and in Undo: "Not undone: <reason>" (the iPhone's queueDropped);
   - another 4xx on a decide: the request itself is wrong and is dropped; the card goes back to
     what it was, and "N taps not saved" stays up with the reason until dismissed;
   - another 4xx: dropped, with a toast.
   Sending again is safe: decide is idempotent by action_id, undo and progress by nature. Only
   the newest queued position per day is kept, and the banner counts taps, not positions. */
const QKEY = 'cbm-queue', LEASE = 'cbm-queue-lease', LOST = 'cbm-lost', DROP = 'cbm-drop';
const LEASE_MS = WRITE_TIMEOUT + 5000;
const TAB = newId();
const Q = { busy: false, state: 'ok', reason: '', retryT: 0 };   // state: ok, offline or refused
const kindOf = url => (/\/decide$/.test(url) ? 'decide' : /\/undo$/.test(url) ? 'undo' : /\/progress$/.test(url) ? 'progress' : 'other');
const dayOfUrl = url => { const m = url.match(/\/day\/(.+)\/progress$/); try { return m ? decodeURIComponent(m[1]) : null; } catch (_) { return null; } };
function qRead() {
  let items = recall(QKEY, []);
  if (!Array.isArray(items)) items = [];
  items = items.filter(it => it && typeof it.url === 'string');
  if (items.some(it => !it.id)) {   // saved by an older version: give each an id, once
    items = items.map(it => (it.id ? it : Object.assign({ id: newId(), kind: kindOf(it.url), day: it.body && it.body.day || dayOfUrl(it.url) }, it)));
    store(QKEY, items);
  }
  return items;
}
function qChange(fn) { const items = fn(qRead()); store(QKEY, items); return items; }
const tapsIn = items => items.filter(it => it.kind === 'decide' || it.kind === 'undo').length;
function send(method, url, body, day) {
  const it = { id: newId(), kind: kindOf(url), method, url, body, day };
  qChange(items => (it.kind === 'progress'   // the first item may be on its way: leave it
    ? items.filter((x, i) => i === 0 || x.kind !== 'progress' || x.day !== day) : items).concat(it));
  showNet();
  pump();
}
async function withQueueLock(fn) {   // false when another tab is sending
  if (navigator.locks) return navigator.locks.request('cbm-queue', { ifAvailable: true }, lock => (lock ? fn() : false));
  const held = () => recall(LEASE, null), now = Date.now(), l = held();
  if (l && l.tab !== TAB && l.until > now) return false;
  store(LEASE, { tab: TAB, until: now + LEASE_MS });
  await sleep(40);                      // two tabs taking it at once: the last write wins
  if ((held() || {}).tab !== TAB) return false;
  try { return await fn(); } finally { if ((held() || {}).tab === TAB) localStorage.removeItem(LEASE); }
}
const renewLease = () => { if (!navigator.locks) store(LEASE, { tab: TAB, until: Date.now() + LEASE_MS }); };
// A tab closed or reloaded while sending leaves no lease behind for the others to wait out.
addEventListener('pagehide', () => { if ((recall(LEASE, null) || {}).tab === TAB) localStorage.removeItem(LEASE); });
async function pump() {
  if (Q.busy) return;
  Q.busy = true;
  clearTimeout(Q.retryT);
  let sent;
  try { sent = await withQueueLock(sendQueued); } finally { Q.busy = false; }
  if (sent === false && qRead().length) Q.retryT = setTimeout(pump, 1000);   // another tab is on it
}
async function sendQueued() {
  for (;;) {
    const it = qRead()[0];
    if (!it) { setNet('ok'); return true; }
    renewLease();
    const r = await write(it.method, it.url, it.body);
    if (!r || r.status >= 500) {
      setNet(r ? 'refused' : 'offline', r ? await errorOf(r) : '');
      Q.retryT = setTimeout(pump, 4000);
      return true;
    }
    const err = r.ok ? null : await errorOf(r);
    // a decide the PC refused takes its queued undo with it (that would only be refused too)
    qChange(items => items.filter(x => x.id !== it.id &&
      !(err && it.kind === 'decide' && x.kind === 'undo' && x.body.action_id === it.body.action_id)));
    if (err) dropped(it, r.status, err);
    setNet('ok');
  }
}
function setNet(state, reason) {
  if (Q.state === state && (Q.reason || '') === (reason || '')) return showNet();
  Q.state = state; Q.reason = reason || '';
  showNet();
}
// The banners: Offline or PC refused (with the taps still waiting), and taps the PC refused.
function netInner() {
  const n = tapsIn(qRead()), lost = recall(LOST, null);
  const wait = n ? ' · ' + n + ' waiting to save' : '';
  return (Q.state === 'offline' ? '<p>Offline' + wait + '</p>' : Q.state === 'refused' ? '<p>PC refused: ' + esc(Q.reason) + wait + '</p>' : '') +
    (lost && lost.n ? '<p class="lost">' + lost.n + (lost.n === 1 ? ' tap' : ' taps') + ' not saved: ' + esc(lost.reason) +
      '. Look at ' + (lost.n === 1 ? 'that stack' : 'those stacks') + ' again. <button class="link" data-act="lost-ok">Dismiss</button></p>' : '');
}
const netDiv = () => { const h = netInner(); return '<div class="net" id="net"' + (h ? '' : ' hidden') + '>' + h + '</div>'; };
function showNet() {
  const el = $('#net', view);
  if (!el) return;
  const h = netInner();
  el.innerHTML = h; el.hidden = !h;
}
// A write the PC refused for good. The tab that sent it tells the others (the storage event), so
// the tab where the tap was made puts its card back.
function dropped(it, status, err) {
  if (it.kind === 'decide') { const l = recall(LOST, null); store(LOST, { n: ((l && l.n) || 0) + 1, reason: err }); }
  const d = { it, status, err, at: Date.now() + Math.random() };
  store(DROP, d);
  onDrop(d, true);
}
function onDrop(d, here) {
  const { it, status, err } = d;
  if (it.kind === 'undo' && status === 409) { if (!undoRefused(it.body.action_id, err) && here) toast('Not undone: ' + err); }
  else if (it.kind === 'decide') { decideRefused(it.body.action_id); showNet(); }
  else if (here) toast('Not saved: ' + err);
}
addEventListener('storage', e => {
  if (e.key === QKEY) { showNet(); if (!Q.busy && qRead().length) pump(); }
  else if (e.key === LOST) showNet();
  else if (e.key === DROP && e.newValue) { try { onDrop(JSON.parse(e.newValue), false); } catch (_) {} }
});
let progressT;
function saveProgress(finished) {
  if (!S.day) return;
  clearTimeout(progressT);
  const st = S.stacks[S.cursor], day = S.day.day, body = { pass: S.pass, cursor: st ? st.id : 0, finished: !!finished };
  if (st && typeof st.lead === 'number') body.lead = st.lead;
  progressT = setTimeout(() => send('PUT', '/m/api/day/' + dayPath(day) + '/progress', body, day), finished ? 0 : 600);
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

/* one action = one tap; saved to the server and to the undo history */
const decisionOf = c => ({ flag: c.flag, stars: c.flag === 'pick' ? (c.stars || null) : null, note: c.note || '', state: 'draft', outcome: null });
const sameDecision = (a, b) => (!a || a.flag === 'none' ? null : a.flag + '|' + (a.stars || '') + '|' + (a.note || '')) ===
  (!b || b.flag === 'none' ? null : b.flag + '|' + (b.stars || '') + '|' + (b.note || ''));
const copy = d => (d ? Object.assign({}, d) : null);
function act(label, changes, extra) {
  const before = changes.map(c => [c.id, copy(S.dec[c.id])]);
  for (const c of changes) S.dec[c.id] = decisionOf(c);
  const action_id = newId();
  const at = S.stacks[S.cursor];
  S.hist.push(Object.assign({ action_id, label, before, changes, day: S.day.day, cursor: S.cursor, stack: at ? at.id : null, pass: S.pass, screen: 'cull' }, extra || {}));
  send('POST', '/m/api/decide', { action_id, day: S.day.day, label, changes }, S.day.day);
}
S.undone = {};      // action_id -> history entry, for an undo the PC may refuse
S.hists = new Map(); // day -> its Undo history, kept for the session when you leave the day
const DAY_SCREENS = ['cull', 'picker', 'focus', 'summary', 'grid', 'large'];
const histOf = day => (S.day && S.day.day === day ? S.hist : S.hists.get(day));
function undo() {
  if (!S.day || !DAY_SCREENS.includes(S.screen)) return;
  const h = S.hist.pop();
  if (!h) { toast('Nothing to undo'); return; }
  h.at = S.hist.length;
  h.undoneFrom = h.before.map(([id]) => [id, copy(S.dec[id])]);
  for (const [id, d] of h.before) { if (d) S.dec[id] = d; else delete S.dec[id]; }
  S.undone[h.action_id] = h;
  send('POST', '/m/api/undo', { action_id: h.action_id }, h.day);
  S.pass = h.pass;
  S.picker = null;
  closeSheet();
  toast('Undone: ' + h.label);
  if (h.screen === 'summary') { S.screen = 'summary'; return draw(); }
  const back = S.stacks.findIndex(s => s.id === h.stack);   // the same stack, wherever a search put it
  S.cursor = back >= 0 ? back : Math.min(h.cursor, S.stacks.length - 1);
  S.screen = 'cull';
  saveProgress();
  draw();
}
// The PC refused an undo (409: the tap already reached Lightroom), so it is still in force: put
// its decisions back, except on a frame decided again since, and the entry back in Undo.
function undoRefused(actionId, err) {
  const h = S.undone[actionId];
  if (!h) return false;
  delete S.undone[actionId];
  const list = histOf(h.day);
  if (list) list.splice(Math.min(h.at, list.length), 0, h);
  if (S.day && S.day.day === h.day) {
    const was = new Map(h.before);
    for (const [id, d] of h.undoneFrom) if (sameDecision(S.dec[id], was.get(id))) { if (d) S.dec[id] = d; else delete S.dec[id]; }
    if (DAY_SCREENS.includes(S.screen)) draw();
  }
  toast('Not undone: ' + err);
  return true;
}
// The PC refused a decide (a 4xx): the card goes back to what it was, unless decided again since.
function decideRefused(actionId) {
  const u = S.undone[actionId];
  delete S.undone[actionId];   // already undone here: the card shows what it was
  if (u) return;
  for (const list of [S.hist, ...S.hists.values()]) {
    const i = list.findIndex(h => h.action_id === actionId);
    if (i < 0) continue;
    const h = list.splice(i, 1)[0], was = new Map(h.before);
    if (!S.day || S.day.day !== h.day) return;   // that day shows the server's rows when it opens
    for (const c of h.changes) if (sameDecision(S.dec[c.id], decisionOf(c))) { const d = was.get(c.id); if (d) S.dec[c.id] = d; else delete S.dec[c.id]; }
    if (DAY_SCREENS.includes(S.screen)) draw();
    return;
  }
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
  draw();
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
function closeSheet() { S.sheet = false; S.sendAll = null; const el = $('#sheet'); el.hidden = true; el.innerHTML = ''; }
function detailHTML(s, f) {
  const lead = leadOf(s), d = S.dec[f.id];
  const files = [f.file].concat(f.partners || []).join(' + ');
  const fromApp = ' from Culling Bay';
  const lines = [];
  if (s.frames.length > 1 && f.sharpness != null && lead.sharpness != null) {
    lines.push(f.id === lead.id ? 'The sharpest frame in its burst (measured ' + Math.round(f.sharpness) + ').'
      : 'Measured sharpness ' + Math.round(f.sharpness) + ', against ' + Math.round(lead.sharpness) + ' for ' + stem(lead.file) + ', the sharpest in this burst.');
  }
  if (f.badges.includes('Blown')) lines.push('Blown: ' + Math.round(f.blown_pct) + '% of the pixels are pure white.');
  if (f.badges.includes('Dark')) lines.push('Dark: mean brightness ' + Math.round(f.mean_lum) + ' of 255.');
  if (f.lr && (f.lr.pick || f.lr.rating)) {
    const bits = [];
    if (f.lr.pick) bits.push((f.lr.pick === 1 ? 'picked' : 'rejected') + (f.lr.by === 'you' ? ' by you' : fromApp));
    if (f.lr.rating) bits.push(f.lr.rating + ' star' + (f.lr.rating > 1 ? 's' : '') + (f.lr.stars_by === 'you' ? ' by you' : fromApp));
    lines.push('In Lightroom at the last sync: ' + bits.join(', ') + '.');
  }
  if (s.kind === 'bracket') lines.push('Looks like an exposure bracket: dark, normal and bright frames together. Keep all to merge it in Lightroom.');
  if (s.kind === 'pano') lines.push('The frames slide one way, like a panorama, so Keep all is suggested.');
  const head = '<p class="sh-id">' + esc(files) + '</p>' +
    (f.lens || f.place ? '<p class="sh-muted">' + esc([f.lens, f.place ? 'near ' + f.place : ''].filter(Boolean).join(' · ')) + '</p>' : '');
  const body = lines.map(l => '<p class="sh-why">' + esc(l) + '</p>').join('') +
    (d && d.note ? '<p class="sh-why">Lightroom note: ' + esc(d.note) + '</p>' : '') +
    (f.caption ? '<p class="sh-cap">“' + esc(f.caption) + '”</p>' : '') +
    (f.caption ? '<p class="sh-muted">The AI’s caption.</p>' : '') +
    '<button class="pb2" data-act="like" data-id="' + f.id + '" data-name="' + esc(stem(f.file)) + '">More like this: days with similar photos</button>';
  return { head, body };
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
// timing (perf-client.js): on the cull card, how long from drawing it to its photo being ready,
// so a decision followed by a wait for the next photo shows up; and a day's first photo.
function bindPhotos(root, perfT) {
  let first = root.dataset.screen === 'cull' && perfT !== undefined;
  for (const p of root.querySelectorAll('.photo')) {
    const im = p.querySelector('img'), id = p.dataset.fid, timed = first;
    first = false;
    const ready = () => {
      noteAR(id, im); fitPhoto(p);
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
let bandResizeT;
window.addEventListener('resize', () => {
  for (const p of view.querySelectorAll('.photo')) fitPhoto(p);
  clearTimeout(bandResizeT);
  bandResizeT = setTimeout(() => { if ($('#band', view)) loadBand(); }, 120);
});
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
  netDiv();
const backBtn = (act, label) => '<button class="tbtn" data-act="' + act + '">' + IC.back + '<span>' + label + '</span></button>';

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
S.dayView = recall('cbm-dayview', 'date');
// The camera's AF point as a box on the photo: off unless you turn it on (the AF button on a card).
S.showAF = recall('cbm-show-af', false);
document.documentElement.classList.toggle('hide-af', !S.showAF);
S.daySearch = '';
S.yearsOpen = null;   // set of open years; the newest starts open
const yearOf = d => d.day.slice(0, 4);
const town = p => (p ? p.split(', ').slice(0, 2).join(', ') : '');
const regionOf = p => { const parts = p.split(', '); return parts.length > 1 ? parts.slice(1).join(', ') : p; };
const lrCulled = d => !d.decided && !d.finished && d.stacks && d.lr_done >= d.stacks;

// A shoot under 48 hours old is marked as resting: a nudge to cull it with fresh eyes, never a block.
const resting = d => !d.decided && !d.finished && d.last_ts && Date.now() / 1000 - d.last_ts < 48 * 3600;
// Decisions a day has not sent to Lightroom yet (draft, or missing from the last sync); an older
// server without `unsent` gives decided minus sent (the iPhone's CullSendAllModel.unsent).
const unsentOf = d => (typeof d.unsent === 'number' ? d.unsent : Math.max(0, (d.decided || 0) - (d.sent || 0)));
function dayRow(d, hit) {   // hit: a search result for the day, {why, ids}
  if (!hit || typeof hit !== 'object') hit = null;
  const pct = d.frames ? Math.round(d.decided / d.frames * 100) : 0, unsent = unsentOf(d);
  // A day with decisions not sent never reads Sent or Synced, though an earlier send went.
  const tag = d.conflicts ? '<span class="tag warn">' + d.conflicts + ' conflict' + (d.conflicts > 1 ? 's' : '') + '</span>'
    : unsent && d.finished ? '<span class="tag unsent">Finished, not sent</span>'
    : unsent ? '<span class="tag">' + pct + '%</span>'
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
    '<span class="day-b"><b>' + esc(dayTitle(d)) + '</b><span>' + esc(meta.join(' · ')) +
      (unsent ? ' · <em class="unsent">' + unsent + ' unsent</em>' : '') + '</span>' +
    (d.place ? '<span class="place">' + esc(town(d.place)) + '</span>' : '') +
    (hit && hit.why ? '<span class="why">' + esc(hit.why) + '</span>'
      : d.summary ? '<span class="dsum">' + d.summary.split('\n').map(esc).join('<br>') + '</span>' : '') +
    (d.decided ? '<span class="day-bar"><i style="width:' + pct + '%"></i></span>' : '') + '</span>' + tag + '</button>';
}

const dayRows = list => '<div class="day-grid">' + list.map(d => dayRow(d)).join('') + '</div>';

function daysByDate(list, searching) {
  const years = [];
  for (const d of list) { const y = yearOf(d); if (!years.includes(y)) years.push(y); }
  if (!S.yearsOpen) S.yearsOpen = new Set(recall('cbm-years-open', years.slice(0, 1)));
  return years.map(y => {
    const days = list.filter(d => yearOf(d) === y), open = searching || S.yearsOpen.has(y);
    const frames = days.reduce((n, d) => n + d.frames, 0), done = days.filter(d => d.finished || lrCulled(d)).length;
    const head = '<button class="year" data-act="toggle-year" data-year="' + esc(y) + '" id="year-' + esc(y) + '" aria-expanded="' + open + '">' +
      '<b>' + esc(y) + '</b><span>' + days.length + ' day' + (days.length > 1 ? 's' : '') + ' · ' + frames.toLocaleString() + ' frames' + (done ? ' · ' + done + ' done' : '') + '</span><i>' + (open ? '−' : '+') + '</i></button>';
    if (!open) return head;
    const months = [];
    for (const d of days) { const m = d.date ? MONTHS[+d.date.slice(5, 7) - 1] : 'Other folders'; if (!months.includes(m)) months.push(m); }
    return head + months.map(m => {
      const md = days.filter(d => (d.date ? MONTHS[+d.date.slice(5, 7) - 1] : 'Other folders') === m);
      return '<p class="sec">' + m + ' · ' + md.length + '</p>' + dayRows(md);
    }).join('');
  }).join('');
}

function daysByPlace(list) {
  const placed = list.filter(d => d.place), regions = [];
  for (const d of placed) { const r = regionOf(d.place); if (!regions.includes(r)) regions.push(r); }
  const unplaced = list.length - placed.length;
  return regions.map(r => {
    const rd = placed.filter(d => regionOf(d.place) === r);
    return '<p class="sec">' + esc(r) + ' · ' + rd.length + '</p>' + dayRows(rd);
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
  return (going.length ? '<p class="sec">In progress</p>' + dayRows(going) : '') +
    (lane.length ? '<p class="sec">On this day · earlier years</p>' + dayRows(lane) : '') +
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
    '<div class="day-grid">' + hits.map(h => dayRow(byDay[h.day], h)).join('') + '</div>';
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
    '<a class="monitor-link" href="/">Monitor</a><a class="plink" href="/m/practice.html">Practice ›</a><a class="glink" href="/m/gallery.html">Gallery ›</a></div>' +
    netDiv() +
    '<div class="dtools"><label class="sbox"><input class="search" id="day-search" type="search" placeholder="Search what, where, when" value="' + esc(S.daySearch) + '" autocomplete="off" enterkeyhint="search" aria-label="Search days">' +
    '<button class="sx" id="search-x" data-act="q-clear" aria-label="Clear the search"' + (S.daySearch || S.like ? '' : ' hidden') + '>×</button></label>' +
    '<div class="seg" role="tablist"><button data-act="day-view" data-v="date" aria-selected="' + (S.dayView !== 'place') + '">Date</button>' +
    '<button data-act="day-view" data-v="place" aria-selected="' + (S.dayView === 'place') + '">Place</button></div></div>' +
    sendAllRow() +
    (S.dayView !== 'place' ? '<div class="yearbar">' + years.map(y => '<button data-act="jump-year" data-year="' + esc(y) + '">' + esc(y) + '</button>').join('') + '</div>' : '') +
    '<div class="scroll" id="days-list">' + dayListHTML() + '</div>';
}

/* ---------------------------------------------------------------- Send all
   Send to Lightroom for many days at once (the iPhone's CullSendAllModel): every day with decisions
   not sent yet, the finished ones ticked and the rest listed unticked, then one POST /m/api/send.
   Like a day's own Send, it waits for the taps still saving first, so each day goes whole. */
const unsentDays = () => (S.days || []).filter(d => unsentOf(d) > 0);
function sendAllRow() {
  const n = unsentDays().length;
  return n ? '<button class="send-all" data-act="send-all"><b>Send to Lightroom</b><span>' + n + ' day' + (n === 1 ? '' : 's') +
    ' with decisions not sent yet</span><i>›</i></button>' : '';
}
function openSendAll() {
  const items = unsentDays().map(d => ({ d, n: unsentOf(d) }));
  S.sendAll = { finished: items.filter(x => x.d.finished), unfinished: items.filter(x => !x.d.finished),
    sel: new Set(items.filter(x => x.d.finished).map(x => x.d.day)), sending: false, sent: false, message: '' };
  drawSendAll();
}
function drawSendAll() {
  const A = S.sendAll, all = A.finished.concat(A.unfinished), el = $('#sheet');
  const n = all.filter(x => A.sel.has(x.d.day)).length, decisions = all.filter(x => A.sel.has(x.d.day)).reduce((t, x) => t + x.n, 0);
  const row = x => '<button class="sa-row" role="checkbox" aria-checked="' + A.sel.has(x.d.day) + '" data-act="sa-tick" data-day="' + esc(x.d.day) + '"' +
    (A.sending || A.sent ? ' disabled' : '') + '><i>' + IC.check + '</i><span><b>' + esc(dayTitle(x.d)) + '</b><small>' +
    esc([x.d.place && town(x.d.place), x.n + ' decision' + (x.n === 1 ? '' : 's')].filter(Boolean).join(' · ')) + '</small></span></button>';
  const every = n === all.length;
  el.innerHTML = '<div class="sheet send-sheet" role="dialog" aria-modal="true" aria-label="Send to Lightroom">' +
    '<div class="sa-head"><p class="sh-q">Send to Lightroom</p>' + (all.length && !A.sent ? '<button class="link" data-act="sa-all"' + (A.sending ? ' disabled' : '') + '>' + (every ? 'None' : 'All') + '</button>' : '') + '</div>' +
    (all.length ? '' : '<p class="sh-muted">Nothing is waiting to go to Lightroom.</p>') +
    (A.finished.length ? '<p class="sec">Finished</p>' + A.finished.map(row).join('') : '') +
    (A.unfinished.length ? '<p class="sec">Not finished yet</p>' + A.unfinished.map(row).join('') +
      '<p class="sh-muted">Their decisions so far can go too; tick them to send.</p>' : '') +
    '<p class="sa-msg' + (A.message && !A.sent ? ' warn' : '') + '" role="status">' + esc(A.message || (n ? decisions + ' decision' + (decisions === 1 ? '' : 's') + ' from ' + n + ' day' + (n === 1 ? '' : 's') : '')) + '</p>' +
    '<div class="sh-row">' + (A.sent ? '<button class="pb2 pri" data-act="close-sheet">Done</button>'
      : '<button class="pb2" data-act="close-sheet">Cancel</button><button class="pb2 pri" data-act="sa-send"' + (n && !A.sending ? '' : ' disabled') + '>' +
        (A.sending ? 'Sending…' : n ? 'Send ' + n + ' day' + (n === 1 ? '' : 's') + ' to Lightroom' : 'Pick the days to send') + '</button>') + '</div></div>';
  el.hidden = false;
  S.sheet = true;
}
// The answer to a failed Send, for a day or for many: 503 is the inbox share not being mounted.
const notSent = e => (e.status === 503 ? 'Not sent: the Lightroom inbox share is not mounted on the PC, so nothing was sent. Try again once it is.'
  : 'Not sent: ' + e.message);
async function sendAll() {
  const A = S.sendAll, days = A.finished.concat(A.unfinished).map(x => x.d.day).filter(d => A.sel.has(d));
  if (!days.length || A.sending) return;
  A.sending = true; A.message = ''; drawSendAll();
  try {
    if (!await drained()) { A.message = stillOffline('Send once they are in.'); return; }
    const r = await writeNow('/m/api/send', { days });
    A.sent = true;
    A.message = r.queued ? 'Queued ' + r.queued + ' decision' + (r.queued === 1 ? '' : 's') + ' from ' + days.length + ' day' + (days.length === 1 ? '' : 's') +
      ' for Lightroom. On the Mac: Sync AI Cull Data.' : 'Nothing new to send.';
    refreshDayList();
  } catch (e) { A.message = notSent(e); }
  finally { A.sending = false; if (S.sendAll === A && S.sheet) drawSendAll(); }
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
  const badges = (s.kind === 'pano' ? '<span class="bd bd-dot">Looks like a panorama</span>'
    : s.kind === 'bracket' ? '<span class="bd bd-dot">Looks like a bracket</span>'
    : burst && f.id === s.lead ? '<span class="bd bd-dot">Sharpest</span>' : '') +
    f.badges.map(b => '<span class="bd">' + esc(b) + '</span>').join('') + lrHere;
  // The button that made the decision shows pressed when you come back to the stack.
  const kept = s.frames.filter(x => isPick(S.dec[x.id])).length;
  const pressed = a => !st.done ? false : a === 'reject' ? st.v === 'reject' : st.v === 'reject' ? false
    : a === 'hero' ? st.v === 'hero'
    : a === 'keep-all' ? st.src !== 'lr' && kept === s.frames.length
    : st.v !== 'hero' && (st.src === 'lr' || !burst || kept < s.frames.length);
  const on = a => (pressed(a) ? ' on' : '');
  const cls = 'card' + (burst ? ' is-stack' : '') + (st.done ? ' st-' + st.v : '');
  const left = n - doneCount(), togo = left + (left === 1 ? ' stack' : ' stacks') + ' to go';
  // The RAW at 1:1 where the camera focused (or the centre); layoutWide() puts it in the rail and
  // loadBand() fills it in.
  const band = '<div class="band" id="band"><img alt="" draggable="false"><span class="bd">1:1 at ' +
    (f.af ? 'the AF point' : 'the centre') + '</span><span class="band-load">Decoding the RAW…</span></div>';
  return top(backBtn('days', 'Days'), dayTitle(S.day), S.matches ? '' : togo,
      '<div class="tools"><button class="ico af-tgl" data-act="toggle-af" aria-pressed="' + S.showAF + '" aria-label="Show the camera’s AF point">AF</button><button class="ico" data-act="grid" aria-label="Show every photo in a grid">' + IC.grid + '</button></div>',
      S.matches ? '<button class="mchip" data-act="matches">' + S.matches.n + ' match' + (S.matches.n === 1 ? '' : 'es') + ' first</button> · ' + left + ' to go' : '') +
    '<div class="prog"><i style="width:' + (doneCount() / n * 100).toFixed(1) + '%"></i></div>' + budgetBar() +
    '<div class="stage" id="stage"><div class="' + cls + '">' +
      photo(f, afBox(f) + stLine(s, st) + '<div class="badges">' + badges + '</div>') + '</div>' + band + '</div>' +
    '<div class="rcol">' + (burst ? '' : starRow(st.done && st.v !== 'reject' ? (frameMark(f) || {}).stars || 0 : 0)) +
    '<div class="bar"><button class="pb pb-rej' + on('reject') + '" data-act="reject">' + IC.x + '<span>Reject</span></button>' +
      '<button class="pb pb-undo" data-act="undo"' + (S.hist.length ? '' : ' disabled') + '>' + IC.undo + '<span>Undo</span></button>' +
      (burst ? '<button class="pb pb-all' + (sugg && !st.done ? ' sugg' : '') + on('keep-all') + '" data-act="keep-all">' + IC.stack + '<span>Keep all ' + s.frames.length + '</span></button>' : '') +
      (burst ? '<button class="pb pb-keep' + on('keep') + '" data-act="choose">' + IC.stack + '<span>Choose</span></button></div>'
        : '<button class="pb pb-keep' + on('keep') + on('hero') + '" data-act="keep">' + IC.check + '<span>Keep</span></button></div>') + '</div>' +
    '<div class="hint">' + (burst ? 'P choose · A keep all' : 'P keep · 1–5 stars') + ' · X reject · ← → browse · Z focus</div>';
}

// The burst picker, as the iPhone's (CullPickerModel): a filmstrip whatever the burst's size, a
// tick on each frame to keep, and stars. Saving keeps what is ticked and rejects the rest.
function vStrip() {
  const s = S.stacks[S.cursor], fr = s.frames, pk = S.picker, f = fr[pk.view], on = pk.sel.has(f.id);
  const n = pk.sel.size, m = frameMark(f);
  const lrBadge = lrMark(f) && !(m && m.text.endsWith('in Lightroom')) ? '<span class="bd bd-lr">' + esc(lrWord(f)) + '</span>' : '';
  // The rail's 1:1 shows every frame at the same spot, the lead frame's AF point (loadBand).
  return top('<button class="tbtn" data-act="close-picker">Cancel</button>', 'Burst of ' + fr.length, 'Tick the keepers') +
    '<div class="pk-main" id="pk-main"><div class="pk-box">' + photo(f, afBox(f)) + '</div>' +
      '<div class="pk-bd">' + (f.id === s.lead ? '<span class="bd bd-dot">Sharpest</span>' : '') + f.badges.map(b => '<span class="bd">' + esc(b) + '</span>').join('') + lrBadge + '</div>' +
      (m ? '<span class="pk-flag ' + m.v + '">' + esc(m.text) + (m.stars ? ' ' + starText(m.stars) : '') + '</span>' : '') +
      '<button class="pk-tick' + (on ? ' on' : '') + '" data-act="tick" aria-pressed="' + on + '" aria-label="Keep ' + esc(f.file) + '">' + IC.check + '</button>' +
      '<span class="pk-id">' + esc(stem(f.file)) + ' · ' + (pk.view + 1) + '/' + fr.length + '</span></div>' +
    '<div class="pk-strip">' + fr.map((x, i) => '<button class="pk-th' + (i === pk.view ? ' cur' : '') + '" data-act="view" data-i="' + i + '" aria-label="Show ' + esc(x.file) + '">' +
      thumb(x) + (x.id === s.lead ? '<i class="dot"></i>' : '') + (pk.sel.has(x.id) ? '<b>' + IC.check + '</b>' : '') + '</button>').join('') + '</div>' +
    starRow(pk.rate[f.id] || 0, 'Rate this frame') +
    '<p class="pk-note">← → browse · 1–5 rate · P keep · X leave out · Z focus · Enter save</p>' +
    '<div class="foot"><button class="pb2" data-act="pk-reject">Reject all ' + fr.length + '</button>' +
      '<button class="pb2 pri" data-act="pk-keep"' + (n ? '' : ' disabled') + '>' + (n ? 'Keep ' + n + ' · reject ' + (fr.length - n) : 'Tick a keeper') + '</button></div>';
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
// From a card: Reject rejects the stack (all of a burst's frames). On a burst, Keep opens the
// picker on this frame rather than keeping it and rejecting the rest unseen.
function vFocus() {
  const f = frameById(S.focus.id), fromCard = S.focus.ret === 'cull', m = frameMark(f);
  const atAF = f.af && Math.abs(f.af[0] - S.focus.u) < 1e-3 && Math.abs(f.af[1] - S.focus.v) < 1e-3;
  return top(backBtn('close-focus', 'Back'), 'Focus · ' + stem(f.file), (atAF ? 'At the camera’s AF point' : '1:1 from the RAW') + ' · drag to look around') +
    (m ? '<div class="fz-st ' + m.v + '">' + (m.v === 'reject' ? '✕ ' : '✓ ') + esc(m.text) + (m.stars ? ' ' + starText(m.stars) : '') + '</div>' : '') +
    '<div class="fz" id="fz"><img alt="" draggable="false"><div class="fz-load">Decoding the RAW…</div></div>' +
    '<div class="fz-cap">Wheel to zoom · drag to pan · Esc to go back</div>' +
    (fromCard ? '<div class="foot"><button class="pb2' + (m && m.v === 'reject' ? ' on-rej' : '') + '" data-act="reject">' +
      (isBurst() ? 'Reject all ' + S.stacks[S.cursor].frames.length : 'Reject') + '</button>' +
      '<button class="pb2 pri' + (m && m.v !== 'reject' ? ' on-keep' : '') + '" data-act="keep">Keep</button></div>' : '');
}
function loadFocus() {
  const box = $('#fz', view);
  if (!box) return;
  const im = $('img', box), load = $('.fz-load', box), r = box.getBoundingClientRect();
  const dpr = Math.min(3, window.devicePixelRatio || 1);
  const w = Math.min(2400, Math.round(r.width * dpr * 1.6)), h = Math.min(2400, Math.round(r.height * dpr * 1.6));
  const { id, u, v } = S.focus;
  let pos = { x: 0, y: 0 }, cw = 0, scale = 1;
  const place = () => { im.style.transform = 'translate(' + pos.x + 'px,' + pos.y + 'px) scale(' + scale + ')'; };
  im.onload = () => {
    cw = im.naturalWidth / dpr; const ch = im.naturalHeight / dpr;      // one image pixel per device pixel
    im.style.width = cw + 'px'; im.style.height = ch + 'px';
    pos = { x: (r.width - cw) / 2, y: (r.height - ch) / 2 };
    place();
    load.hidden = true;
  };
  im.onerror = () => { load.textContent = 'Could not decode this frame.'; };
  const url = '/m/api/crop/' + id + '?x=' + u.toFixed(4) + '&y=' + v.toFixed(4) + '&w=' + w + '&h=' + h;
  keepCrops([url]);
  getCrop(url, true).then(src => { if (box.isConnected) im.src = src; }).catch(e => {
    if (box.isConnected && e.message !== 'cancelled' && e.name !== 'AbortError') im.onerror();
  });
  box.addEventListener('wheel', e => {
    if (!cw) return;
    e.preventDefault();
    const bounds = box.getBoundingClientRect(), x = e.clientX - bounds.left, y = e.clientY - bounds.top;
    const next = Math.max(.25, Math.min(8, scale * Math.exp(-e.deltaY * (e.deltaMode === 1 ? .03 : .002))));
    pos.x = x - (x - pos.x) * next / scale; pos.y = y - (y - pos.y) * next / scale;
    scale = next; place();
  }, { passive: false });
  let drag = null;
  box.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    drag = { x: e.clientX, y: e.clientY, px: pos.x, py: pos.y };
    try { box.setPointerCapture(e.pointerId); } catch (_) {}
  });
  box.addEventListener('pointermove', e => {
    if (!drag || !cw) return;
    pos.x = drag.px + e.clientX - drag.x;
    pos.y = drag.py + e.clientY - drag.y;
    place();
  });
  box.addEventListener('pointerup', () => { drag = null; });
  box.addEventListener('pointercancel', () => { drag = null; });
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
    '<p class="note">Your decisions here, or your Lightroom flags from the last sync where you made none. Click a photo to open its card.</p>' +
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
      '</div><p class="note">' + over + ' over this shoot’s budget of ' + b + ' (' + S.day.budget.per_hour + ' stacks an hour of shooting). ' + 'Click a stack to drop it.</p>'
    : b ? '<p class="note">Kept ' + keptN + ' of this shoot’s budget of ' + b + '.</p>' : '';
  const sendLabel = unsent ? 'Send ' + unsent + ' to Lightroom' : queued ? 'Waiting for Lightroom' : landed ? 'In Lightroom' : 'Send to Lightroom';
  return top(backBtn('back-cull', 'Cards'), dayTitle(S.day), open < 0 ? 'Day finished' : 'Rejects so far',
      '<div class="tools"><button class="ico" data-act="grid" aria-label="Show every photo in a grid">' + IC.grid + '</button></div>') +
    '<div class="scroll">' + (S.day.summary ? '<p class="dsum-top">' + S.day.summary.split('\n').map(esc).join('<br>') + '</p>' : '') +
      '<div class="counts"><div><b>' + keep + '</b><span>Kept</span></div><div><b>' + hero + '</b><span>Hero</span></div>' +
      '<div><b>' + rej + '</b><span>Rejected</span></div><div><b>' + none + '</b><span>Unflagged</span></div></div>' + trim +
      (lr.length ? '<p class="sec">Lightroom</p>' + lr.map(t => '<p class="note">' + esc(t) + '</p>').join('') : '') +
      (won.length ? '<p class="sec">Your Lightroom flag won</p>' + wonGrid +
        '<p class="note">Culling Bay said otherwise, but you had flagged ' + (won.length > 1 ? 'these' : 'this') + ' in Lightroom yourself, so Lightroom kept your flag. Change it there if Culling Bay was right.</p>' : '') +
      (rejects.length ? (fromBurst.length ? '<p class="sec">From bursts · similar frame kept</p>' + grid(fromBurst) : '') +
        (outright.length ? '<p class="sec">Rejected outright</p>' + grid(outright) : '') + '<p class="note">Click a frame to look at it large and rescue it.</p>'
        : '<p class="note">No rejects today.</p>') +
      '<p class="note"><button class="link" data-act="reset-ask">Start this day over</button></p></div>' +
    '<div class="foot"><button class="pb2" data-act="days">Back to days</button><button class="pb2 pri" data-act="send"' + (unsent ? '' : ' disabled') + '>' + sendLabel + '</button></div>';
}

// A reject, large, from the review: step through the day's rejects with the arrows, rescue the
// ones that deserve it, click to check focus. Rescued frames stay in the run with a ✓ until you go back.
function vLarge() {
  const L = S.large, f = frameById(L.ids[L.i]), d = S.dec[f.id], rejected = !!d && d.flag === 'reject';
  return top(backBtn('close-large', 'Review'), stem(f.file), (L.i + 1) + ' of ' + L.ids.length + ' · ← → browse') +
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
  if (m) bindPhotoClick(m, frameById(S.large.ids[S.large.i]));
}

function draw() {
  const perfT = performance.now();
  rememberStrip();
  const list = view.dataset.screen === 'days' && $('#days-list', view);
  if (list) S.daysScroll = list.scrollTop;   // where you were in the days, for coming back
  const active = lastInputKey && view.contains(document.activeElement) ? { ...document.activeElement.dataset } : null;
  if (S.screen === 'picker' && !S.picker) S.screen = 'cull';
  if ((S.screen === 'cull' || S.screen === 'picker') && !S.stacks[S.cursor]) S.screen = 'summary';
  const scr = S.screen;
  view.innerHTML = scr === 'days' ? vDays() : scr === 'loading' ? vLoading('Loading the day…')
    : scr === 'error' ? vLoading(S.error || 'Something went wrong')
    : scr === 'picker' ? vStrip()
    : scr === 'summary' ? vSummary() : scr === 'focus' ? vFocus() : scr === 'grid' ? vGrid() : scr === 'large' ? vLarge() : vCull();
  view.dataset.screen = scr;
  if (scr === 'days' && S.daysScroll) { const l = $('#days-list', view); if (l) l.scrollTop = S.daysScroll; }
  layoutWide();
  bindPhotos(view, perfT);
  restoreStrip();
  if (active && active.act) {
    const control = [...view.querySelectorAll('[data-act]')].find(b => Object.keys(active).every(k => b.dataset[k] === active[k]));
    if (control) control.focus({ preventScroll: true });
    else view.focus({ preventScroll: true });
  }
  if (scr === 'cull') {
    bindStage();
    loadBand();
    setTimeout(prefetch, 80);
  }
  if (scr === 'picker') { bindPickerSwipe(); loadBand(); }
  else if (scr !== 'cull') keepCrops([]);
  if (scr === 'focus') requestAnimationFrame(loadFocus);
  if (scr === 'large') bindLarge();
}

/* The card and picker screens are drawn as one column of controls, then moved into the rail
   beside the photo, with the header above and the day's filmstrip below. */
function layoutWide() {
  if (!['cull', 'picker'].includes(S.screen)) return;
  const s = S.stacks[S.cursor], picking = S.screen === 'picker';
  const f = picking ? s.frames[S.picker.view] : shown(s), details = detailHTML(s, f);
  const header = document.createElement('header');
  header.className = 'wide-header';
  for (const el of view.querySelectorAll(':scope > .top, :scope > .net, :scope > .prog, :scope > .budget')) header.append(el);
  view.prepend(header);
  const rail = document.createElement('aside');
  rail.className = 'detail-rail'; rail.setAttribute('aria-label', 'Photo details');
  rail.innerHTML = details.head;
  const badges = $('.badges, .pk-bd', view);
  if (badges) rail.append(badges);
  let band = $('#band', view);
  if (!band) {
    band = document.createElement('div'); band.className = 'band'; band.id = 'band';
    band.innerHTML = '<img alt="" draggable="false"><span class="bd">1:1 · the same spot on every frame' +
      '</span><span class="band-load">Decoding the RAW…</span>';
  }
  const crop = document.createElement('button');
  crop.className = 'rail-crop'; crop.dataset.act = 'rail-focus'; crop.dataset.id = f.id;
  crop.setAttribute('aria-label', 'Open focus at this spot');
  crop.append(band); rail.append(crop);
  const body = document.createElement('div'); body.className = 'rail-facts'; body.innerHTML = details.body;
  rail.append(body);
  if (picking) {
    const tick = $('.pk-tick', view), flag = $('.pk-flag', view), id = $('.pk-id', view);
    if (flag) rail.append(flag);
    if (id) rail.append(id);
    tick.innerHTML = IC.check + '<span>Keep this frame</span>';
    rail.append(tick);
    for (const el of view.querySelectorAll(':scope > .stars, :scope > .pk-note, :scope > .foot')) rail.append(el);
    const strip = $('.pk-strip', view);
    strip.dataset.stripKey = S.day.day + ':picker:' + s.id;
    strip.setAttribute('aria-label', 'Burst frames');
    for (const b of strip.children) b.setAttribute('aria-current', b.classList.contains('cur'));
  } else {
    const line = $('.stline', view); if (line) rail.insertBefore(line, body);
    const col = $('.rcol', view); rail.append(col);
    const hint = $('.hint', view); if (hint) rail.append(hint);
    view.insertAdjacentHTML('beforeend', dayFilmstrip());
  }
  rail.insertAdjacentHTML('beforeend', '<button class="link" data-act="keys">Keyboard shortcuts (?)</button>');
  view.append(rail);
}
function dayFilmstrip() {
  return '<nav class="day-filmstrip" data-strip-key="' + esc(S.day.day + ':day') + '" aria-label="Day stacks">' +
    S.stacks.map((s, i) => {
      const f = shown(s), st = status(s);
      return '<button class="film-thumb' + (st.done ? ' st-' + st.v : '') + (i === S.cursor ? ' cur' : '') +
        '" data-act="film-jump" data-stack="' + i + '" aria-current="' + (i === S.cursor) + '" aria-label="' +
        esc(f.file + (s.frames.length > 1 ? ', ' + s.frames.length + ' frames' : '') + (st.done ? ', ' + (st.v === 'reject' ? 'rejected' : 'kept') : '')) + '">' +
        thumb(f) + (s.frames.length > 1 ? '<span>' + s.frames.length + '</span>' : '') + '</button>';
    }).join('') + '</nav>';
}
const stripPositions = new Map();
function rememberStrip() {
  const strip = $('[data-strip-key]', view);
  if (strip) stripPositions.set(strip.dataset.stripKey, [strip.scrollLeft, strip.scrollTop]);
}
function restoreStrip() {
  const strip = $('[data-strip-key]', view);
  if (!strip) return;
  const pos = stripPositions.get(strip.dataset.stripKey) || [0, 0];
  strip.scrollLeft = pos[0]; strip.scrollTop = pos[1];
  const cur = $('.cur', strip);
  if (!cur) return;
  // All adjustments happen before paint; never scroll the page or animate a new strip from zero.
  const r = strip.getBoundingClientRect(), c = cur.getBoundingClientRect();
  if (c.left < r.left + 8) strip.scrollLeft += c.left - r.left - 8;
  else if (c.right > r.right - 8) strip.scrollLeft += c.right - r.right + 8;
  if (c.top < r.top + 8) strip.scrollTop += c.top - r.top - 8;
  else if (c.bottom > r.bottom - 8) strip.scrollTop += c.bottom - r.bottom + 8;
}
function bindPhotoClick(stage, f) {
  let start = null;
  stage.addEventListener('pointerdown', e => {
    if (e.button !== 0 || e.target.closest('button') || !e.target.closest('.photo')) return;
    start = { x: e.clientX, y: e.clientY, moved: false };
    stage.setPointerCapture(e.pointerId);
  });
  stage.addEventListener('pointermove', e => {
    if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 6) start.moved = true;
  });
  stage.addEventListener('pointercancel', () => { start = null; });
  stage.addEventListener('pointerup', e => {
    const down = start; start = null;
    if (!down || down.moved || Math.hypot(e.clientX - down.x, e.clientY - down.y) > 6) return;
    const p = imagePoint($('.photo img', stage), e.clientX, e.clientY);
    openFocus(f.id, p.u, p.v);
  });
}
view.addEventListener('wheel', e => {
  const strip = e.target.closest('[data-strip-key]');
  if (!strip || Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
  e.preventDefault();
  strip.scrollLeft += e.deltaY * (e.deltaMode === 1 ? 16 : 1);
}, { passive: false });
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
function bandUrls() {   // this card's 1:1 and the next two cards', for keepCrops
  const out = [];
  for (let k = 0; k <= 2 && S.bandSize; k++) {
    const s = S.stacks[S.cursor + k];
    if (!s) break;
    const v = shown(s);
    out.push(cropUrl(v, spotOf(v), S.bandSize));
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
  let job = (CROPS.live && CROPS.live.url === url && !CROPS.live.ctrl.signal.aborted ? CROPS.live : null) || CROPS.queue.find(j => j.url === url);
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
const railSpot = f => S.screen === 'picker' ? spotOf(leadOf(S.stacks[S.cursor])) : spotOf(f);
const cropUrl = (f, spot, sz) => '/m/api/crop/' + f.id + '?x=' + spot[0].toFixed(4) + '&y=' + spot[1].toFixed(4) + '&w=' + sz.w + '&h=' + sz.h;
const afBox = f => (f.af ? '<span class="af" style="left:' + (f.af[0] * 100).toFixed(2) + '%;top:' + (f.af[1] * 100).toFixed(2) + '%"></span>' : '');
function devSize(el) {   // an element's size in device pixels: one RAW pixel each is 1:1
  const r = el.getBoundingClientRect(), dpr = Math.min(3, window.devicePixelRatio || 1);
  return { w: Math.min(2400, Math.round(r.width * dpr)), h: Math.min(2400, Math.round(r.height * dpr)) };
}
function dropBand() {
  const band = $('#band', view);
  if (band) band.remove();
}
function showCrop(box, url, urgent) {
  const im = $('img', box), load = $('.band-load', box);
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
  const picking = S.screen === 'picker', f = picking ? s.frames[S.picker.view] : shown(s);
  S.bandSize = devSize(band);
  // In a burst: this frame, the next two and the one before, so flipping frames holds the crop still.
  const near = picking && linkedUrls(S.bandSize);
  const urls = picking ? near.slice(0, 3).concat(near.length > 3 ? near.slice(-1) : []) : bandUrls();
  keepCrops(urls);
  showCrop(band, cropUrl(f, railSpot(f), S.bandSize), true);
  for (const u of urls.slice(1)) getCrop(u).catch(() => {});   // so the next bands are there on arrival
}
function linkedUrls(size) {   // a burst's frames at the lead's spot, nearest the one shown first
  const s = S.stacks[S.cursor], pk = S.picker, spot = spotOf(leadOf(s));
  const order = s.frames.slice(pk.view).concat(s.frames.slice(0, pk.view));
  return order.map(f => cropUrl(f, spot, size));
}

/* ---------------------------------------------------------------- moving and clicking */
// A click on the photo opens the 1:1 focus check at that spot; a mouse drag never decides.
function go(d) {
  const n = S.stacks.length;
  if (d > 0 && S.cursor === n - 1) { S.screen = 'summary'; return draw(); }
  S.cursor = Math.max(0, Math.min(n - 1, S.cursor + d));
  saveProgress();
  draw();
}
function bindStage() {
  const stage = $('#stage', view);
  if (stage && $('.card', stage)) bindPhotoClick(stage, shown(S.stacks[S.cursor]));
}
function bindPickerSwipe() {
  const m = $('#pk-main', view);
  if (m) bindPhotoClick(m, S.stacks[S.cursor].frames[S.picker.view]);
}
function stripView(i) { const n = S.stacks[S.cursor].frames.length; S.picker.view = Math.max(0, Math.min(n - 1, i)); draw(); }
function selectFrame(id, on) { if (on) S.picker.sel.add(id); else S.picker.sel.delete(id); }
function savePicker(s) {   // with nothing ticked, nothing happens
  const keeps = s.frames.filter(f => S.picker.sel.has(f.id));
  if (keeps.length) keepFrames(s, keeps, S.picker.rate, 'burst');
}
function rateFrame(n) {
  const f = S.stacks[S.cursor].frames[S.picker.view];
  S.picker.rate[f.id] = n; selectFrame(f.id, true); draw();
}

function showKeys() {
  const rows = [
    ['P / K / ↑', 'Keep · open a burst picker'], ['X / ↓', 'Reject'], ['1–5', 'Keep with stars · rate the frame in a burst'],
    ['← / →', 'Browse'], ['Z / F', 'Focus at the AF point or centre'], ['Ctrl / Cmd + Z', 'Undo'], ['Backspace', 'Undo, on a card or in a burst'],
    ['G', 'Grid'], ['A', 'Keep all frames in a burst'], ['B / Enter', 'Open burst picker'], ['Esc', 'Back (not from a card: Days is the button)'], ['?', 'Keyboard shortcuts'],
  ];
  const el = $('#sheet');
  el.innerHTML = '<div class="sheet key-sheet" role="dialog" aria-modal="true" aria-label="Keyboard shortcuts">' +
    '<p class="sh-q">Keyboard shortcuts</p><dl>' + rows.map(([k, v]) => '<dt>' + k + '</dt><dd>' + v + '</dd>').join('') +
    '</dl><p class="sh-muted">In a burst: P ticks the frame, X unticks it, Enter keeps what is ticked and rejects the rest.</p>' +
    '<button class="pb2" data-act="close-sheet">Close</button></div>';
  S.sheet = true; el.hidden = false;
  $('[data-act="close-sheet"]', el).focus();
}
function onKey(e) {
  const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
  if (e.target.closest('input, textarea, select, [contenteditable="true"]')) return;
  if (e.ctrlKey || e.metaKey || e.altKey) {
    if ((e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && k === 'z' && S.day && !S.sheet) {
      e.preventDefault(); if (!e.repeat) undo();
    }
    return;
  }
  // Native button activation gets the only Enter/Space action, including held keys.
  if ((k === 'Enter' || k === ' ') && e.target.closest('button, a, [role="button"]')) {
    if (e.repeat) e.preventDefault();
    return;
  }
  const decisions = ['p', 'k', 'x', 'ArrowUp', 'ArrowDown', '1', '2', '3', '4', '5', 'a', 'Backspace', 'Enter'];
  if (e.repeat && decisions.includes(k)) { e.preventDefault(); return; }
  if (k === 'Escape') {
    e.preventDefault();
    if (S.sheet) closeSheet();
    else if (S.screen === 'focus') closeFocus();
    else if (S.screen === 'picker') { S.picker = null; S.screen = 'cull'; draw(); }
    else if (S.screen === 'large') { S.large = null; S.screen = 'summary'; draw(); }
    else if (S.screen === 'grid') { S.screen = S.gridFrom || 'cull'; S.gridFrom = null; draw(); }
    else if (S.screen === 'summary') { S.screen = 'cull'; draw(); }
    return;   // on a card Esc does nothing: Days is the way out, and Undo is kept

  }
  if (S.sheet) {
    if (k === 'Tab') {
      const controls = [...$('#sheet').querySelectorAll('button:not(:disabled), a[href]')];
      if (controls.length && ((e.shiftKey && e.target === controls[0]) || (!e.shiftKey && e.target === controls[controls.length - 1]))) {
        e.preventDefault(); controls[e.shiftKey ? controls.length - 1 : 0].focus();
      }
    }
    return;
  }
  if (k === '?') { e.preventDefault(); return showKeys(); }
  if (!S.day) return;
  if (k === 'Backspace') {   // undo, but only where a tap was just made: the card and the picker
    if (S.screen === 'cull' || S.screen === 'picker') { e.preventDefault(); undo(); }
    return;
  }
  if (k === 'g' && ['cull', 'picker', 'focus', 'large', 'summary', 'grid'].includes(S.screen)) {
    e.preventDefault();
    if (S.screen === 'grid') { S.screen = S.gridFrom || 'cull'; S.gridFrom = null; }
    else { S.gridFrom = S.screen; S.screen = 'grid'; }
    return draw();
  }
  if (k === 'ArrowLeft' || k === 'ArrowRight') {
    const d = k === 'ArrowRight' ? 1 : -1;
    e.preventDefault();
    if (S.screen === 'large') return largeStep(d);
    if (S.screen === 'picker') return stripView(S.picker.view + d);
    if (S.screen === 'cull') return go(d);
    return;
  }
  const s = S.stacks[S.cursor], picking = S.screen === 'picker';
  if (!s) return;
  if ((k === 'z' || k === 'f') && ['cull', 'picker', 'large'].includes(S.screen)) {
    e.preventDefault();
    const f = picking ? s.frames[S.picker.view] : S.screen === 'large' ? frameById(S.large.ids[S.large.i]) : shown(s), sp = spotOf(f);
    return openFocus(f.id, sp[0], sp[1]);
  }
  if (picking) {
    if (/^[1-5]$/.test(k)) { e.preventDefault(); return rateFrame(+k); }
    if (['p', 'k', 'ArrowUp', 'x', 'ArrowDown'].includes(k)) {
      e.preventDefault(); selectFrame(s.frames[S.picker.view].id, !['x', 'ArrowDown'].includes(k)); return draw();
    }
    if (k === 'a') { e.preventDefault(); return decide('all'); }
    if (k === 'Enter') { e.preventDefault(); return savePicker(s); }
    return;
  }
  const focusCull = S.screen === 'focus' && S.focus.ret === 'cull';
  if (S.screen !== 'cull' && !focusCull) return;
  if (['p', 'k', 'ArrowUp', 'x', 'ArrowDown', 'a', 'b', 'Enter'].includes(k) || /^[1-5]$/.test(k)) {
    e.preventDefault();
    if (['a', 'b', 'Enter'].includes(k) && !isBurst()) return;
    const at = focusCull ? S.focus.id : null;   // a burst's picker opens on the frame in focus
    if (focusCull) { S.focus = null; S.screen = 'cull'; }
    if (['p', 'k', 'ArrowUp'].includes(k)) return isBurst() ? openPicker(at === null, at) : decide('keep');
    if (['x', 'ArrowDown'].includes(k)) return decide('reject');
    if (/^[1-5]$/.test(k)) {   // on a burst this must not keep one frame and reject the rest unseen
      if (!isBurst()) return decide('keep', +k);
      openPicker(false, at);
      return rateFrame(+k);
    }
    if (k === 'a' && isBurst()) return decide('all');
    if (k === 'b' || k === 'Enter') return openPicker(false, at);
    if (focusCull) draw();
  }
}

/* ---------------------------------------------------------------- navigation */
// Leaving a day: its Undo history is kept for when it opens again this session.
function leaveDay() {
  if (S.day) S.hists.set(S.day.day, S.hist);
  S.day = null; S.stacks = []; S.hist = []; S.picker = null; S.focus = null; S.large = null;
}
let openSeq = 0;   // the day being opened: a late answer for another one is dropped
async function showDays() {
  openSeq++;
  leaveDay();
  S.screen = 'days';
  if (location.hash !== '#/') history.replaceState(null, '', '#/');
  draw();
  await refreshDayList();
}
// Fetches the days (a 304 when nothing changed) and redraws the list only if it did, keeping the
// scroll position and the open years.
let daysSeq = 0;
async function refreshDayList() {
  const seq = ++daysSeq;
  let list;
  try { list = (await getJSON('/m/api/days')).days; }
  catch (e) {
    if (seq !== daysSeq || S.screen !== 'days') return;
    if (S.days) return toast('Could not refresh the days: ' + e.message);
    S.screen = 'error'; S.error = 'Could not load days: ' + e.message; return draw();
  }
  if (seq !== daysSeq) return;
  const sig = JSON.stringify(list);
  if (sig === S.daysSig) return;
  S.days = list; S.daysSig = sig;
  if (S.screen === 'days') draw();
}
// Taps for this day still in the queue (made offline, or not saved yet): the day as loaded doesn't
// have them, so they are laid over it in order, an undo taking back its decide (the iPhone's
// layQueued). Returns the newest position still queued for the day.
function layQueued(day) {
  const before = {};
  let at = null;
  for (const it of qRead()) {
    if (it.kind === 'decide' && it.body.day === day) {
      before[it.body.action_id] = it.body.changes.map(c => [c.id, copy(S.dec[c.id])]);
      for (const c of it.body.changes) S.dec[c.id] = decisionOf(c);
    } else if (it.kind === 'undo' && before[it.body.action_id]) {
      for (const [id, d] of before[it.body.action_id]) { if (d) S.dec[id] = d; else delete S.dec[id]; }
      delete before[it.body.action_id];
    } else if (it.kind === 'progress' && it.day === day) at = it.body;
  }
  return at;
}
async function openDay(day, match) {   // match: {ids, label} from a search, whose stacks go first
  const seq = ++openSeq;
  S.perfDay = performance.now();
  leaveDay();
  S.screen = 'loading'; draw();
  let body;
  try { body = await getJSON('/m/api/day/' + dayPath(day)); }
  catch (e) {
    if (seq !== openSeq || S.screen !== 'loading') return;
    S.screen = 'error'; S.error = 'Could not load ' + day + ': ' + e.message; return draw();
  }
  if (seq !== openSeq || S.screen !== 'loading') return;   // you went back, or opened another day
  S.day = body; S.stacks = body.stacks; S.dec = {}; S.hist = S.hists.get(body.day) || []; S.picker = null; S.matches = null;
  for (const s of S.stacks) for (const f of s.frames) if (f.decision) S.dec[f.id] = f.decision;
  const queuedAt = layQueued(body.day);
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
  if (!S.matches && queuedAt) {     // a position still in the queue is newer than the server's
    const i = queuedAt.lead != null ? S.stacks.findIndex(s => s.lead === queuedAt.lead) : -1;
    S.cursor = i >= 0 ? i : Math.max(0, S.stacks.findIndex(s => s.id === queuedAt.cursor));
  }
  const i = status(S.stacks[S.cursor]).done ? firstOpen(S.cursor) : S.cursor;
  if (i < 0) S.screen = 'summary'; else { S.cursor = i; S.screen = 'cull'; await loadShape(shown(S.stacks[i]).id, 1500); }
  if (seq !== openSeq) return;
  const hash = '#/day/' + dayPath(day);
  if (location.hash !== hash) history.replaceState(null, '', hash);
  draw();
}
// Send: every queued tap must reach the server first, so the day is sent whole.
// Waits up to 10 s for every queued write to reach the PC; false if some are still waiting.
async function drained() {
  pump();
  for (let i = 0; i < 40 && qRead().length; i++) await sleep(250);
  return !qRead().length;
}
const stillOffline = then => 'Still offline: ' + (tapsIn(qRead()) || 'some') + ' taps waiting to save. ' + then;
// A write that is not queued (Send, Start over): its answer, or an error to show.
async function writeNow(url, body) {
  const r = await write('POST', url, body);
  if (!r) throw new Error('no answer from the PC');
  const out = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(out.error || 'HTTP ' + r.status), { status: r.status });
  return out;
}
async function sendDay(btn) {
  btn.disabled = true;
  if (!await drained()) { btn.disabled = false; return toast(stillOffline('Send once they are in.')); }
  let body;
  try { body = await writeNow('/m/api/day/' + dayPath(S.day.day) + '/send', {}); }
  catch (e) { btn.disabled = false; return toast(notSent(e)); }
  for (const id in S.dec) if (S.dec[id].state === 'draft' || S.dec[id].state === 'missing') S.dec[id].state = 'queued';
  toast(body.queued ? 'Queued ' + body.queued + ' for Lightroom. On the Mac: Sync AI Cull Data.' : 'Nothing new to send.');
  draw();
}

// Start a day over: clears Culling Bay's decisions for it. Allowed until any of them reach
// Lightroom; rows already queued in the inbox are taken back out.
function resetAsk() {
  const ds = Object.values(S.dec), applied = ds.filter(d => d.state === 'landed' || d.state === 'conflict').length;
  const queued = ds.filter(d => d.state === 'queued').length;
  const el = $('#sheet');
  el.innerHTML = '<div class="sheet" role="dialog" aria-label="Start this day over">' + (applied
    ? '<p class="sh-q">Already in Lightroom</p><p class="sh-muted">' + applied + ' decision' + (applied > 1 ? 's' : '') +
      ' from this day reached Lightroom in a sync. Culling Bay can’t take ' + (applied > 1 ? 'them' : 'it') + ' back: change ' + (applied > 1 ? 'those photos' : 'that photo') + ' in Lightroom.</p>' +
      '<div class="sh-row"><button class="pb2" data-act="close-sheet">Close</button></div>'
    : '<p class="sh-q">Start ' + esc(dayTitle(S.day)) + ' over?</p><p class="sh-muted">Clears the ' + ds.length + ' decision' + (ds.length === 1 ? '' : 's') +
      ' you made in Culling Bay for this day' + (queued ? ', and takes the ' + queued + ' waiting for Lightroom back out of the inbox' : '') +
      '. Flags and stars you set in Lightroom aren’t touched. This can’t be undone.</p>' +
      '<div class="sh-row"><button class="pb2" data-act="close-sheet">Cancel</button><button class="pb2 danger" data-act="reset-do">Start over</button></div>') + '</div>';
  el.hidden = false;
  S.sheet = true;
}
async function resetDo(btn) {
  btn.disabled = true;
  clearTimeout(progressT);                          // a position save still pending would bring the day back
  if (!await drained()) { btn.disabled = false; return toast(stillOffline('Try again once they are in.')); }   // taps must land first
  const day = S.day.day;
  let body;
  try { body = await writeNow('/m/api/day/' + dayPath(day) + '/reset', {}); }
  catch (e) { btn.disabled = false; closeSheet(); return toast('Not reset: ' + e.message); }
  closeSheet();
  S.hist = []; S.hists.delete(day);                 // the day's taps are gone, so is their Undo
  await openDay(day);
  toast('Started over: cleared ' + body.cleared + (body.withdrawn ? ', took ' + body.withdrawn + ' back out of the inbox' : ''));
}

const isBurst = () => { const s = S.stacks[S.cursor]; return !!s && s.frames.length > 1; };
// openPicker, as the iPhone's CullPickerModel: Choose and P open a burst on its sharpest frame
// (the stack's lead; the strip shows the rest), Enter, B and a number key on the frame the card
// shows, and the focus check's Keep on the frame in focus (`at`, a frame id). A burst not yet
// decided opens with nothing ticked; coming back to a decided one, its kept frames start ticked,
// with their stars. Opening it decides nothing.
function openPicker(fromStart, at) {
  const s = S.stacks[S.cursor];
  if (!s || s.frames.length < 2) return;
  const picked = s.frames.filter(f => isPick(S.dec[f.id])), rate = {};
  for (const f of picked) if (S.dec[f.id].stars > 0) rate[f.id] = S.dec[f.id].stars;
  const open = at != null ? at : fromStart ? s.lead : shown(s).id;
  S.picker = { sel: new Set(picked.map(f => f.id)), view: Math.max(0, s.frames.findIndex(f => f.id === open)), rate };
  S.screen = 'picker';
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
      const h = $('#year-' + CSS.escape(y)); if (h) h.scrollIntoView({ block: 'start' });
      return;
    }
    case 'day-view': S.dayView = b.dataset.v; store('cbm-dayview', S.dayView); S.daysScroll = 0; return draw();
    case 'days': return showDays();
    case 'choose': return openPicker(true);
    case 'star': {
      const n = +b.dataset.n;
      if (S.screen === 'picker') return rateFrame(n);
      return decide('keep', n);
    }
    case 'keep': case 'reject':
      if (S.screen === 'focus') {   // on a burst, Keep opens the picker on the frame in focus
        const at = S.focus.id;
        S.focus = null; S.screen = 'cull';
        return a === 'keep' && isBurst() ? openPicker(false, at) : decide(a);
      }
      return decide(a);
    case 'keep-all': return decide('all');
    case 'undo': return undo();
    case 'toggle-af':
      S.showAF = !S.showAF; store('cbm-show-af', S.showAF);
      document.documentElement.classList.toggle('hide-af', !S.showAF);
      document.querySelectorAll('.af-tgl').forEach(x => x.setAttribute('aria-pressed', S.showAF));
      return toast(S.showAF ? 'Showing the camera’s AF point' : 'AF point hidden');
    case 'close-sheet': return closeSheet();
    case 'close-focus': return closeFocus();
    case 'grid':                       // the toggle: into the grid, and back to where you were
      if (S.screen === 'grid') { S.screen = S.gridFrom || 'cull'; S.gridFrom = null; }
      else { S.gridFrom = S.screen; S.screen = 'grid'; }
      return draw();
    case 'grid-filter': S.gridFilter = b.dataset.f; return draw();
    case 'film-jump': S.cursor = +b.dataset.stack; S.screen = 'cull'; saveProgress(); return draw();
    case 'rail-focus': { const f = frameById(+b.dataset.id), sp = railSpot(f); return openFocus(f.id, sp[0], sp[1]); }
    case 'keys': return showKeys();
    case 'grid-open': S.cursor = +b.dataset.stack; S.gridFrom = null; S.screen = 'cull'; return draw();
    case 'reset-ask': return resetAsk();
    case 'reset-do': return resetDo(b);
    case 'picker': return openPicker();
    case 'close-picker': S.picker = null; S.screen = 'cull'; return draw();
    case 'view': return stripView(+b.dataset.i);
    case 'tick': { const f = s.frames[S.picker.view]; selectFrame(f.id, !S.picker.sel.has(f.id)); return draw(); }
    case 'pk-keep': return savePicker(s);
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
    case 'lost-ok': localStorage.removeItem(LOST); return showNet();
    case 'send-all': return openSendAll();
    case 'sa-tick': { const A = S.sendAll, d = b.dataset.day; if (A.sel.has(d)) A.sel.delete(d); else A.sel.add(d); return drawSendAll(); }
    case 'sa-all': {
      const A = S.sendAll, all = A.finished.concat(A.unfinished).map(x => x.d.day);
      A.sel = new Set(A.sel.size === all.length ? [] : all);
      return drawSendAll();
    }
    case 'sa-send': return sendAll();
  }
});
document.addEventListener('input', e => {
  if (e.target.id !== 'day-search') return;
  S.daySearch = e.target.value;
  S.like = null;
  runSearch();
});
document.addEventListener('keydown', onKey);

function route() {
  const m = location.hash.match(/^#\/day\/(.+)$/);
  let day = null;
  try { day = m && decodeURIComponent(m[1]); } catch (_) { day = null; }   // a malformed % shows the days
  if (day) openDay(day); else showDays();
}
window.addEventListener('popstate', route);
route();
pump();
})();
