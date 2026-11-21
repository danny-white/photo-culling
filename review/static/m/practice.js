/* Culling Bay Practice: browse hand-written editing challenges and track their progress. */
'use strict';

(() => {
const $ = (s, el = document) => el.querySelector(s);
const main = $('#practice');
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const img = (id, size) => '/m/api/img/' + id + '?s=' + size;
const exportUrl = id => '/m/api/export/' + id + '?s=original';
const S = { challenges: [], missing: 0, error: '', drafts: Object.create(null), preview: '' };
const byId = id => S.challenges.find(c => c.id === id);

function hashId() {
  const raw = location.hash.replace(/^#/, '');
  if (!raw) return '';
  try { return decodeURIComponent(raw); } catch { return raw; }
}
function navigate(id) { location.hash = id ? encodeURIComponent(id) : ''; }
function dateLabel(value) {
  if (!value) return '';
  const d = new Date(value.length === 10 ? value + 'T12:00:00' : value);
  return Number.isNaN(d.getTime()) ? value : d.toLocaleDateString([], {year:'numeric', month:'short', day:'numeric'});
}
function sizeLabel(bytes) {
  if (!bytes) return '';
  const mb = bytes / 1000000;
  return (mb >= 10 ? Math.round(mb) : mb.toFixed(1)) + ' MB';
}
function whenPlace(p) { return [dateLabel(p.date || p.day), p.place].filter(Boolean).join(' · '); }

async function load() {
  main.innerHTML = '<p class="p-note">Loading challenges…</p>';
  try {
    const r = await fetch('/m/api/practice', {cache:'no-store'});
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || 'HTTP ' + r.status);
    S.challenges = body.challenges || [];
    S.missing = body.missing || 0;
    S.error = body.error || '';
    render();
  } catch (e) {
    S.error = 'Couldn’t load challenges: ' + e.message;
    main.innerHTML = '<p class="p-error" role="alert">' + esc(S.error) + '</p><button class="p-button" data-action="retry">Try again</button>';
  }
}

function errorHTML() {
  return S.error ? '<p class="p-error" role="status">' + esc(S.error) + '</p>' : '';
}
function challengeCard(c) {
  const p = c.photo;
  const downloaded = c.downloaded_at ? '<span class="p-tag">Downloaded</span>' : '';
  return '<a class="challenge-card" href="#' + esc(encodeURIComponent(c.id)) + '">' +
    '<img class="challenge-thumb" src="' + esc(img(p.id, 'thumb')) + '" loading="lazy" alt="">' +
    '<span class="challenge-copy"><span class="challenge-top"><b>' + esc(c.title) + '</b>' + downloaded + '</span>' +
    '<span class="challenge-meta"><span class="p-level level-' + esc(c.level) + '">' + esc(c.level) + '</span> · ~' +
    esc(c.minutes) + ' min · ' + (c.mode === 'phone' ? 'iPhone' : 'Mac') + '</span>' +
    '<span class="p-chips">' + (c.tools || []).map(t => '<span class="p-chip">' + esc(t) + '</span>').join('') + '</span></span></a>';
}
function section(title, items, kind, collapsedWhenLong = false) {
  if (!items.length) return '';
  const cards = items.map(challengeCard).join('');
  if (collapsedWhenLong) {
    const open = items.length <= 3 ? ' open' : '';
    return '<details class="challenge-section"' + open + '><summary>' + esc(title) + ' <span>' + items.length + '</span></summary>' +
      '<div class="challenge-list">' + cards + '</div></details>';
  }
  return '<section class="challenge-section"><h2>' + esc(title) + ' <span>' + items.length + '</span></h2><div class="challenge-list">' + cards + '</div></section>';
}
function listView() {
  const waiting = S.challenges.filter(c => c.status === 'todo' || c.status === 'downloaded');
  const done = S.challenges.filter(c => c.status === 'done');
  const skipped = S.challenges.filter(c => c.status === 'skipped');
  return '<div class="practice-list">' + errorHTML() +
    (S.missing ? '<p class="p-note">' + S.missing + ' challenge photo' + (S.missing === 1 ? ' is' : 's are') + ' no longer in the library.</p>' : '') +
    section('Waiting', waiting, 'waiting') + section('Done', done, 'done', true) + section('Skipped', skipped, 'skipped', true) +
    (!S.challenges.length ? '<p class="p-note">No practice challenges yet.</p>' : '') + '</div>';
}
function detailView(c) {
  const p = c.photo;
  const downloaded = c.downloaded_at ? '<span class="p-tag">Downloaded</span>' : '';
  const notes = Object.prototype.hasOwnProperty.call(S.drafts, c.id) ? S.drafts[c.id] : c.note;
  const hintList = (c.hints || []).length ? '<details class="p-hints"><summary>Show hints</summary><ul>' +
    c.hints.map(h => '<li>' + esc(h) + '</li>').join('') + '</ul></details>' : '';
  let actions;
  if (c.status === 'done') {
    actions = '<div class="p-done"><b>Done' + (c.done_at ? ' · ' + esc(dateLabel(c.done_at)) : '') + '</b>' +
      '<button class="p-button" data-action="undo-done">Undo</button></div>';
  } else {
    actions = '<div class="p-actions"><button class="p-button p-primary" data-action="done">Mark done</button>' +
      (c.status === 'skipped' ? '<button class="p-button" data-action="unskip">Move to waiting</button>' : '<button class="p-button" data-action="skip">Skip</button>') +
      '</div>';
  }
  const downloadText = (p.raw ? 'Download RAW' : 'Download original') + (sizeLabel(p.bytes) ? ' · ' + sizeLabel(p.bytes) : '');
  return '<article class="practice-detail" data-cid="' + esc(c.id) + '">' + errorHTML() +
    '<a class="p-list-back" href="/m/practice.html">‹ Challenges</a>' +
    '<button class="p-photo-open" type="button" data-action="preview" aria-label="View photo full screen">' +
    '<img class="p-detail-photo" src="' + esc(img(p.id, 'view')) + '" alt="Challenge photo"></button>' +
    '<div class="p-titleline"><div><h2>' + esc(c.title) + '</h2><p class="p-meta">' + esc(whenPlace(p)) + '</p><p class="p-meta">' + esc(p.camera || 'Camera not recorded') + '</p></div>' + downloaded + '</div>' +
    '<section class="p-brief"><h3>The challenge</h3><b>Only use:</b><ul class="p-tools">' + (c.tools || []).map(t => '<li>' + esc(t) + '</li>').join('') + '</ul>' +
    '<h3>Aim for:</h3><p>' + esc(c.aim) + '</p><h3>Why this photo:</h3><p>' + esc(c.why) + '</p>' + hintList + '</section>' +
    '<a class="p-download" href="' + esc(exportUrl(p.id)) + '" download data-action="download">' + esc(downloadText) + '</a>' +
    '<ol class="p-howto"><li>Safari asks to download: tap <b>Download</b>. It goes to Files › Downloads.</li>' +
    '<li>In Lightroom, tap the add-photos button, choose Files, and pick the file.</li>' +
    '<li>Edit with only the tools above, then come back and mark it done.</li></ol>' +
    '<label class="p-note-label" for="practice-note">How did it go?</label><textarea id="practice-note" maxlength="2000" placeholder="Add a short note…">' + esc(notes) + '</textarea>' +
    actions + '</article>';
}
function render() {
  const cid = hashId();
  if (cid) {
    const c = byId(cid);
    main.innerHTML = c ? detailView(c) : '<div class="practice-list">' + errorHTML() + '<p class="p-note">Challenge not found.</p><a class="p-button" href="/m/practice.html">Back to challenges</a></div>';
  } else {
    main.innerHTML = listView();
  }
}

async function updateState(c, status, includeNote = false) {
  const note = includeNote ? ($('#practice-note')?.value ?? S.drafts[c.id] ?? c.note) : undefined;
  if (includeNote) S.drafts[c.id] = note;
  const body = {};
  if (status) body.status = status;
  if (includeNote) body.note = note;
  try {
    const r = await fetch('/m/api/practice/' + encodeURIComponent(c.id), {
      method:'POST', headers:{'Content-Type':'application/json','X-Culling-Bay':'1'}, body:JSON.stringify(body)
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.error || 'HTTP ' + r.status);
    c.status = data.status; c.note = data.note; c.updated_at = data.updated_at;
    c.downloaded_at = data.downloaded_at; c.done_at = data.done_at;
    if (includeNote && S.drafts[c.id] === note) delete S.drafts[c.id];
    S.error = '';
    const y = window.scrollY;
    render();
    window.scrollTo(0, y);
  } catch (e) {
    S.error = 'Not saved: ' + e.message + ' · Your note is still here.';
    const node = $('.p-error', main);
    if (node) node.textContent = S.error;
    else {
      const detail = $('.practice-detail', main);
      if (detail) detail.insertAdjacentHTML('afterbegin', errorHTML());
      else main.insertAdjacentHTML('afterbegin', errorHTML());
    }
  }
}

main.addEventListener('click', e => {
  const action = e.target.closest('[data-action]')?.dataset.action;
  if (!action) return;
  if (action === 'retry') { load(); return; }
  const c = byId(hashId());
  if (!c) return;
  if (action === 'download') {
    // Do not prevent the anchor's normal Safari download. State tracking happens separately.
    updateState(c, 'downloaded');
  } else if (action === 'done') updateState(c, 'done', true);
  else if (action === 'skip') updateState(c, 'skipped');
  else if (action === 'unskip') updateState(c, c.downloaded_at ? 'downloaded' : 'todo');
  else if (action === 'undo-done') updateState(c, c.downloaded_at ? 'downloaded' : 'todo');
  else if (action === 'preview') openPreview(c);
});
main.addEventListener('input', e => {
  if (e.target.id === 'practice-note') S.drafts[hashId()] = e.target.value;
});
main.addEventListener('focusout', e => {
  if (e.target.id !== 'practice-note') return;
  const c = byId(hashId());
  if (c && c.status === 'done') updateState(c, null, true);
});

function openPreview(c) {
  const p = $('#preview');
  S.preview = img(c.photo.id, 'view');
  $('img', p).src = S.preview;
  p.hidden = false;
}
function closePreview() { $('#preview').hidden = true; S.preview = ''; }
$('#preview').addEventListener('click', e => { if (e.target.id === 'preview' || e.target.closest('.preview-close')) closePreview(); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') closePreview(); });
window.addEventListener('hashchange', () => { closePreview(); render(); });
load();
})();
