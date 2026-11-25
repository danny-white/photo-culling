/* Culling Bay Gallery: search the library and show photos, on a computer. Read-only: nothing here
   changes a cull decision. Routes live in the hash so Back works:
     #/            recent days and On this day
     #/q/<query>   photos for a search, best match first   (/m/api/gallery/search)
     #/day/<day>   one day in time order                   (/m/api/gallery/day/<day>)
     #/like/<id>   photos like one photo                   (/m/api/gallery/like/<id>)
   The viewer is an overlay with its own history entry, so Back closes it. */
'use strict';
(() => {
if (window.cbPhone) return;   // a phone gets desktop.js's page pointing to the app

const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const img = (id, size) => '/m/api/img/' + id + '?s=' + size;
const exportUrl = (id, extra) => '/m/api/export/' + id + (extra ? '?' + extra : '');
const PAGE = 120;

const S = {
  route: { kind: 'home' },
  photos: [], shown: 0, note: '',
  days: null, open: loadOpen(),   // open: {years: Set, months: Set} on the home page
  best: load('gallery.best', false), bursts: load('gallery.bursts', true),
  select: false, sel: new Set(),
  v: null,   // the viewer: {i, s, tx, ty, base, hd}
};

function loadOpen() {
  try {
    const o = JSON.parse(localStorage.getItem('gallery.open') || 'null');
    if (o) return { years: new Set(o.years), months: new Set(o.months), set: true };
  } catch { /* private mode */ }
  return { years: new Set(), months: new Set(), set: false };
}
function storeOpen() {
  try { localStorage.setItem('gallery.open', JSON.stringify({ years: [...S.open.years], months: [...S.open.months] })); } catch { /* private mode */ }
}
function load(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : v === '1'; } catch { return d; } }
function store(k, v) { try { localStorage.setItem(k, v ? '1' : '0'); } catch { /* private mode */ } }

async function getJSON(url) {
  const r = await fetch(url, { cache: 'no-cache' });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || 'HTTP ' + r.status);
  return body;
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
  let arg;
  try { arg = decodeURIComponent(rest.join('/')); } catch { return { kind: 'home' }; }   // a malformed %
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
  $('#yearbar').hidden = r.kind !== 'home';
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
/* ---------------------------------------------------------------- home: years, months, days
   Year pills in the header jump to a year and light up for the year on screen; each pill's bar
   shows how many photos the year holds. Years open into months, months into days. A month shows
   a strip of its photos so it can be recognised before it's opened. What's open is remembered. */
const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const yearOf = d => d.date ? d.date.slice(0, 4) : 'Undated';
const monthKey = d => d.date ? d.date.slice(0, 7) : 'Undated';
const count = n => n.toLocaleString() + ' photo' + (n === 1 ? '' : 's');

function topTown(days) {   // the town most of these photos were near
  const n = {};
  for (const d of days) if (d.place) n[d.place] = (n[d.place] || 0) + d.frames;
  const best = Object.keys(n).sort((a, b) => n[b] - n[a])[0];
  return best ? town(best) : '';
}

function groupDays(days) {   // [{year, days, months: [{key, days}]}], newest first, as the list comes
  const years = [];
  for (const d of days) {
    let y = years[years.length - 1];
    if (!y || y.year !== yearOf(d)) years.push(y = { year: yearOf(d), days: [], months: [] });
    y.days.push(d);
    let m = y.months[y.months.length - 1];
    if (!m || m.key !== monthKey(d)) y.months.push(m = { key: monthKey(d), days: [] });
    m.days.push(d);
  }
  return years;
}

async function renderHome(seq) {
  const main = $('#main');
  if (!S.days) {
    main.innerHTML = '<div class="empty">Loading…</div>';
    try { S.days = (await getJSON('/m/api/days')).days; }
    catch (e) { if (seq === routeSeq) main.innerHTML = '<div class="empty">Couldn’t load the library: ' + esc(e.message) + '</div>'; return; }
    if (seq !== routeSeq) return;
  }
  const years = groupDays(S.days);
  if (!S.open.set && years.length) {   // first visit: the newest year and its newest month
    S.open.years.add(years[0].year);
    S.open.months.add(years[0].months[0].key);
    S.open.set = true;
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
  html += years.map(yearHTML).join('');
  main.innerHTML = html;
  renderYearbar(years);
  watchYears();
}

function yearHTML(y) {
  const open = S.open.years.has(y.year), photos = y.days.reduce((n, d) => n + d.frames, 0);
  const sub = [y.days.length + ' day' + (y.days.length === 1 ? '' : 's'), count(photos), topTown(y.days)].filter(Boolean).join(' · ');
  return '<section class="yr" id="yr-' + esc(y.year) + '" data-year="' + esc(y.year) + '">' +
    '<button class="yhead" data-act="year" data-k="' + esc(y.year) + '" aria-expanded="' + open + '">' +
    '<b>' + esc(y.year) + '</b><small>' + esc(sub) + '</small><i aria-hidden="true">' + (open ? '−' : '+') + '</i></button>' +
    (open ? y.months.map(monthHTML).join('') : '') + '</section>';
}

function monthHTML(m) {
  const open = S.open.months.has(m.key), photos = m.days.reduce((n, d) => n + d.frames, 0);
  const name = m.key === 'Undated' ? 'Other folders' : MONTH_NAMES[+m.key.slice(5, 7) - 1];
  const sub = [m.days.length + ' day' + (m.days.length === 1 ? '' : 's'), count(photos), topTown(m.days)].filter(Boolean).join(' · ');
  const strip = m.days.flatMap(d => d.thumbs.slice(0, m.days.length > 2 ? 1 : 3)).slice(0, 6);
  return '<div class="mo' + (open ? ' open' : '') + '">' +
    '<button class="mhead" data-act="month" data-k="' + esc(m.key) + '" aria-expanded="' + open + '">' +
    '<span class="mtx"><b>' + esc(name) + '</b><small>' + esc(sub) + '</small></span><i aria-hidden="true">' + (open ? '−' : '+') + '</i></button>' +
    (open ? m.days.map(dayRow).join('')
          : '<button class="mstrip" data-act="month" data-k="' + esc(m.key) + '" tabindex="-1" aria-hidden="true">' +
            strip.map(id => '<img loading="lazy" src="' + img(id, 'thumb') + '" alt="">').join('') + '</button>') +
    '</div>';
}

function toggle(set, key) {
  if (set.has(key)) set.delete(key); else set.add(key);
  storeOpen();
  const y = window.scrollY;
  renderHome(routeSeq).then(() => window.scrollTo(0, y));
}

function renderYearbar(years) {
  const max = Math.max(...years.map(y => y.days.reduce((n, d) => n + d.frames, 0)), 1);
  $('#yearbar').innerHTML = years.map(y => {
    const photos = y.days.reduce((n, d) => n + d.frames, 0);
    const bar = Math.max(8, Math.round(100 * Math.sqrt(photos / max)));   // square root, so small years still show
    return '<button class="ypill" data-year="' + esc(y.year) + '" title="' + esc(count(photos)) + '">' + esc(y.year) +
      '<i style="width:' + bar + '%"></i></button>';
  }).join('');
}

function jumpToYear(year) {
  if (!S.open.years.has(year)) { S.open.years.add(year); storeOpen(); }
  renderHome(routeSeq).then(() => {
    const el = document.getElementById('yr-' + year);
    if (el) window.scrollTo({ top: el.getBoundingClientRect().top + window.scrollY - $('.bar').offsetHeight });
    markYear(year);
  });
}

let yearSpy = null;
function watchYears() {   // light the pill of the year at the top of the screen
  if (yearSpy) yearSpy.disconnect();
  const top = $('.bar').offsetHeight;
  yearSpy = new IntersectionObserver(entries => {
    const on = [...document.querySelectorAll('.yr')].find(sec => sec.getBoundingClientRect().bottom > top + 8);
    if (on) markYear(on.dataset.year);
  }, { rootMargin: `-${top}px 0px 0px 0px`, threshold: [0, 0.01, 1] });
  document.querySelectorAll('.yr').forEach(sec => yearSpy.observe(sec));
}
function markYear(year) {
  const bar = $('#yearbar');
  for (const b of bar.querySelectorAll('.ypill')) {
    const on = b.dataset.year === year;
    if (on && b.getAttribute('aria-current') !== 'true')   // keep the lit pill in view, without moving the page
      bar.scrollTo({ left: b.offsetLeft - bar.clientWidth / 2 + b.offsetWidth / 2 });
    b.setAttribute('aria-current', on);
  }
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
// A sheet of download links: the full-size picture, and the original for a RAW.
const save = photos => { if (photos.length) openSheet(photos); };
// The full-size export preserves HEIC/HEIF originals; label those truthfully too.
const downloadLabel = p => 'Download ' + (/\.(heic|heif)$/i.exec(p.file)?.[1].toUpperCase() || 'JPEG');
function openSheet(photos) {
  $('#sheet-title').textContent = photos.length > 1 ? 'Save ' + photos.length + ' photos' : 'Save photo';
  $('#sheet-list').innerHTML = photos.map(p =>
    '<figure><figcaption><span>' + esc(p.file) + ' · ' + esc(shortDate(p.date)) + '</span><span class="dl">' +
    '<a href="' + exportUrl(p.id, 's=full&dl=1') + '" download>' + downloadLabel(p) + '</a>' +
    (p.raw ? '<a href="' + exportUrl(p.id, 's=original') + '" download>Download RAW · ' + esc(mb(p.bytes)) + '</a>' : '') +
    '</span></figcaption></figure>').join('');
  $('#sheet').hidden = false;
}
function closeSheet() { $('#sheet').hidden = true; $('#sheet-list').innerHTML = ''; }

/* ---------------------------------------------------------------- viewer */
const viewer = $('#viewer'), stage = $('#stage'), vimg = $('#vimg');

function openViewer(i) {
  S.v = { i, s: 1, tx: 0, ty: 0, base: null, hd: false, dir: 1, sharp: false, pre: [] };
  viewer.hidden = false;
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
  // The grid's thumbnail is already here, so it goes up at once (soft, same shape), and
  // the 1616 px view replaces it when it arrives, unless the zoom picture got there first.
  const perfT = performance.now();
  v.sharp = false;
  let first = true;
  vimg.onload = () => {
    if (!S.v || S.v.i !== i) return;
    fit();
    if (first && window.cbPerf) cbPerf.mark('viewer_first', performance.now() - perfT, { name: img(p.id, 'thumb') });
    first = false;
  };
  vimg.src = img(p.id, 'thumb');
  const sharp = new Image();
  sharp.onload = () => {
    const swap = () => {
      if (!S.v || S.v.i !== i || S.v.sharp) return;
      S.v.sharp = true;
      vimg.src = sharp.src;
      if (window.cbPerf) cbPerf.mark('viewer_photo', performance.now() - perfT, { name: img(p.id, 'view') });
    };
    (sharp.decode ? sharp.decode() : Promise.resolve()).then(swap, swap);   // swap once decoded: no flash
  };
  sharp.src = img(p.id, 'view');
  $('#v-count').textContent = (i + 1) + ' / ' + S.photos.length;
  $('#v-when').textContent = [longDate(p.date), timeOf(p.ts)].filter(Boolean).join(' · ');
  $('#v-cap').textContent = p.caption || '';
  viewerDetails();
  $('#v-day').hidden = S.route.kind === 'day';
  // Preload two ahead in the direction you're stepping, and one behind. The Image objects are kept
  // so the requests aren't dropped.
  v.pre = [i + v.dir, i + 2 * v.dir, i - v.dir].filter(j => S.photos[j]).map(j => {
    const im = new Image();
    im.src = img(S.photos[j].id, 'view');
    return im;
  });
}

function viewerDetails() {
  const old = $('.gallery-details'); if (old) old.remove();
  if (!S.v) return;
  const p = S.photos[S.v.i];
  $('#v-where').textContent = '';
  const fields = [['File', p.file], ['Camera', p.camera], ['Lens', p.lens], ['Place', p.place], ['Stars', p.stars ? '★'.repeat(Math.min(p.stars, 5)) : '']];
  $('#v-cap').insertAdjacentHTML('beforebegin', '<dl class="gallery-details">' + fields.filter(([, v]) => v).map(([k, v]) => '<dt>' + k + '</dt><dd>' + esc(v) + '</dd>').join('') + '</dl>');
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

function zoomAt(s, x, y) {   // keep the point (x, y) on screen under the pointer
  const v = S.v, b = v.base;
  if (!b) return;
  const lx = (x - b.left - v.tx) / v.s, ly = (y - b.top - v.ty) / v.s;
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
    S.v.sharp = true;   // nothing smaller replaces it now
    vimg.onload = null;
    vimg.src = hi.src;
    $('#v-hd').hidden = true;
  };
  hi.onerror = () => { $('#v-hd').hidden = true; };
  hi.src = exportUrl(p.id, 's=large');
}

function step(d) {
  const v = S.v, j = v.i + d;
  if (j < 0 || j >= S.photos.length) return;
  v.dir = d > 0 ? 1 : -1;
  show(j);
}

// The mouse: the wheel zooms where the pointer is, and a drag pans a zoomed photo.
let drag = null;
stage.addEventListener('pointerdown', e => {
  if (!S.v || e.button !== 0) return;
  stage.setPointerCapture(e.pointerId);
  vimg.style.transition = 'none';
  drag = { x0: e.clientX, y0: e.clientY, tx0: S.v.tx, ty0: S.v.ty };
});
stage.addEventListener('pointermove', e => {
  const v = S.v;
  if (!v || !drag || v.s <= 1) return;
  v.tx = drag.tx0 + e.clientX - drag.x0; v.ty = drag.ty0 + e.clientY - drag.y0;
  clampPan(); applyTransform();
});
stage.addEventListener('pointerup', () => { drag = null; });
stage.addEventListener('pointercancel', () => { drag = null; });

window.addEventListener('resize', () => { if (S.v) { fit(); S.v.s = 1; S.v.tx = 0; S.v.ty = 0; applyTransform(); } });
stage.addEventListener('wheel', e => {
  if (!S.v) return;
  e.preventDefault(); vimg.style.transition = 'none';
  const r = stage.getBoundingClientRect();
  zoomAt(S.v.s * Math.exp(-e.deltaY * (e.deltaMode === 1 ? .03 : .002)), e.clientX - r.left, e.clientY - r.top);
}, { passive: false });
document.addEventListener('keydown', e => {
  if (e.ctrlKey || e.metaKey || e.altKey || e.target.closest('input, textarea, [contenteditable="true"]')) return;
  if (!$('#sheet').hidden) { if (e.key === 'Escape') { e.preventDefault(); closeSheet(); } return; }
  if (S.v && ['ArrowRight', 'ArrowLeft', 'Escape'].includes(e.key)) e.preventDefault();
  if (!S.v) return;
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
$('#yearbar').addEventListener('click', e => { const b = e.target.closest('.ypill'); if (b) jumpToYear(b.dataset.year); });
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
  if (t.dataset.act === 'year') { toggle(S.open.years, t.dataset.k); return; }
  if (t.dataset.act === 'month') { toggle(S.open.months, t.dataset.k); return; }
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
})();
