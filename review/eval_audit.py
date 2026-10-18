"""Phone review of caption-eval references and grades; writes only separate audit files."""
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from flask import Blueprint, Response, jsonify, request, send_file, url_for

from eval.evalcommon import read_json

FACTUAL = ("caption", "subject", "scene", "people_count", "tags", "activity",
           "indoor_outdoor", "time_of_day", "animals", "visible_text")


def _optional_json(path):
    try:
        return read_json(path)
    except FileNotFoundError:
        return None


def _validate_audit(body, runs):
    if not isinstance(body, dict) or set(body) - {"reference", "corrections", "grades", "note"}:
        return "expected an audit object with reference, corrections, grades and note"
    if body.get("reference") not in ("right", "wrong", "unsure"):
        return "reference must be right, wrong or unsure"
    corrections = body.get("corrections", {})
    if not isinstance(corrections, dict) or set(corrections) - {"caption", "people_count", "activity", "note"}:
        return "invalid corrections object"
    for key, value in corrections.items():
        if key == "people_count":
            if type(value) is not int or value < 0:
                return "corrections.people_count must be a non-negative integer"
        elif not isinstance(value, str):
            return f"corrections.{key} must be text"
    grades = body.get("grades", {})
    if not isinstance(grades, dict):
        return "grades must be an object"
    if any(run not in runs or value not in ("agree", "disagree") for run, value in grades.items()):
        return "grades must name a graded run for this photo and say agree or disagree"
    if not isinstance(body.get("note", ""), str):
        return "note must be text"
    return None


def _save_audit(path, audit):
    """Unique sibling temp files keep concurrent requests and interrupted writes atomic."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=f".{path.stem}-", suffix=".tmp", delete=False) as f:
            tmp = Path(f.name)
            json.dump(audit, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if tmp is not None:
            tmp.unlink(missing_ok=True)


def make_eval_blueprint(eval_dir: Path) -> Blueprint:
    eval_dir = Path(eval_dir)
    bp = Blueprint("eval_audit", __name__, url_prefix="/m/eval")

    def entries():
        return {e["id"]: e for e in (_optional_json(eval_dir / "set.json") or [])}

    def available_runs():
        return sorted(p.name for p in (eval_dir / "grades").glob("*")
                      if p.is_dir() and any(f.stem.isdecimal() for f in p.glob("*.json")))

    def selected_runs():
        available = available_runs()
        query = request.args.get("runs")
        if query is None:
            return available
        runs = list(dict.fromkeys(r.strip() for r in query.split(",")))
        # Match directory names, never turn user-supplied paths into filesystem paths.
        if any(r not in available for r in runs):
            raise ValueError("runs must name existing graded runs")
        return runs

    @bp.after_request
    def fresh_state(response):
        if request.path.startswith("/m/eval/api/"):
            response.headers["Cache-Control"] = "no-store"
        return response

    @bp.get("/")
    def page():
        return Response(PAGE, mimetype="text/html")

    @bp.get("/api/items")
    def items():
        try:
            runs = selected_runs()
        except ValueError as ex:
            return jsonify(error=str(ex)), 400
        if request.args.get("only") not in (None, "priority"):
            return jsonify(error="only must be priority"), 400
        result = []
        for i, entry in entries().items():
            grades = [g for run in runs
                      if (g := _optional_json(eval_dir / "grades" / run / f"{i}.json")) is not None]
            error_flags = {bool(g.get("caption_errors")) for g in grades}
            checks = [
                (any("REF:" in g.get("notes", "") for g in grades), "Grader questioned reference (REF:)"),
                (len(error_flags) > 1, "Runs disagree on caption errors"),
                (True in error_flags, "Caption errors flagged"),
                (any(g.get("people_count_ok") is False for g in grades), "People count flagged"),
            ]
            reasons = [reason for yes, reason in checks if yes]
            if request.args.get("only") == "priority" and not reasons:
                continue
            rank = next((n for n, (yes, _) in enumerate(checks) if yes), len(checks))
            result.append((rank, {"id": i, "split": entry["split"], "reasons": reasons,
                                  "audited": _optional_json(eval_dir / "audits" / f"{i}.json") is not None}))
        return jsonify([item for _, item in sorted(result, key=lambda pair: (pair[0], pair[1]["id"]))])

    @bp.get("/api/item/<int:id>")
    def item(id):
        entry = entries().get(id)
        if entry is None:
            return jsonify(error="unknown eval id"), 404
        try:
            runs = selected_runs()
        except ValueError as ex:
            return jsonify(error=str(ex)), 400
        data = {}
        for run in runs:
            output = _optional_json(eval_dir / "runs" / run / f"{id}.json")
            grade = _optional_json(eval_dir / "grades" / run / f"{id}.json")
            if output is not None or grade is not None:
                data[run] = {"output": {k: output.get(k) for k in FACTUAL} if output is not None else None,
                             "grade": grade}
        return jsonify(id=id, split=entry["split"], image=url_for("eval_audit.img", id=id),
                       label=_optional_json(eval_dir / "labels" / f"{id}.json"), runs=data,
                       audit=_optional_json(eval_dir / "audits" / f"{id}.json"))

    @bp.get("/img/<int:id>")
    def img(id):
        path = eval_dir / "images" / f"{id}.jpg"
        if id not in entries() or not path.is_file():
            return jsonify(error="eval image not found"), 404
        return send_file(path, mimetype="image/jpeg", max_age=3600)

    @bp.post("/api/audit/<int:id>")
    def audit(id):
        # Same gate as mobile.guarded, without importing the mobile app's DB/image dependencies.
        if request.headers.get("X-Culling-Bay") != "1" or not request.is_json:
            return jsonify(error="missing X-Culling-Bay header or JSON body"), 403
        if id not in entries():
            return jsonify(error="unknown eval id"), 404
        body = request.get_json(silent=True)
        runs = [r for r in available_runs() if (eval_dir / "grades" / r / f"{id}.json").is_file()]
        error = _validate_audit(body, runs)
        if error:
            return jsonify(error=error), 400
        saved = {"reference": body["reference"], "corrections": body.get("corrections", {}),
                 "grades": body.get("grades", {}), "note": body.get("note", ""),
                 "audited_at": datetime.now(timezone.utc).isoformat()}
        try:
            _save_audit(eval_dir / "audits" / f"{id}.json", saved)
        except OSError:
            return jsonify(error="Could not write the audit. Please try saving again."), 500
        return jsonify(saved)

    return bp


PAGE = r'''<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>Caption audit · Culling Bay</title>
<style>
:root { color-scheme: light dark; --bg:#f3f5f7; --card:#fff; --ink:#18232e; --muted:#526170;
  --line:#b8c3ce; --accent:#075a9c; --tint:#e5f1fc; --bad:#982521; --warn:#fff1d0; }
@media (prefers-color-scheme:dark) { :root { --bg:#12181f; --card:#1c2631; --ink:#edf2f8;
  --muted:#b7c5d4; --line:#526477; --accent:#91ccff; --tint:#173c59; --bad:#ffb4ab; --warn:#45391e; } }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:1rem/1.5 system-ui,sans-serif; }
main { max-width:48rem; margin:auto; padding:1rem max(1rem,env(safe-area-inset-right)) 2rem max(1rem,env(safe-area-inset-left)); }
h1 { font-size:1.5rem; margin:0; } h2 { font-size:1.2rem; margin:0 0 .6rem; }
p { margin:.5rem 0; } ul { padding-left:1.4rem; } li { margin:.3rem 0; }
button, input, textarea, select { font:inherit; color:inherit; }
button, select, textarea, input[type=number] { border:1px solid var(--line); border-radius:.5rem; background:var(--card); padding:.6rem; }
button, select, .choice { min-height:2.8rem; } button { cursor:pointer; }
button:disabled { opacity:.5; cursor:default; } :focus-visible { outline:3px solid var(--accent); outline-offset:3px; }
textarea, input[type=number] { display:block; width:100%; margin:.25rem 0 .8rem; }
input[type=radio], input[type=checkbox] { width:1.25rem; height:1.25rem; accent-color:var(--accent); flex-shrink:0; }
.row { display:flex; flex-wrap:wrap; align-items:center; gap:.6rem; margin:.7rem 0; }
.row > button { flex:1; } .muted { color:var(--muted); } .card { background:var(--card); border:1px solid var(--line);
  border-radius:.75rem; padding:1rem; margin:1rem 0; overflow-wrap:anywhere; }
.flag { color:var(--bad); } .ref-note { background:var(--warn); border-left:4px solid var(--accent); padding:.6rem; white-space:pre-wrap; }
.tag { display:inline-block; border:1px solid var(--line); border-radius:.4rem; padding:.1rem .4rem; margin:.15rem; }
.tag.flag { border-color:var(--bad); text-decoration:underline wavy; }
.choice { display:flex; align-items:center; gap:.5rem; padding:.6rem; border:1px solid var(--line); border-radius:.5rem; }
.choice:has(input:checked) { background:var(--tint); border-color:var(--accent); }
fieldset { border:0; padding:0; margin:0; min-width:0; } legend { font-weight:650; margin-bottom:.3rem; }
#photo-open { display:block; width:100%; padding:0; border:0; background:transparent; }
#photo { display:block; width:100%; max-height:65vh; object-fit:contain; border-radius:.5rem; }
.primary { background:var(--accent); color:var(--card); font-weight:650; }
#save { width:100%; min-height:3.2rem; } #status { white-space:pre-wrap; }
#reasons { padding-left:1.4rem; } #position { scroll-margin-top:1rem; }
dialog { width:100%; max-width:100%; height:100%; max-height:100%; margin:0; padding:1rem;
  border:0; background:var(--bg); color:var(--ink); }
dialog::backdrop { background:#000d; } #full-image { width:100%; height:calc(100% - 4rem); object-fit:contain; }
#close-image { display:block; margin-left:auto; } [hidden] { display:none !important; }
</style>
<main>
  <header><h1>Caption audit</h1><p class="muted">Check the reference and the grader against the photo.</p></header>
  <div class="row"><label for="filter">Queue</label><select id="filter">
    <option value="priority">Priority only</option><option value="all">All photos</option>
  </select><button id="unaudited" type="button">Next un-audited</button></div>
  <p id="progress" aria-live="polite"></p>
  <nav class="row" aria-label="Photo navigation"><button id="prev" type="button">← Prev</button>
    <button id="next" type="button">Next →</button></nav>
  <p id="status" role="status" aria-live="polite">Loading queue…</p>
  <button id="retry" type="button" hidden>Retry loading</button>
  <article id="item" hidden>
    <h2 id="position" tabindex="-1"></h2><ul id="reasons"></ul>
    <button id="photo-open" type="button" aria-label="Open photo full screen"><img id="photo" alt="Photo being audited"></button>
    <p id="photo-status" class="muted">Loading image…</p>
    <form id="audit-form">
      <fieldset id="editor">
        <section id="reference" class="card" aria-label="Reference label"></section>
        <fieldset class="card"><legend>Is the reference right?</legend>
          <div class="row">
            <label class="choice"><input type="radio" name="reference" value="right" required>Right</label>
            <label class="choice"><input type="radio" name="reference" value="wrong">Wrong</label>
            <label class="choice"><input type="radio" name="reference" value="unsure">Unsure</label>
          </div>
          <fieldset id="corrections" hidden disabled>
            <p class="muted">Correct any fields you can. People count means faces visible.</p>
            <label>Corrected caption<textarea id="caption" rows="3"></textarea></label>
            <label>Corrected people count<input id="people" type="number" min="0" step="1" inputmode="numeric"></label>
            <label>Corrected activity<textarea id="activity" rows="2"></textarea></label>
            <label>Correction note<textarea id="correction-note" rows="2"></textarea></label>
          </fieldset>
        </fieldset>
        <div id="runs"></div>
        <label>Audit note<textarea id="note" rows="3" placeholder="What should we revisit?"></textarea></label>
        <button id="save" class="primary" type="submit">Save, then next</button>
      </fieldset>
    </form>
  </article>
  <noscript>Enable JavaScript to review and save audits.</noscript>
</main>
<dialog id="viewer" aria-label="Full screen photo"><button id="close-image" type="button">Close photo ✕</button>
  <img id="full-image" alt="Full screen photo being audited"></dialog>
<script>
'use strict';
const $ = id => document.getElementById(id);
const base = '/m/eval/';
const runQuery = new URLSearchParams();
const requestedRuns = new URLSearchParams(location.search).get('runs');
if (requestedRuns !== null) runQuery.set('runs', requestedRuns);
let queue = [], visible = [], index = -1, current = null, busy = false, dirty = false;
let loaded = false, filterValue = 'priority', preloaded = null;
let pendingIndex = 0, imageReady = false;
const correctionEdits = new Set();
function node(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}
function message(text, error = false) { $('status').textContent = text; $('status').className = error ? 'flag' : ''; }
async function api(path, options) {
  const response = await fetch(base + path, {cache:'no-store', ...options});
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || 'Request failed (' + response.status + ')');
  return body;
}
function controls() {
  $('editor').disabled = busy;
  $('filter').disabled = busy || !loaded;
  $('prev').disabled = busy || index <= 0;
  $('next').disabled = busy || index < 0 || index >= visible.length - 1;
  $('unaudited').disabled = busy || !visible.some(x => !x.audited);
  $('retry').disabled = busy;
  $('save').disabled = busy || !imageReady;
  $('progress').textContent = `${visible.filter(x => x.audited).length} of ${visible.length} audited`;
}
function canLeave() { return !dirty || confirm('Discard unsaved changes to this audit?'); }
function correctionVisibility(wrong) {
  $('corrections').hidden = !wrong;
  $('corrections').disabled = !wrong;
}
function facts(parent, value, grade) {
  if (!value) { parent.append(node('p', 'Not available.', 'muted')); return; }
  parent.append(node('p', value.caption ?? 'Caption unavailable'));
  parent.append(node('p', `People (faces visible): ${value.people_count ?? '—'}${grade?.people_count_ok === false ? ' · Grader: wrong count' : ''}`,
    grade?.people_count_ok === false ? 'flag' : ''));
  const activityFlag = ['wrong','missing'].includes(grade?.activity);
  parent.append(node('p', `Activity: ${value.activity || '—'}${activityFlag ? ' · Grader: ' + grade.activity : ''}`, activityFlag ? 'flag' : ''));
  const tags = node('p', 'Tags: ');
  for (const tag of value.tags || []) tags.append(node('span', tag, 'tag' + (grade?.tags_wrong_list?.includes(tag) ? ' flag' : '')));
  parent.append(tags);
}
function render(item) {
  $('audit-form').reset();
  correctionEdits.clear();
  const audit = item.audit;
  $('position').textContent = `Photo ${index + 1} of ${visible.length} · #${item.id} · ${item.split}`;
  $('reasons').replaceChildren(...(visible[index].reasons.length ? visible[index].reasons : ['No priority flags']).map(t => node('li', t)));
  imageReady = false;
  $('photo').hidden = true;
  $('photo-status').textContent = 'Loading image…';
  $('photo').src = item.image;
  $('photo').alt = `Eval photo ${item.id}; compare with the reference below`;
  const reference = $('reference');
  reference.replaceChildren(node('h2', 'Reference label'));
  facts(reference, item.label);
  reference.append(node('p', 'Uncertain: ' + ((item.label?.uncertain || []).join('; ') || 'None listed'), 'muted'));
  if (item.label?.confidence) reference.append(node('p', 'Confidence: ' + item.label.confidence, 'muted'));
  for (const radio of document.querySelectorAll('[name=reference]')) radio.checked = radio.value === audit?.reference;
  correctionVisibility(audit?.reference === 'wrong');
  const fields = {caption:'caption', people:'people_count', activity:'activity', 'correction-note':'note'};
  for (const [id, key] of Object.entries(fields)) {
    $(id).value = audit?.corrections?.[key] ?? '';
    $(id).placeholder = key === 'note' ? 'Why is the reference wrong?' : String(item.label?.[key] ?? '');
    if (Object.hasOwn(audit?.corrections || {}, key)) correctionEdits.add(id);
  }
  $('note').value = audit?.note || '';
  $('runs').replaceChildren();
  for (const [run, data] of Object.entries(item.runs)) {
    const card = node('section', undefined, 'card');
    card.append(node('h2', run));
    facts(card, data.output, data.grade);
    if (data.grade) {
      const errors = data.grade.caption_errors || [];
      const list = node('ul', undefined, 'flag');
      for (const error of errors) list.append(node('li', `${error.type}: ${error.detail || ''}`));
      card.append(errors.length ? list : node('p', 'No caption errors flagged.', 'muted'));
      card.append(node('p', `Tags marked wrong: ${(data.grade.tags_wrong_list || []).join(', ') || 'None'} (${data.grade.tags_wrong ?? 0})`,
        data.grade.tags_wrong ? 'flag' : 'muted'));
      if (data.grade.notes) card.append(node('p', data.grade.notes, data.grade.notes.includes('REF:') ? 'ref-note' : 'muted'));
      const label = node('label', undefined, 'choice'), toggle = node('input');
      toggle.type = 'checkbox'; toggle.dataset.run = run;
      toggle.checked = audit?.grades?.[run] === 'disagree';
      label.append(toggle, document.createTextNode('Grade looks wrong'));
      card.append(label);
    } else card.append(node('p', 'Not graded yet.', 'muted'));
    $('runs').append(card);
  }
  $('item').hidden = false;
  dirty = false;
  // Only the next image is prefetched; captions and grades load when visited.
  preloaded = null;
  if (visible[index + 1]) { preloaded = new Image(); preloaded.src = base + 'img/' + visible[index + 1].id; }
}
async function show(target, notice = '') {
  pendingIndex = target;
  busy = true; controls(); message('Loading photo…'); $('retry').hidden = true;
  try {
    const item = await api('api/item/' + visible[target].id + '?' + runQuery);
    index = target; current = item; render(item);
    message(notice || (item.audit ? 'Previously audited. You can update it.' : ''));
    $('position').focus();
    window.scrollTo(0, 0);
  } catch (error) { message(error.message + ' Your saved audits are safe. Retry loading.', true); $('retry').hidden = false; }
  finally { busy = false; controls(); }
}
async function applyFilter() {
  visible = queue.filter(x => filterValue === 'all' || x.reasons.length);
  current = null; index = -1; $('item').hidden = true; $('retry').hidden = true; dirty = false;
  if (!visible.length) { message('No photos in this queue. Choose All photos to see the rest.'); controls(); return; }
  const first = visible.findIndex(x => !x.audited);
  await show(first < 0 ? 0 : first);
}
async function start() {
  busy = true; controls();
  try { queue = await api('api/items?' + runQuery); loaded = true; await applyFilter(); }
  catch (error) { message(error.message, true); $('retry').hidden = false; }
  finally { busy = false; controls(); }
}
$('filter').onchange = async () => {
  if (!canLeave()) { $('filter').value = filterValue; return; }
  filterValue = $('filter').value; await applyFilter();
};
$('prev').onclick = () => { if (canLeave()) show(index - 1); };
$('next').onclick = () => { if (canLeave()) show(index + 1); };
$('unaudited').onclick = () => {
  if (!canLeave()) return;
  for (let step = 1; step <= visible.length; step++) {
    const target = (index + step) % visible.length;
    if (!visible[target].audited) { show(target); return; }
  }
};
$('retry').onclick = () => { if (canLeave()) return loaded ? show(pendingIndex) : start(); };
$('audit-form').addEventListener('input', event => {
  dirty = true;
  if (event.target.closest('#corrections')) correctionEdits.add(event.target.id);
  correctionVisibility(document.querySelector('[name=reference]:checked')?.value === 'wrong');
});
$('audit-form').onsubmit = async event => {
  event.preventDefault();
  if (busy || !current || !imageReady) return;
  const reference = document.querySelector('[name=reference]:checked')?.value;
  if (!reference) { message('Choose right, wrong or unsure before saving.', true); return; }
  const corrections = {};
  if (reference === 'wrong') {
    for (const [id, key] of Object.entries({caption:'caption', activity:'activity', 'correction-note':'note'})) {
      if (correctionEdits.has(id)) corrections[key] = $(id).value;
    }
    if ($('people').value !== '') corrections.people_count = Number($('people').value);
  }
  // Preserve audit choices for runs omitted by a ?runs= filter.
  const grades = {...(current.audit?.grades || {})};
  for (const toggle of document.querySelectorAll('[data-run]')) grades[toggle.dataset.run] = toggle.checked ? 'disagree' : 'agree';
  busy = true; controls(); message('Saving…');
  try {
    current.audit = await api('api/audit/' + current.id, {method:'POST', headers:{'Content-Type':'application/json', 'X-Culling-Bay':'1'},
      body:JSON.stringify({reference, corrections, grades, note:$('note').value})});
    queue.find(x => x.id === current.id).audited = true;
    dirty = false;
    if (index + 1 < visible.length) await show(index + 1, 'Saved.');
    else message('Saved. End of this queue. Use Next un-audited to revisit any skipped photos.');
  } catch (error) { message('Not saved: ' + error.message + ' Your edits are still here; try Save again.', true); }
  finally { busy = false; controls(); }
};
$('photo-open').onclick = () => { $('full-image').src = current.image; $('viewer').showModal(); };
$('close-image').onclick = () => $('viewer').close();
$('photo').onload = () => {
  imageReady = true; $('photo').hidden = false;
  $('photo-status').textContent = 'Tap photo to view full screen.'; controls();
};
$('photo').onerror = () => {
  imageReady = false; $('photo').hidden = true;
  $('photo-status').textContent = 'Image could not load. Retry loading before auditing this photo.';
  $('retry').hidden = false; controls();
};
window.addEventListener('beforeunload', event => { if (dirty) { event.preventDefault(); event.returnValue = ''; } });
start();
</script>
</html>'''
