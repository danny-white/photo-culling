#!/usr/bin/env python3
"""
Local human-in-the-loop review + run-monitor UI for photo_cull.

Serves a single-page app over the cull SQLite DB:
  * browse/filter processed images, see the generated content next to the photo,
  * correct the verdict/stars and flag *what's wrong* (feeds prompt refinement),
  * compare bursts and pick the real best,
  * monitor the live run (progress / throughput / errors) and intervene
    (pause, redrive failures, export),
  * a prompt-suggestion report and a threshold sandbox that re-derives verdicts
    against your own corrections.

Reads the cull DB read-only (WAL-safe while a run is in progress); writes your
labels to a separate annotations DB so there's zero write-contention with the run.

    ./venv/bin/python review/server.py \
        --db trial_out/trial.db --log trial_out/run.log \
        --folders /mnt/passport/Pictures/2024 /mnt/passport/Pictures/2025

Then open http://127.0.0.1:8000
"""
import argparse
import hashlib
import io
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

from flask import Flask, jsonify, request, send_file, send_from_directory

# Reuse the culler's image loading / thresholds.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import photo_cull as pc  # noqa: E402

HERE = Path(__file__).resolve().parent
STATIC = HERE / "static"
CACHE = HERE / "cache"
CACHE.mkdir(exist_ok=True)

app = Flask(__name__, static_folder=None)

# ---- config (populated in main) ----
CFG = {
    "db": Path("trial_out/trial.db"),
    "annotations": Path("trial_out/annotations.db"),
    "log": Path("trial_out/run.log"),
    "pidfile": None,          # defaults to <db>.pid
    "folders": [],            # for resume/redrive
}

# The prompt-refinement signals a reviewer can attach to a frame, each mapped to a
# concrete suggested edit to photo_cull.VLM_PROMPT.
FLAG_SUGGESTIONS = {
    "confabulated detail": "Reinforce: 'Describe ONLY what is clearly visible; never invent objects, text, or people you are unsure about.'",
    "wrong subject": "Add: 'subject = the single largest / most in-focus element; ignore background clutter.'",
    "wrong genre": "Tighten the scene list and add: 'Choose the closest genre; if a pet/animal, use wildlife.'",
    "over-rated": "Add to the aesthetic rubric: 'Reserve 8-10 for genuinely strong frames; a merely acceptable snapshot is 4-6.'",
    "under-rated": "Add to the aesthetic rubric: 'Do not penalise unconventional but intentional composition.'",
    "missed issue": "Expand the issues list with examples and: 'Look specifically for distractions, crops through joints, merges.'",
    "keyword noise": "Constrain tags: 'Return 4-6 specific keywords; no generic filler like photo, image, picture.'",
    "missed eyes-closed": "Emphasise: 'Inspect every visible face; set eyes_closed=true if ANY subject is mid-blink.'",
}

TUNE_DEFAULTS = {
    "sharp_floor": pc.SHARP_FLOOR,
    "blown_severe": pc.BLOWN_PCT_SEVERE,
    "aesthetic_keep": 7,
    "aesthetic_reject": 3,
}


# ---------------------------------------------------------------- db helpers
def db_ro():
    """Read-only connection to the cull DB (query_only avoids WAL read-only file issues)."""
    conn = sqlite3.connect(str(CFG["db"]), timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA query_only=1")
    return conn


def anno():
    conn = sqlite3.connect(str(CFG["annotations"]), timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS annotations(
        path TEXT PRIMARY KEY,
        human_verdict TEXT,
        human_stars INTEGER,
        agree INTEGER,
        flags TEXT,
        note TEXT,
        updated_at TEXT)""")
    return conn


def annotations_map(paths):
    """Return {path: annotation-dict} for the given paths."""
    if not paths:
        return {}
    con = anno()
    q = ",".join("?" * len(paths))
    rows = con.execute(f"SELECT * FROM annotations WHERE path IN ({q})", paths).fetchall()
    con.close()
    return {r["path"]: dict(r) for r in rows}


def row_public(r, ann=None):
    d = {k: r[k] for k in r.keys()}
    for jcol in ("tags", "issues"):
        try:
            d[jcol] = json.loads(d[jcol]) if d.get(jcol) else []
        except (json.JSONDecodeError, TypeError):
            d[jcol] = []
    d["ai_verdict"] = d.get("base_verdict") or d.get("verdict")
    if ann:
        d["annotation"] = {
            "human_verdict": ann.get("human_verdict"),
            "human_stars": ann.get("human_stars"),
            "agree": ann.get("agree"),
            "flags": json.loads(ann["flags"]) if ann.get("flags") else [],
            "note": ann.get("note") or "",
        }
    else:
        d["annotation"] = None
    return d


# ---------------------------------------------------------------- pages / static
@app.route("/")
def index():
    return send_from_directory(STATIC, "index.html")


@app.route("/static/<path:p>")
def static_files(p):
    return send_from_directory(STATIC, p)


# ---------------------------------------------------------------- summary / list
FILTER_SQL = {
    "all": "status='ok'",
    "keep": "status='ok' AND base_verdict='keep'",
    "review": "status='ok' AND base_verdict='review'",
    "reject": "status='ok' AND base_verdict='reject'",
    "bursts": "status='ok' AND burst_size>1",
    "errors": "status='error'",
}
SORT_SQL = {
    "capture": "capture_ts", "sharpness": "sharpness", "aesthetic": "aesthetic",
    "stars": "quality_stars", "filename": "filename",
}


@app.route("/api/summary")
def api_summary():
    con = db_ro()
    total = con.execute("SELECT COUNT(*) c FROM images").fetchone()["c"]
    by_status = {r["status"]: r["c"] for r in con.execute("SELECT status,COUNT(*) c FROM images GROUP BY 1")}
    verdicts = {r["base_verdict"]: r["c"] for r in
                con.execute("SELECT base_verdict,COUNT(*) c FROM images WHERE status='ok' GROUP BY 1")}
    scenes = [dict(r) for r in con.execute(
        "SELECT scene,COUNT(*) c FROM images WHERE status='ok' AND scene<>'' GROUP BY 1 ORDER BY c DESC LIMIT 12")]
    bursts = con.execute("SELECT COUNT(*) c FROM images WHERE status='ok' AND burst_size>1").fetchone()["c"]
    errors = con.execute("SELECT COUNT(*) c FROM images WHERE status='error'").fetchone()["c"]
    con.close()
    acon = anno()
    disagreements = acon.execute("SELECT COUNT(*) c FROM annotations WHERE human_verdict IS NOT NULL").fetchone()["c"]
    corrected = acon.execute(
        "SELECT COUNT(*) c FROM annotations WHERE human_verdict IS NOT NULL OR agree=1").fetchone()["c"]
    acon.close()
    return jsonify({
        "total": total, "by_status": by_status, "verdicts": verdicts,
        "scenes": scenes, "bursts": bursts, "errors": errors,
        "reviewed": corrected, "labeled": disagreements,
    })


@app.route("/api/list")
def api_list():
    filt = request.args.get("filter", "all")
    scene = request.args.get("scene", "")
    stars = request.args.get("stars", "").strip()
    exposure = request.args.get("exposure", "").strip()
    q = request.args.get("q", "").strip()
    sort = SORT_SQL.get(request.args.get("sort", "capture"), "capture_ts")
    order = "DESC" if request.args.get("order", "asc") == "desc" else "ASC"
    limit = min(int(request.args.get("limit", 120)), 500)
    offset = int(request.args.get("offset", 0))

    where = [FILTER_SQL.get(filt, FILTER_SQL["all"])]
    params = []
    if scene:
        where.append("scene=?"); params.append(scene)
    if stars[:1].isdigit():
        where.append("quality_stars >= ?" if stars.endswith("+") else "quality_stars = ?")
        params.append(int(stars[0]))
    if exposure in ("over", "under", "ok"):
        where.append("exposure_flag=?"); params.append(exposure)
    if q:
        where.append("(filename LIKE ? OR subject LIKE ? OR caption LIKE ? OR tags LIKE ? OR issues LIKE ?)")
        params += [f"%{q}%"] * 5
    sql = (f"SELECT rowid AS id, path, filename, base_verdict, verdict, color_label, quality_stars, "
           f"aesthetic, sharpness, exposure_flag, scene, subject, people_count, eyes_closed, "
           f"burst_id, burst_size, is_best_in_burst, status, error_class, error_msg "
           f"FROM images WHERE {' AND '.join(where)} ORDER BY {sort} {order}, filename LIMIT ? OFFSET ?")
    con = db_ro()
    rows = con.execute(sql, (*params, limit, offset)).fetchall()
    con.close()
    amap = annotations_map([r["path"] for r in rows])
    items = [row_public(r, amap.get(r["path"])) for r in rows]
    # never leak absolute NAS paths to the client beyond what's needed
    for it in items:
        it.pop("path", None)
    return jsonify({"items": items, "count": len(items), "offset": offset})


@app.route("/api/item/<int:rowid>")
def api_item(rowid):
    con = db_ro()
    r = con.execute("SELECT rowid AS id, * FROM images WHERE rowid=?", (rowid,)).fetchone()
    con.close()
    if not r:
        return jsonify({"error": "not found"}), 404
    amap = annotations_map([r["path"]])
    d = row_public(r, amap.get(r["path"]))
    d.pop("path", None)
    d.pop("mtime", None); d.pop("size", None)
    return jsonify(d)


# Bursts are computed live: the burst_* columns are only written at export time, so
# the reviewer would see nothing mid-run. We replicate photo_cull.cluster_bursts read-only.
_BURST = {"ts": 0}


def burst_index():
    if _BURST.get("groups") and time.time() - _BURST["ts"] < 20:
        return _BURST
    con = db_ro()
    rows = con.execute(
        "SELECT rowid AS id, path, filename, capture_ts, camera, sharpness, aesthetic, "
        "quality_stars, base_verdict, exposure_flag, subject FROM images WHERE status='ok' "
        "ORDER BY capture_ts, filename").fetchall()
    con.close()
    groups, cur = [], []
    prev_ts = prev_cam = None
    bid = 0
    for r in rows:
        ts, cam = r["capture_ts"], r["camera"]
        same = (prev_ts is not None and ts is not None and cam is not None and prev_cam is not None
                and (ts - prev_ts) <= pc.BURST_GAP_S and cam == prev_cam)
        if not same:
            if cur:
                groups.append(cur)
            cur = []
            bid += 1
        d = {k: r[k] for k in r.keys()}
        d["bid"] = bid
        cur.append(d)
        prev_ts, prev_cam = ts, cam
    if cur:
        groups.append(cur)
    by_row, multi = {}, []
    for g in groups:
        keepers = [x for x in g if x["base_verdict"] == "keep"]
        best = max(keepers or g, key=lambda x: (x["aesthetic"] or 0, x["sharpness"] or 0))
        for x in g:
            x["is_best"] = x["id"] == best["id"]
            x["burst_size"] = len(g)
            by_row[x["id"]] = x
        if len(g) > 1:
            multi.append(g)
    _BURST.update(ts=time.time(), groups=groups, by_row=by_row, multi=multi)
    return _BURST


def _burst_frame(x, amap):
    a = amap.get(x["path"])
    return {"id": x["id"], "filename": x["filename"], "sharpness": x["sharpness"],
            "aesthetic": x["aesthetic"], "quality_stars": x["quality_stars"],
            "base_verdict": x["base_verdict"], "exposure_flag": x["exposure_flag"],
            "subject": x.get("subject"), "is_best": x["is_best"],
            "human_verdict": a["human_verdict"] if a else None}


@app.route("/api/bursts")
def api_bursts():
    idx = burst_index()
    out = []
    for g in idx["multi"]:
        best = next((x for x in g if x["is_best"]), g[0])
        out.append({"bid": g[0]["bid"], "n": len(g), "rep": best["id"],
                    "keeps": sum(1 for x in g if x["base_verdict"] == "keep"),
                    "subject": best.get("subject"),
                    "top_stars": max((x["quality_stars"] or 0) for x in g)})
    out.sort(key=lambda b: -b["bid"])
    return jsonify({"bursts": out[:400], "total": len(idx["multi"])})


@app.route("/api/burst/<int:bid>")
def api_burst(bid):
    idx = burst_index()
    g = next((grp for grp in idx["groups"] if grp and grp[0]["bid"] == bid), [])
    amap = annotations_map([x["path"] for x in g])
    return jsonify({"bid": bid, "frames": [_burst_frame(x, amap) for x in g]})


@app.route("/api/burst_of/<int:rowid>")
def api_burst_of(rowid):
    idx = burst_index()
    x = idx["by_row"].get(rowid)
    if not x or x["burst_size"] <= 1:
        return jsonify({"bid": None, "frames": []})
    g = next((grp for grp in idx["groups"] if grp and grp[0]["bid"] == x["bid"]), [])
    amap = annotations_map([y["path"] for y in g])
    return jsonify({"bid": x["bid"], "frames": [_burst_frame(y, amap) for y in g]})


# ---------------------------------------------------------------- thumbnails
def _path_for(rowid):
    con = db_ro()
    r = con.execute("SELECT path FROM images WHERE rowid=?", (rowid,)).fetchone()
    con.close()
    return r["path"] if r else None


@app.route("/api/thumb/<int:rowid>")
def api_thumb(rowid):
    size = request.args.get("s", "grid")
    edge = {"grid": 400, "loupe": 1400, "strip": 240}.get(size, 400)
    path = _path_for(rowid)
    if not path:
        return jsonify({"error": "not found"}), 404
    key = hashlib.md5(f"{path}:{edge}".encode()).hexdigest()
    cached = CACHE / f"{key}.jpg"
    if not cached.exists():
        try:
            im = pc.load_source(Path(path))
            im = pc.to_working(im, edge)
            im.save(cached, "JPEG", quality=86)
        except Exception as e:  # unreadable file -> 1x1 so the grid still lays out
            return jsonify({"error": f"decode failed: {pc._exc_text(e)[:120]}"}), 415
    return send_file(cached, mimetype="image/jpeg", max_age=3600)


# ---------------------------------------------------------------- annotations
@app.route("/api/annotate", methods=["POST"])
def api_annotate():
    d = request.get_json(force=True)
    rowid = d.get("id")
    path = _path_for(rowid)
    if not path:
        return jsonify({"error": "unknown image"}), 404
    con = anno()
    con.execute(
        """INSERT INTO annotations(path, human_verdict, human_stars, agree, flags, note, updated_at)
           VALUES(?,?,?,?,?,?,?)
           ON CONFLICT(path) DO UPDATE SET
             human_verdict=excluded.human_verdict, human_stars=excluded.human_stars,
             agree=excluded.agree, flags=excluded.flags, note=excluded.note,
             updated_at=excluded.updated_at""",
        (path, d.get("human_verdict"), d.get("human_stars"),
         1 if d.get("agree") else 0, json.dumps(d.get("flags") or []),
         d.get("note") or "", time.strftime("%Y-%m-%dT%H:%M:%S")))
    con.commit(); con.close()
    return jsonify({"ok": True})


# ---------------------------------------------------------------- monitor + intervene
def _pid_alive():
    pf = CFG["pidfile"] or Path(str(CFG["db"]) + ".pid")
    try:
        pid = int(Path(pf).read_text().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError, FileNotFoundError):
        return None


def _tail(path, n=12):
    try:
        data = Path(path).read_bytes()
    except OSError:
        return []
    return data.decode("utf-8", "replace").splitlines()[-n:]


@app.route("/api/monitor")
def api_monitor():
    con = db_ro()
    by_status = {r["status"]: r["c"] for r in con.execute("SELECT status,COUNT(*) c FROM images GROUP BY 1")}
    total = sum(by_status.values())
    rate = con.execute(
        "SELECT COUNT(*) n, MIN(processed_at) a, MAX(processed_at) b FROM images WHERE status='ok'").fetchone()
    errclasses = [dict(r) for r in con.execute(
        "SELECT COALESCE(error_class,'?') error_class, COUNT(*) c FROM images WHERE status='error' GROUP BY 1 ORDER BY c DESC")]
    con.close()
    ok = by_status.get("ok", 0)
    img_per_hr = eta_h = None
    if rate["n"] and rate["a"] and rate["b"] and rate["a"] != rate["b"]:
        import datetime as dt
        span = (dt.datetime.fromisoformat(rate["b"]) - dt.datetime.fromisoformat(rate["a"])).total_seconds()
        if span > 0:
            img_per_hr = round(rate["n"] / (span / 3600))
            pending = by_status.get("pending", 0)
            eta_h = round(pending / img_per_hr, 1) if img_per_hr else None
    gpu = None
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total,utilization.gpu",
                              "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=3)
        used, tot, util = (x.strip() for x in out.stdout.strip().split(","))
        gpu = {"used_mb": int(used), "total_mb": int(tot), "util": int(util)}
    except Exception:
        pass
    # The run's own [i/N] counter is the true progress — the ok/pending DB counts don't move
    # while --force re-runs already-ok frames in place.
    recent = _tail(CFG["log"], 40)
    run_pos = None
    for line in reversed(recent):
        m = re.search(r"\[(\d+)/(\d+)\]", line)
        if m:
            run_pos = {"i": int(m.group(1)), "n": int(m.group(2))}
            break
    return jsonify({
        "running": _pid_alive() is not None,
        "counts": {"ok": ok, "pending": by_status.get("pending", 0),
                   "error": by_status.get("error", 0), "total": total},
        "img_per_hr": img_per_hr, "eta_hours": eta_h,
        "errors_by_class": errclasses, "gpu": gpu,
        "run_pos": run_pos,
        "recent": recent[-12:],
    })


@app.route("/api/intervene", methods=["POST"])
def api_intervene():
    action = (request.get_json(force=True) or {}).get("action")
    py = sys.executable
    cull = str(HERE.parent / "photo_cull.py")
    db = str(CFG["db"])
    if action == "pause":
        pid = _pid_alive()
        if not pid:
            return jsonify({"ok": False, "msg": "no running process"}), 409
        os.kill(pid, signal.SIGINT)
        return jsonify({"ok": True, "msg": f"sent SIGINT to {pid}"})
    if action in ("resume", "redrive"):
        if _pid_alive():
            return jsonify({"ok": False, "msg": "a run is already active"}), 409
        if not CFG["folders"]:
            return jsonify({"ok": False, "msg": "start the server with --folders to enable resume/redrive"}), 400
        cmd = [py, "-u", cull, "run", *CFG["folders"], "--db", db]
        if action == "redrive":
            cmd.append("--redrive")
        logf = open(CFG["log"], "a")
        subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, start_new_session=True)
        return jsonify({"ok": True, "msg": f"{action} started"})
    if action == "export":
        snap = CFG["db"].with_suffix(".export-snapshot.db")
        src = sqlite3.connect(str(CFG["db"])); dst = sqlite3.connect(str(snap))
        src.backup(dst); dst.close(); src.close()
        out_csv = CFG["db"].parent / "cull.csv"
        out_xmp = CFG["db"].parent / "xmp"
        cmd = [py, cull, "export", "--db", str(snap), "--csv", str(out_csv), "--xmp-dir", str(out_xmp)]
        logf = open(CFG["db"].parent / "export.log", "a")
        subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, start_new_session=True)
        return jsonify({"ok": True, "msg": f"export started -> {out_csv} and {out_xmp}/"})
    return jsonify({"ok": False, "msg": "unknown action"}), 400


# ---------------------------------------------------------------- feedback -> prompt
@app.route("/api/feedback")
def api_feedback():
    acon = anno()
    rows = acon.execute("SELECT * FROM annotations").fetchall()
    acon.close()
    flag_counts = {}
    notes = []
    human = {}
    for r in rows:
        for f in (json.loads(r["flags"]) if r["flags"] else []):
            flag_counts[f] = flag_counts.get(f, 0) + 1
        if r["note"]:
            notes.append(r["note"])
        if r["human_verdict"]:
            human[r["path"]] = r["human_verdict"]

    # disagreements: human verdict vs the AI's base verdict, bucketed by scene
    disagree_by_scene = {}
    n_dis = n_lab = 0
    if human:
        con = db_ro()
        qs = ",".join("?" * len(human))
        for r in con.execute(f"SELECT path, scene, base_verdict FROM images WHERE path IN ({qs})", list(human)):
            n_lab += 1
            if human[r["path"]] != r["base_verdict"]:
                n_dis += 1
                disagree_by_scene[r["scene"] or "?"] = disagree_by_scene.get(r["scene"] or "?", 0) + 1
        con.close()

    suggestions = [{"flag": f, "count": c, "suggestion": FLAG_SUGGESTIONS.get(f, "")}
                   for f, c in sorted(flag_counts.items(), key=lambda x: -x[1])]
    # assemble a draft prompt addendum from the top flags
    addendum = "\n".join(f"- {s['suggestion']}" for s in suggestions[:6] if s["suggestion"])
    return jsonify({
        "flag_counts": flag_counts,
        "suggestions": suggestions,
        "notes": notes[-20:],
        "labeled": n_lab, "disagreements": n_dis,
        "disagree_rate": round(100 * n_dis / n_lab, 1) if n_lab else None,
        "disagree_by_scene": sorted(disagree_by_scene.items(), key=lambda x: -x[1]),
        "prompt_addendum": addendum,
    })


# ---------------------------------------------------------------- threshold sandbox
def derive_with(r, p):
    """Re-derive verdict/stars from stored CV+VLM fields with candidate thresholds.
    Mirrors photo_cull.derive() minus the (unstored) keep_hint gate."""
    blurry = (r["sharpness"] or 0) < p["sharp_floor"]
    bad_exp = (r["exposure_flag"] or "ok") != "ok"
    severe = (r["blown_pct"] or 0) > p["blown_severe"]
    closed = (r["people_count"] or 0) > 0 and (r["eyes_closed"] or 0)
    aes = r["aesthetic"] if r["aesthetic"] is not None else 5
    stars = round(aes / 2) - (1 if blurry else 0) - (1 if bad_exp else 0) - (1 if closed else 0)
    stars = max(1, min(5, stars))
    if blurry or severe or closed or aes <= p["aesthetic_reject"]:
        v = "reject"
    elif (not blurry) and (not bad_exp) and aes >= p["aesthetic_keep"]:
        v = "keep"
    else:
        v = "review"
    return v, stars


@app.route("/api/tune")
def api_tune():
    p = {k: float(request.args.get(k, v)) for k, v in TUNE_DEFAULTS.items()}
    p["aesthetic_keep"] = int(p["aesthetic_keep"]); p["aesthetic_reject"] = int(p["aesthetic_reject"])
    con = db_ro()
    rows = con.execute(
        "SELECT path, sharpness, exposure_flag, blown_pct, people_count, eyes_closed, aesthetic, base_verdict "
        "FROM images WHERE status='ok'").fetchall()
    con.close()
    human = {}
    acon = anno()
    for r in acon.execute("SELECT path, human_verdict FROM annotations WHERE human_verdict IS NOT NULL"):
        human[r["path"]] = r["human_verdict"]
    acon.close()

    dist = {"keep": 0, "review": 0, "reject": 0}
    flips = 0
    agree_h = tot_h = 0
    for r in rows:
        v, _ = derive_with(r, p)
        dist[v] += 1
        if v != r["base_verdict"]:
            flips += 1
        h = human.get(r["path"])
        if h:
            tot_h += 1
            if h == v:
                agree_h += 1
    return jsonify({
        "params": p, "n": len(rows), "distribution": dist,
        "flips_vs_ai": flips,
        "labeled": tot_h, "agreement_pct": round(100 * agree_h / tot_h, 1) if tot_h else None,
        "defaults": TUNE_DEFAULTS,
    })


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", type=Path, default=Path("trial_out/trial.db"))
    ap.add_argument("--annotations", type=Path, default=None)
    ap.add_argument("--log", type=Path, default=Path("trial_out/run.log"))
    ap.add_argument("--pidfile", type=Path, default=None)
    ap.add_argument("--folders", nargs="*", default=[], help="source folders, to enable resume/redrive from the UI")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    a = ap.parse_args()
    CFG["db"] = a.db
    CFG["annotations"] = a.annotations or a.db.with_suffix(".annotations.db")
    CFG["log"] = a.log
    CFG["pidfile"] = a.pidfile
    CFG["folders"] = a.folders
    anno().close()  # ensure the annotations table exists
    print(f"Review UI on http://{a.host}:{a.port}  (db={a.db}, annotations={CFG['annotations']})")
    app.run(host=a.host, port=a.port, threaded=True)


if __name__ == "__main__":
    main()
