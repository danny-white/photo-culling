/* Culling Bay Gallery: search the library and show photos on the phone. Read-only: nothing here
   changes a cull decision. Routes live in the hash so Back works:
     #/            recent days and On this day
     #/q/<query>   photos for a search, best match first   (/m/api/gallery/search)
     #/day/<day>   one day in time order                   (/m/api/gallery/day/<day>)
     #/like/<id>   photos like one photo                   (/m/api/gallery/like/<id>)
   The viewer is an overlay with its own history entry, so Back closes it. */
'use strict';

const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const img = (id, size) => '/m/api/img/' + id + '?s=' + size;
const exportUrl = (id, extra) => '/m/api/export/' + id + (extra ? '?' + extra : '');
const PAGE = 120;

const S = {
  route: { kind: 'home' },
  photos: [], shown: 0, note: '',
  days: null, homeShown: 30,
  best: load('gallery.best', false), bursts: load('gallery.bursts', true),
  select: false, sel: new Set(),
  v: null,   // the viewer: {i, s, tx, ty, base, hd}
};

function load(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : v === '1'; } catch { return d; } }
function store(k, v) { try { localStorage.setItem(k, v ? '1' : '0'); } catch { /* private mode */ } }

async function getJSON(url) {
  const r = await fetch(url, { cache: 'no-store' });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || 'HTTP ' + r.status);
  return body;
}

let toastT = 0;
function toast(msg, ms = 2200) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('on');
  clearTimeout(toastT);
  toastT = setTimeout(() => t.classList.remove('on'), ms);
}

/* ---------------------------------------------------------------- dates */
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
function isoParts(iso) { const [y, m, d] = iso.split('-').map(Number); return { y, m, d, wd: new Date(y, m - 1, d).getDay() }; }
function longDate(iso) { if (!iso) return 'Undated'; const p = isoParts(iso); return `${WEEKDAYS[p.wd]}, ${MONTHS[p.m - 1]} ${p.d} ${p.y}`; }
function shortDate(iso) { if (!iso) return ''; const p = isoParts(iso); return `${MONTHS[p.m - 1]} ${p.d} ’${String(p.y).slice(2)}`; }
function timeOf(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}
const mb = b => b ? (b / 1e6 >= 10 ? Math.round(b / 1e6) : (b / 1e6).toFixed(1)) + ' MB' : '';
const town = p => (p || '').split(',')[0].replace(/\b\w/g, c => c.toUpperCase());

/* ---------------------------------------------------------------- routing */
function parseHash() {
  const h = location.hash.replace(/^#\/?/, '');
  const [kind, ...rest] = h.split('/');
  const arg = decodeURIComponent(rest.join('/'));
  if (kind === 'q' && arg) return { kind, arg };
  if (kind === 'day' && arg) return { kind, arg };
  if (kind === 'like' && arg) return { kind, arg };
  return { kind: 'home' };
}
function go(kind, arg) {
  if (history.state && history.state.v) history.replaceState(null, '');
  location.hash = kind === 'home' ? '#/' : '#/' + kind + '/' + encodeURIComponent(arg);
}

let routeSeq = 0;
async function route() {
  closeViewer(false);
  closeSheet();
  setSelect(false);
  S.route = parseHash();
  const r = S.route, seq = ++routeSeq;
  $('#back').hidden = r.kind === 'home';
  $('#filters').hidden = r.kind === 'home';
  $('#q').value = r.kind === 'q' ? r.arg : '';
  $('#q-clear').hidden = !$('#q').value;
  $('#f-best').setAttribute('aria-pressed', S.best);
  $('#f-bursts').setAttribute('aria-pressed', S.bursts);
  window.scrollTo(0, 0);
  if (r.kind === 'home') return renderHome(seq);
  setTitle(r.kind === 'q' ? '“' + r.arg + '”' : r.kind === 'like' ? 'Similar photos' : longDate(r.arg.split('/').pop()), 'Loading…');
  $('#main').innerHTML = '<div class="empty">Loading…</div>';
  const flags = 'best=' + (S.best ? 1 : 0) + '&bursts=' + (S.bursts ? 1 : 0);
  const perfT = performance.now();
  let body;
  try {
    if (r.kind === 'q') body = await getJSON('/m/api/gallery/search?q=' + encodeURIComponent(r.arg) + '&' + flags);
    else if (r.kind === 'like') body = await getJSON('/m/api/gallery/like/' + encodeURIComponent(r.arg) + '?' + flags);
    else body = await getJSON('/m/api/gallery/day/' + r.arg.split('/').map(encodeURIComponent).join('/') + '?' + flags);
  } catch (e) {
    if (seq !== routeSeq) return;
    setTitle($('#title').firstChild?.textContent || '', '');
    $('#main').innerHTML = '<div class="empty">Couldn’t load that: ' + esc(e.message) + '</div>';
    return;
  }
  if (seq !== routeSeq) return;
  S.photos = body.photos || [];
  S.shown = 0;
  const n = S.photos.length;
  const count = n + ' photo' + (n === 1 ? '' : 's') + (S.best ? ' · best only' : '');
  if (r.kind === 'day') {
    const first = S.photos.find(p => p.place);
    setTitle(longDate(body.date), [first && town(first.place), count, body.summary].filter(Boolean).join(' · '));
  } else {
    const more = body.total > n && !S.best && !S.bursts ? ` (top ${n} of ${body.total})` : '';
    setTitle($('#title').firstChild.textContent, count + more);
  }
  S.note = (body.notes || []).join(' ');
  renderGrid();
  const firstImg = document.querySelector('#grid .tile img');
  if (firstImg && window.cbPerf) {
    const done = () => cbPerf.mark('results_ready', performance.now() - perfT, { screen: r.kind, n: S.photos.length });
    if (firstImg.complete && firstImg.naturalWidth) done(); else firstImg.addEventListener('load', done, { once: true });
  }
}

function setTitle(t, sub) { $('#title').innerHTML = esc(t) + (sub ? '<small>' + esc(sub) + '</small>' : ''); }

/* ---------------------------------------------------------------- home */
async function renderHome(seq) {
  const main = $('#main');
  if (!S.days) {
    main.innerHTML = '<div class="empty">Loading…</div>';
    try { S.days = (await getJSON('/m/api/days')).days; }
    catch (e) { if (seq === routeSeq) main.innerHTML = '<div class="empty">Couldn’t load the library: ' + esc(e.message) + '</div>'; return; }
    if (seq !== routeSeq) return;
  }
  const today = new Date();
  const near = d => {   // within two days of today's month and day, in an earlier year
    if (!d.date || !d.thumbs.length) return false;
    const p = isoParts(d.date);
    if (p.y >= today.getFullYear()) return false;
    return Math.abs(new Date(2000, p.m - 1, p.d) - new Date(2000, today.getMonth(), today.getDate())) / 864e5 <= 2;
  };
  const otd = S.days.filter(near);
  let html = '';
  if (otd.length) {
    html += '<h2>On this day</h2><div class="lane">' + otd.map(d =>
      '<button class="ot" data-day="' + esc(d.day) + '"><img loading="lazy" src="' + img(d.thumbs[0], 'thumb') + '" alt="">' +
      '<span>' + isoParts(d.date).y + (d.place ? ' · ' + esc(town(d.place)) : '') + '</span></button>').join('') + '</div>';
  }
  html += '<h2>Recent days</h2>' + S.days.slice(0, S.homeShown).map(dayRow).join('');
  if (S.days.length > S.homeShown) html += '<button class="more" data-act="more-days">Show more days</button>';
  main.innerHTML = html;
}

function dayRow(d) {
  const sub = [d.place && town(d.place), d.frames + ' photos', d.summary].filter(Boolean).join(' · ');
  return '<button class="dayrow" data-day="' + esc(d.day) + '"><span class="tx"><b>' + esc(longDate(d.date)) + '</b><small>' + esc(sub) + '</small></span>' +
    '<span class="th">' + d.thumbs.map(id => '<img loading="lazy" src="' + img(id, 'thumb') + '" alt="">').join('') + '</span></button>';
}

/* ---------------------------------------------------------------- grid */
let pager = null;
function renderGrid() {
  const main = $('#main');
  if (!S.photos.length) {
    const why = S.best ? 'Nothing you picked or rated 3★ or more. Turn off ★ Best to see everything.' : 'No photos found.';
    main.innerHTML = (S.note ? '<div class="note">' + esc(S.note) + '</div>' : '') + '<div class="empty">' + why + '</div>';
    return;
  }
  main.innerHTML = (S.note ? '<div class="note">' + esc(S.note) + '</div>' : '') + '<div class="grid" id="grid"></div><div id="pager"></div>';
  S.shown = 0;
  addTiles();
  if (pager) pager.disconnect();
  pager = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) addTiles(); }, { rootMargin: '800px' });
  pager.observe($('#pager'));
}

function addTiles() {
  const grid = $('#grid');
  if (!grid || S.shown >= S.photos.length) return;
  const across = S.route.kind !== 'day';   // results from many days carry their date
  const html = S.photos.slice(S.shown, S.shown + PAGE).map((p, k) => {
    const i = S.shown + k;
    return '<button class="tile' + (S.sel.has(p.id) ? ' sel' : '') + '" data-i="' + i + '"><img loading="lazy" src="' + img(p.id, 'thumb') + '" alt="">' +
      (across && p.date ? '<span class="d">' + esc(shortDate(p.date)) + '</span>' : '') +
      (p.stars ? '<span class="st">' + '★'.repeat(Math.min(p.stars, 5)) + '</span>' : '') + '</button>';
  }).join('');
  grid.insertAdjacentHTML('beforeend', html);
  S.shown = Math.min(S.photos.length, S.shown + PAGE);
}

/* ---------------------------------------------------------------- selection */
function setSelect(on) {
  S.select = on;
  if (!on) S.sel.clear();
  $('#f-select').setAttribute('aria-pressed', on);
  $('#f-select').textContent = on ? 'Done' : 'Select';
  document.querySelectorAll('.tile.sel').forEach(t => t.classList.toggle('sel', on && S.sel.has(S.photos[+t.dataset.i].id)));
  updateSelbar();
}
function updateSelbar() {
  $('#selbar').hidden = !S.select;
  $('#sel-n').textContent = S.sel.size + ' selected';
  $('#sel-save').disabled = !S.sel.size;
}

/* ---------------------------------------------------------------- saving */
// Over plain http the share sheet with files isn't available, so the usual path is a sheet of
// full-size pictures: press and hold one, Save to Photos. Where files can be shared (https),
// the share sheet comes up directly.
async function save(photos) {
  if (!photos.length) return;
  if (navigator.canShare && window.isSecureContext) {
    try {
      toast('Preparing ' + photos.length + ' full-size photo' + (photos.length > 1 ? 's' : '') + '…', 10000);
      const files = await Promise.all(photos.map(async p => {
        const r = await fetch(exportUrl(p.id));
        if (!r.ok) throw new Error('HTTP ' + r.status);
        const blob = await r.blob();   // a RAW comes back as a JPEG; a JPEG or HEIC as it is
        return new File([blob], p.raw ? p.file.replace(/\.[^.]+$/, '') + '.jpg' : p.file, { type: blob.type || 'image/jpeg' });
      }));
      toast('', 1);
      if (navigator.canShare({ files })) { await navigator.share({ files }); return; }
    } catch (e) {
      if (e.name === 'AbortError') return;
    }
  }
  openSheet(photos);
}

function openSheet(photos) {
  $('#sheet-title').textContent = photos.length > 1 ? 'Save ' + photos.length + ' photos' : 'Save to phone';
  $('#sheet-list').innerHTML = photos.map(p =>
    '<figure><img src="' + exportUrl(p.id) + '" alt="Preparing the full-size picture…">' +
    '<figcaption><span>' + esc(p.file) + ' · ' + esc(shortDate(p.date)) + '</span><span class="dl">' +
    '<a href="' + exportUrl(p.id, 'dl=1') + '" download>' + (p.raw ? 'JPEG' : 'Download') + '</a>' +
    (p.raw ? '<a href="' + exportUrl(p.id, 's=original') + '" download>RAW · ' + esc(mb(p.bytes)) + '</a>' : '') +
    '</span></figcaption></figure>').join('');
  $('#sheet-raw').hidden = !photos.some(p => p.raw);
  $('#sheet').hidden = false;
  const first = $('#sheet-list img'), perfT = performance.now();
  if (first && window.cbPerf) first.addEventListener('load', () =>
    cbPerf.mark('save_ready', performance.now() - perfT, { name: first.getAttribute('src'), n: photos.length }), { once: true });
}
function closeSheet() { $('#sheet').hidden = true; $('#sheet-list').innerHTML = ''; }

/* ---------------------------------------------------------------- viewer */
const viewer = $('#viewer'), stage = $('#stage'), vimg = $('#vimg');

function openViewer(i) {
  S.v = { i, s: 1, tx: 0, ty: 0, base: null, hd: false };
  viewer.hidden = false;
  viewer.classList.remove('bare');
  document.body.style.overflow = 'hidden';
  if (!(history.state && history.state.v)) history.pushState({ v: 1 }, '');
  show(i);
}

function closeViewer(viaHistory) {
  if (!S.v) return;
  S.v = null;
  viewer.hidden = true;
  document.body.style.overflow = '';
  vimg.removeAttribute('src');
  if (viaHistory && history.state && history.state.v) history.back();
}

function show(i) {
  const v = S.v, p = S.photos[i];
  if (!v || !p) return;
  v.i = i; v.s = 1; v.tx = 0; v.ty = 0; v.hd = false;
  $('#v-hd').hidden = true;
  vimg.style.transition = 'none';
  vimg.style.opacity = '1';
  applyTransform();
  const perfT = performance.now();
  vimg.onload = () => {
    if (!S.v || S.v.i !== i) return;
    fit();
    if (window.cbPerf) cbPerf.mark('viewer_photo', performance.now() - perfT, { name: img(p.id, 'view') });
  };
  vimg.src = img(p.id, 'view');
  $('#v-count').textContent = (i + 1) + ' / ' + S.photos.length;
  $('#v-when').textContent = [longDate(p.date), timeOf(p.ts)].filter(Boolean).join(' · ');
  $('#v-where').textContent = [town(p.place), p.camera, p.stars ? '★'.repeat(Math.min(p.stars, 5)) : ''].filter(Boolean).join(' · ');
  $('#v-cap').textContent = p.caption || '';
  $('#v-day').hidden = S.route.kind === 'day';
  for (const j of [i + 1, i - 1]) if (S.photos[j]) new Image().src = img(S.photos[j].id, 'view');
}

// The image is sized to fit the screen in its own shape, so zoom and pan work on the picture
// itself rather than on letterbox bars.
function fit() {
  const v = S.v;
  if (!v || !vimg.naturalWidth) return;
  const W = stage.clientWidth, H = stage.clientHeight, ar = vimg.naturalWidth / vimg.naturalHeight;
  const w = Math.min(W, H * ar), h = w / ar;
  vimg.style.width = w + 'px';
  vimg.style.height = h + 'px';
  v.base = { left: (W - w) / 2, top: (H - h) / 2, w, h, W, H };
}

function applyTransform() {
  const v = S.v;
  if (!v) return;
  vimg.style.transform = `translate(${v.tx}px, ${v.ty}px) scale(${v.s})`;
}

function clampPan() {
  const v = S.v, b = v.base;
  if (!b) return;
  const w = b.w * v.s, h = b.h * v.s;
  v.tx = w <= b.W ? (b.W - w) / 2 - b.left : Math.min(-b.left, Math.max(b.W - w - b.left, v.tx));
  v.ty = h <= b.H ? (b.H - h) / 2 - b.top : Math.min(-b.top, Math.max(b.H - h - b.top, v.ty));
}

function zoomAt(s, x, y, from) {   // keep the point (x, y) on screen under the finger
  const v = S.v, b = v.base;
  if (!b) return;
  const f = from || v;
  const lx = (x - b.left - f.tx) / f.s, ly = (y - b.top - f.ty) / f.s;
  v.s = Math.min(6, Math.max(1, s));
  v.tx = x - b.left - lx * v.s;
  v.ty = y - b.top - ly * v.s;
  if (v.s === 1) { v.tx = 0; v.ty = 0; } else clampPan();
  applyTransform();
  if (v.s > 1.6 && !v.hd) loadHD();
}

function loadHD() {   // the 3000-px picture, decoded from the original, when you zoom in
  const v = S.v, p = S.photos[v.i];
  v.hd = true;
  $('#v-hd').hidden = false;
  const hi = new Image(), perfT = performance.now();
  hi.onload = () => {
    if (window.cbPerf) cbPerf.mark('viewer_hd', performance.now() - perfT, { name: exportUrl(p.id, 's=large') });
    if (!S.v || S.photos[S.v.i] !== p) return;
    vimg.onload = null;
    vimg.src = hi.src;
    $('#v-hd').hidden = true;
  };
  hi.onerror = () => { $('#v-hd').hidden = true; };
  hi.src = exportUrl(p.id, 's=large');
}

function step(d) {
  const v = S.v, j = v.i + d;
  if (j < 0 || j >= S.photos.length) { snapBack(); return; }
  const b = v.base, out = d > 0 ? -(b ? b.W : 400) : (b ? b.W : 400);
  vimg.style.transition = 'transform .16s ease-out';
  v.tx = out; applyTransform();
  setTimeout(() => { if (S.v) show(j); }, 160);
}
function snapBack() {
  const v = S.v;
  vimg.style.transition = 'transform .16s ease-out, opacity .16s';
  vimg.style.opacity = '1';
  if (v.s === 1) { v.tx = 0; v.ty = 0; } else clampPan();
  applyTransform();
}

// Gestures: one finger swipes between photos (or pans when zoomed) and swipes down to close;
// two fingers pinch; a double tap zooms; a single tap hides everything but the photo.
const pts = new Map();
let g = null, lastTap = null, tapT = 0;

stage.addEventListener('pointerdown', e => {
  if (!S.v) return;
  stage.setPointerCapture(e.pointerId);
  pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
  vimg.style.transition = 'none';
  const v = S.v;
  if (pts.size === 2) {
    const [a, b] = [...pts.values()];
    g = { kind: 'pinch', d0: Math.hypot(a.x - b.x, a.y - b.y) || 1, from: { s: v.s, tx: v.tx, ty: v.ty },
          mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2 };
  } else if (pts.size === 1) {
    g = { kind: 'one', x0: e.clientX, y0: e.clientY, t0: Date.now(), tx0: v.tx, ty0: v.ty, axis: null, moved: false };
  }
});

stage.addEventListener('pointermove', e => {
  if (!S.v || !pts.has(e.pointerId) || !g) return;
  pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
  const v = S.v;
  if (g.kind === 'pinch' && pts.size >= 2) {
    const [a, b] = [...pts.values()];
    const d = Math.hypot(a.x - b.x, a.y - b.y), mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
    zoomAt(g.from.s * d / g.d0, g.mx, g.my, g.from);
    v.tx += mx - g.mx; v.ty += my - g.my;   // the pinch also drags
    if (v.s > 1) clampPan();
    applyTransform();
    return;
  }
  if (g.kind !== 'one') return;
  const dx = e.clientX - g.x0, dy = e.clientY - g.y0;
  if (Math.hypot(dx, dy) > 8) g.moved = true;
  if (v.s > 1) { v.tx = g.tx0 + dx; v.ty = g.ty0 + dy; clampPan(); applyTransform(); return; }
  if (!g.axis && g.moved) g.axis = Math.abs(dx) > Math.abs(dy) ? 'x' : 'y';
  if (g.axis === 'x') { v.tx = dx; applyTransform(); }
  else if (g.axis === 'y' && dy > 0) {
    v.ty = dy; applyTransform();
    vimg.style.opacity = String(Math.max(0.3, 1 - dy / 500));
  }
});

function endPointer(e) {
  if (!pts.has(e.pointerId)) return;
  pts.delete(e.pointerId);
  if (!S.v || !g) return;
  const v = S.v;
  if (g.kind === 'pinch') {
    if (pts.size === 0) { g = null; if (v.s < 1.05) { v.s = 1; snapBack(); } }
    else if (pts.size === 1) {   // one finger left: carry on as a pan
      const [p] = [...pts.values()];
      g = { kind: 'one', x0: p.x, y0: p.y, t0: Date.now(), tx0: v.tx, ty0: v.ty, axis: null, moved: true };
    }
    return;
  }
  const dx = e.clientX - g.x0, dy = e.clientY - g.y0, quick = Date.now() - g.t0 < 300;
  const kind = g.axis;
  const moved = g.moved;
  g = null;
  if (!moved && quick) return tap(e.clientX, e.clientY);
  if (v.s > 1) return;
  if (kind === 'x' && Math.abs(dx) > 60) return step(dx < 0 ? 1 : -1);
  if (kind === 'y' && dy > 110) return closeViewer(true);
  snapBack();
}
stage.addEventListener('pointerup', endPointer);
stage.addEventListener('pointercancel', endPointer);

function tap(x, y) {
  const now = Date.now();
  if (lastTap && now - lastTap.t < 280 && Math.hypot(x - lastTap.x, y - lastTap.y) < 30) {
    clearTimeout(tapT);
    lastTap = null;
    vimg.style.transition = 'transform .2s ease-out';
    if (S.v.s > 1) { S.v.s = 1; S.v.tx = 0; S.v.ty = 0; applyTransform(); }
    else zoomAt(2.5, x, y);
    return;
  }
  lastTap = { t: now, x, y };
  tapT = setTimeout(() => { lastTap = null; viewer.classList.toggle('bare'); }, 280);
}

window.addEventListener('resize', () => { if (S.v) { fit(); S.v.s = 1; S.v.tx = 0; S.v.ty = 0; applyTransform(); } });
document.addEventListener('keydown', e => {
  if (!S.v) { if (e.key === 'Escape') closeSheet(); return; }
  if (e.key === 'ArrowRight') step(1);
  else if (e.key === 'ArrowLeft') step(-1);
  else if (e.key === 'Escape') closeViewer(true);
});

/* ---------------------------------------------------------------- wiring */
$('#search-form').addEventListener('submit', e => {
  e.preventDefault();
  const q = $('#q').value.trim();
  $('#q').blur();
  if (q) go('q', q); else go('home');
});
$('#q').addEventListener('input', () => { $('#q-clear').hidden = !$('#q').value; });
$('#q-clear').addEventListener('click', () => { $('#q').value = ''; $('#q-clear').hidden = true; $('#q').focus(); });
$('#back').addEventListener('click', () => { if (history.length > 1) history.back(); else go('home'); });
$('#f-best').addEventListener('click', () => { S.best = !S.best; store('gallery.best', S.best); route(); });
$('#f-bursts').addEventListener('click', () => { S.bursts = !S.bursts; store('gallery.bursts', S.bursts); route(); });
$('#f-select').addEventListener('click', () => setSelect(!S.select));
$('#sel-clear').addEventListener('click', () => { S.sel.clear(); document.querySelectorAll('.tile.sel').forEach(t => t.classList.remove('sel')); updateSelbar(); });
$('#sel-save').addEventListener('click', () => save(S.photos.filter(p => S.sel.has(p.id))));

$('#main').addEventListener('click', e => {
  const t = e.target.closest('[data-i],[data-day],[data-act]');
  if (!t) return;
  if (t.dataset.act === 'more-days') { S.homeShown += 60; renderHome(routeSeq); return; }
  if (t.dataset.day) { go('day', t.dataset.day); return; }
  const i = +t.dataset.i, p = S.photos[i];
  if (S.select) {
    if (S.sel.has(p.id)) S.sel.delete(p.id); else S.sel.add(p.id);
    t.classList.toggle('sel', S.sel.has(p.id));
    updateSelbar();
    return;
  }
  openViewer(i);
});

$('#v-close').addEventListener('click', () => closeViewer(true));
$('#v-save').addEventListener('click', () => save([S.photos[S.v.i]]));
$('#v-like').addEventListener('click', () => { const p = S.photos[S.v.i]; go('like', String(p.id)); });
$('#v-day').addEventListener('click', () => { const p = S.photos[S.v.i]; if (p.day) go('day', p.day); });
$('#sheet-close').addEventListener('click', closeSheet);
$('#sheet').addEventListener('click', e => { if (e.target.id === 'sheet') closeSheet(); });

window.addEventListener('popstate', () => { if (S.v && !(history.state && history.state.v)) closeViewer(false); });
window.addEventListener('hashchange', route);
route();
