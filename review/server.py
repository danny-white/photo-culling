#!/usr/bin/env python3
"""
Run monitor for photo_cull, plus Culling Bay Mobile under /m.

The desktop page at / is the monitor only: progress, throughput, errors and GPU for the
ingest runs, with Pause / Resume / Redrive / Export and the bulk-run timer switch.
Culling, search and the gallery live in the phone app (mobile.py, /m). The desktop
Review, Search, Bursts, Feedback and Tune tabs were retired on 2026-10-17.

Reads the cull DB read-only (WAL-safe while a run is in progress). The phone app keeps
its own state in a separate annotations DB, so there's zero write-contention with the run.

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
import threading
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
from flask import Flask, Response, jsonify, request, send_file, send_from_directory

# Reuse the culler's image loading / thresholds.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import photo_cull as pc  # noqa: E402
import mobile  # noqa: E402  -- Culling Bay Mobile, the phone routes under /m
from eval_audit import make_eval_blueprint  # noqa: E402
import perf  # noqa: E402  -- request timing: trial_out/perf.jsonl and Server-Timing

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
    "embed_base_url": "http://localhost:11434/v1",   # for embedding SEARCH QUERIES (semantic search)
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
    """The annotations DB. Its `annotations` table held the retired desktop Review tab's
    corrections and is left as it was; the phone app adds its own cull_* tables."""
    conn = sqlite3.connect(str(CFG["annotations"]), timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def row_public(r):
    d = {k: r[k] for k in r.keys()}
    for jcol in ("tags", "issues", "animals"):
        try:
            d[jcol] = json.loads(d[jcol]) if d.get(jcol) else []
        except (json.JSONDecodeError, TypeError):
            d[jcol] = []
    return d


# ---------------------------------------------------------------- pages / static
@app.route("/")
def index():
    return send_from_directory(STATIC, "index.html")


@app.route("/static/<path:p>")
def static_files(p):
    return send_from_directory(STATIC, p)


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
    perf.note(cache="hit" if cached.exists() else "miss", ext=Path(path).suffix.lower())
    if not cached.exists():
        try:
            with perf.stage("load"):
                im = pc.load_source(Path(path))
            with perf.stage("resize"):
                im = pc.to_working(im, edge)
            with perf.stage("encode"):
                im.save(cached, "JPEG", quality=86)
        except Exception as e:  # unreadable file -> 1x1 so the grid still lays out
            return jsonify({"error": f"decode failed: {pc._exc_text(e)[:120]}"}), 415
    return send_file(cached, mimetype="image/jpeg", max_age=3600)


# ---------------------------------------------------------------- semantic search
# Brute-force cosine KNN over `embeddings` (34k x 768 floats ~= 100MB -- trivial to hold in RAM,
# no vector DB needed at this scale). Cached in-process and refreshed only when the table's
# (count, latest created_at) changes, since `embed` runs continuously in the background (ingest
# watcher) as new shoots land.
_EMBED_CACHE = {"count": -1, "latest": None, "matrix": None, "meta": []}
_EMBED_CACHE_LOCK = threading.Lock()


def _load_embed_cache():
    con = db_ro()
    snap = con.execute(
        "SELECT COUNT(*) c, MAX(created_at) m FROM embeddings WHERE embed_version=?",
        (pc.EMBED_VERSION,)).fetchone()
    count, latest = snap["c"], snap["m"]
    with _EMBED_CACHE_LOCK:
        if count == _EMBED_CACHE["count"] and latest == _EMBED_CACHE["latest"]:
            con.close()
            return _EMBED_CACHE
        rows = con.execute(
            "SELECT e.path, e.vector, e.dims, i.rowid AS id, i.filename, i.caption, i.subject "
            "FROM embeddings e JOIN images i ON i.path = e.path "
            "WHERE e.embed_version=?", (pc.EMBED_VERSION,)).fetchall()
        con.close()
        if not rows:
            _EMBED_CACHE.update(count=count, latest=latest, matrix=None, meta=[])
            return _EMBED_CACHE
        dims = rows[0]["dims"]
        mat = np.zeros((len(rows), dims), dtype=np.float32)
        meta = []
        for i, r in enumerate(rows):
            mat[i] = pc.unpack_vector(r["vector"])
            meta.append({"id": r["id"], "path": r["path"], "filename": r["filename"],
                         "caption": r["caption"], "subject": r["subject"],
                         "shoot_folder": Path(r["path"]).parent.name})
        norms = np.linalg.norm(mat, axis=1, keepdims=True)
        norms[norms == 0] = 1  # guard a hypothetical all-zero vector, never divide by 0
        mat /= norms  # pre-normalize so cosine similarity = a plain dot product at query time
        _EMBED_CACHE.update(count=count, latest=latest, matrix=mat, meta=meta)
    return _EMBED_CACHE


@app.route("/api/semantic_search")
def api_semantic_search():
    """Text -> query embedding -> cosine KNN over the indexed photos. ?format=tsv returns
    `shootFolder\\tfilename\\tscore\\tcaption` lines (no header) for the Lightroom plugin, which
    already knows how to parse that shape from the AI-Cull sync TSV; default is JSON for the web UI."""
    q = request.args.get("q", "").strip()
    if not q:
        return jsonify({"error": "missing q"}), 400
    k = min(max(int(request.args.get("k", 60)), 1), 300)
    fmt = request.args.get("format", "json")

    cache = _load_embed_cache()
    if cache["matrix"] is None:
        return jsonify({"error": "no embeddings indexed yet -- run `photo_cull.py embed`"}), 503

    try:
        qvec = np.asarray(pc.infer_embed(CFG["embed_base_url"], None, pc.EMBED_MODEL, q),
                          dtype=np.float32)
    except Exception as e:  # noqa: BLE001 - embedding server hiccup shouldn't 500 the page
        return jsonify({"error": f"embed failed: {pc._exc_text(e)[:200]}"}), 502
    qnorm = np.linalg.norm(qvec)
    if qnorm > 0:
        qvec = qvec / qnorm

    scores = cache["matrix"] @ qvec
    top = np.argsort(-scores)[:k]
    results = [{**cache["meta"][i], "score": round(float(scores[i]), 4)} for i in top]

    if fmt == "tsv":
        lines = [f"{r['shoot_folder']}\t{r['filename']}\t{r['score']}\t"
                 f"{(r['caption'] or '').replace(chr(9), ' ').replace(chr(10), ' ')}"
                 for r in results]
        return Response("\n".join(lines) + "\n", mimetype="text/plain")

    for r in results:
        r.pop("path", None)  # never leak absolute NAS paths to the web client
    return jsonify({"query": q, "count": len(results), "results": results})


# ---------------------------------------------------------------- monitor + intervene
def _active_runs():
    """Every live `photo_cull.py run` process on the box, wherever it was launched from --
    this server's own Resume/Redrive button, a manual `nohup ... &`, or the ops/watch_ingest.sh
    poller. Replaces the old single-pidfile check, since those three sources now run
    interchangeably against the same DB."""
    try:
        out = subprocess.run(["ps", "-eo", "pid,etimes,args"],
                             capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return []
    runs = []
    for line in out.splitlines()[1:]:
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        pid, etimes, args = parts
        if "photo_cull.py" not in args or "run" not in args.split() or "grep" in args:
            continue
        toks = args.split()
        try:
            ridx = toks.index("run")
        except ValueError:
            continue
        folders = []
        for t in toks[ridx + 1:]:
            if t.startswith("--"):
                break
            folders.append(t)
        runs.append({"pid": int(pid), "elapsed_s": int(etimes), "folders": folders})
    return runs


def _active_watchers():
    """Live ops/watch_ingest.sh instances. Its for-loop moves on to the NEXT ready shoot folder
    as soon as its current photo_cull.py child exits -- so turning the timer off has to kill this
    parent too, not just whatever child it's driving right now, or it just spawns another one."""
    try:
        out = subprocess.run(["ps", "-eo", "pid,args"],
                             capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return []
    pids = []
    for line in out.splitlines()[1:]:
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        pid, args = parts
        if "watch_ingest.sh" in args and "grep" not in args:
            pids.append(int(pid))
    return pids


TIMER_UNIT = "photo-cull-ingest.timer"
SERVICE_UNIT = "photo-cull-ingest.service"


def _timer_status():
    def q(prop):
        try:
            out = subprocess.run(["systemctl", "--user", "is-" + prop, TIMER_UNIT],
                                 capture_output=True, text=True, timeout=5)
            return out.stdout.strip()
        except Exception:
            return "unknown"
    return {"active": q("active") == "active", "enabled": q("enabled") == "enabled"}


def _shoot_key(path):
    """(year, 'YYYY/YYYY-MM-DD') for the standard library layout; falls back gracefully for
    anything outside it (e.g. a manually-culled one-off folder) so grouping never crashes."""
    p = Path(path).parent
    year = p.parent.name if re.fullmatch(r"\d{4}", p.parent.name or "") else "other"
    return year, f"{year}/{p.name}"


def _shoot_date(path, capture_ts):
    """YYYY-MM-DD the photo was actually shot. capture_ts is written via a NAIVE (local-time)
    datetime.timestamp() at ingestion time (see process_one's EXIF parse), so it must be decoded
    the same way -- fromtimestamp() without a tz, not utcfromtimestamp() -- or the date can shift
    by a day. Falls back to the shoot folder's own YYYY-MM-DD name when EXIF capture time is
    missing (e.g. a format photo_cull couldn't parse)."""
    if capture_ts:
        try:
            return datetime.fromtimestamp(capture_ts).strftime("%Y-%m-%d")
        except (OSError, OverflowError, ValueError):
            pass
    m = re.search(r"\d{4}-\d{2}-\d{2}", Path(path).parent.name)
    return m.group(0) if m else None


@app.route("/api/monitor")
def api_monitor():
    con = db_ro()
    by_status = {r["status"]: r["c"] for r in con.execute("SELECT status,COUNT(*) c FROM images GROUP BY 1")}
    total = sum(by_status.values())
    errclasses = [dict(r) for r in con.execute(
        "SELECT COALESCE(error_class,'?') error_class, COUNT(*) c FROM images WHERE status='error' GROUP BY 1 ORDER BY c DESC")]

    # Throughput + ETA from the DB's own processed_at timestamps -- works no matter which
    # process wrote the row (server-launched run, a manual nohup run, the ingest watcher),
    # unlike the old approach of tailing one fixed --log file.
    window_min = 15
    cutoff = (datetime.now(timezone.utc) - timedelta(minutes=window_min)).isoformat(timespec="seconds")
    recent_n = con.execute("SELECT COUNT(*) c FROM images WHERE processed_at >= ?", (cutoff,)).fetchone()["c"]
    img_per_hr = round(recent_n * 60 / window_min) if recent_n else None
    pending = by_status.get("pending", 0)
    eta_h = round(pending / img_per_hr, 1) if img_per_hr else None

    # Per-shoot-folder breakdown, across the whole library the DB has ever seen -- grouped in
    # Python since it's one cheap pass over a local SQLite file, not worth a path-parsing SQL trick.
    by_year = defaultdict(lambda: {"total": 0, "ok": 0, "pending": 0, "error": 0, "last": None})
    by_folder = defaultdict(lambda: {"total": 0, "ok": 0, "pending": 0, "error": 0, "last": None, "year": None})
    for r in con.execute("SELECT path, status, processed_at FROM images"):
        year, key = _shoot_key(r["path"])
        for bucket in (by_year[year], by_folder[key]):
            bucket["total"] += 1
            bucket[r["status"]] = bucket.get(r["status"], 0) + 1
            if r["processed_at"] and (bucket["last"] is None or r["processed_at"] > bucket["last"]):
                bucket["last"] = r["processed_at"]
        by_folder[key]["year"] = year
    years = [{"year": y, **s} for y, s in sorted(by_year.items())]
    # "Needs attention" = anything not fully done yet -- fully-'ok' folders are already reflected
    # in the year rollup above and aren't actionable, so leave them out of this list.
    attention = [{"folder": k, **s} for k, s in by_folder.items() if s["pending"] or s["error"]]
    attention.sort(key=lambda f: f["last"] or "", reverse=True)

    last = con.execute(
        "SELECT rowid, filename, path, status, caption, subject, scene, "
        "capture_ts, error_class, error_msg, processed_at, tags, activity, indoor_outdoor, "
        "time_of_day, animals, content_type, visible_text, monochrome FROM images "
        "WHERE processed_at IS NOT NULL ORDER BY processed_at DESC LIMIT 1").fetchone()
    last_processed = row_public(last) if last else None
    if last_processed:
        last_processed["shoot_date"] = _shoot_date(last_processed["path"], last_processed["capture_ts"])

    # Recently processed (newest first).
    recent5 = [dict(r) for r in con.execute(
        "SELECT rowid, filename, path, status, capture_ts, processed_at FROM images "
        "WHERE processed_at IS NOT NULL ORDER BY processed_at DESC LIMIT 5")]
    for r in recent5:
        r["shoot_date"] = _shoot_date(r["path"], r["capture_ts"])

    # Up-next: cmd_run snapshots its whole `todo` list ONCE at launch and works through it
    # in-memory (filename ASC) -- it never notices rows registered *after* it started. So a
    # global "pending ORDER BY filename" prediction can show a row (e.g. from a folder
    # registered mid-run) that the actually-running process can't see yet and won't touch
    # until a fresh invocation starts. Scope to the active source(s)' own folder args when
    # something's running, to predict what THAT process will really do next; fall back to the
    # global view when idle, since that's what the next fresh `run` would see.
    runs = _active_runs()
    active_folders = [f for r in runs for f in r["folders"]]
    if active_folders:
        clauses = " OR ".join(["path LIKE ?"] * len(active_folders))
        params = [f"{f.rstrip('/')}/%" for f in active_folders]
        next5 = [dict(r) for r in con.execute(
            f"SELECT rowid, filename, path, capture_ts FROM images "
            f"WHERE status='pending' AND ({clauses}) ORDER BY filename ASC LIMIT 5", params)]
    else:
        next5 = [dict(r) for r in con.execute(
            "SELECT rowid, filename, path, capture_ts FROM images "
            "WHERE status='pending' ORDER BY filename ASC LIMIT 5")]
    for r in next5:
        r["shoot_date"] = _shoot_date(r["path"], r["capture_ts"])

    con.close()
    gpu = None
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total,utilization.gpu",
                              "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=3)
        used, tot, util = (x.strip() for x in out.stdout.strip().split(","))
        gpu = {"used_mb": int(used), "total_mb": int(tot), "util": int(util)}
    except Exception:
        pass
    return jsonify({
        "running": bool(runs),
        "sources": runs,
        "counts": {"ok": by_status.get("ok", 0), "pending": pending,
                   "error": by_status.get("error", 0), "total": total},
        "img_per_hr": img_per_hr, "eta_hours": eta_h,
        "errors_by_class": errclasses, "gpu": gpu,
        "by_year": years,
        "attention": attention[:40],
        "attention_more": max(0, len(attention) - 40),
        "last_processed": last_processed,
        "recent5": recent5,
        "next5": next5,
        "timer": _timer_status(),
    })


@app.route("/api/intervene", methods=["POST"])
def api_intervene():
    action = (request.get_json(force=True) or {}).get("action")
    py = sys.executable
    cull = str(HERE.parent / "photo_cull.py")
    db = str(CFG["db"])
    if action == "pause":
        runs = _active_runs()
        if not runs:
            return jsonify({"ok": False, "msg": "no running process"}), 409
        for r in runs:
            os.kill(r["pid"], signal.SIGINT)
        return jsonify({"ok": True, "msg": f"sent SIGINT to {', '.join(str(r['pid']) for r in runs)}"})
    if action in ("resume", "redrive"):
        if _active_runs():
            return jsonify({"ok": False, "msg": "a run is already active"}), 409
        if not CFG["folders"]:
            return jsonify({"ok": False, "msg": "start the server with --folders to enable resume/redrive"}), 400
        cmd = [py, "-u", cull, "run", *CFG["folders"], "--db", db]
        if action == "redrive":
            cmd.append("--redrive")
        logf = open(CFG["log"], "a")
        subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, start_new_session=True)
        return jsonify({"ok": True, "msg": f"{action} started"})
    if action == "timer_off":
        subprocess.run(["systemctl", "--user", "stop", TIMER_UNIT], timeout=10)
        runs = _active_runs()
        for r in runs:
            os.kill(r["pid"], signal.SIGINT)
        for pid in _active_watchers():
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        extra = f" -- interrupted {len(runs)} active run(s)" if runs else ""
        return jsonify({"ok": True, "msg": "Bulk runs turned off" + extra})
    if action == "timer_on":
        subprocess.run(["systemctl", "--user", "start", TIMER_UNIT], timeout=10)
        # --no-block: this is a oneshot service that can run for a long time (a big backlog) --
        # a normal `start` waits for it to finish, which would hang this HTTP request.
        subprocess.run(["systemctl", "--user", "start", "--no-block", SERVICE_UNIT], timeout=10)
        return jsonify({"ok": True, "msg": "Bulk runs turned on -- kicking off a poll now"})
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


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", type=Path, default=Path("trial_out/trial.db"))
    ap.add_argument("--annotations", type=Path, default=None)
    ap.add_argument("--log", type=Path, default=Path("trial_out/run.log"))
    ap.add_argument("--pidfile", type=Path, default=None,
                    help="Path to the CULL's pidfile, for the monitor (default: <db>.pid).")
    ap.add_argument("--server-pidfile", type=Path, default=None,
                    help="Write THIS review server's own PID here at start, so it can be stopped later.")
    ap.add_argument("--folders", nargs="*", default=[], help="source folders, to enable resume/redrive from the UI")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--perf-log", type=Path, default=None,
                    help="Where request timings go, one JSON line each (default: perf.jsonl next to --db).")
    ap.add_argument("--embed-base-url", default="http://localhost:11434/v1",
                    help="OpenAI-compatible base URL for embedding semantic-search queries (default: local Ollama).")
    a = ap.parse_args()
    CFG["db"] = a.db
    CFG["annotations"] = a.annotations or a.db.with_suffix(".annotations.db")
    CFG["log"] = a.log
    CFG["pidfile"] = a.pidfile
    CFG["folders"] = a.folders
    CFG["embed_base_url"] = a.embed_base_url
    perf.install(app, a.perf_log or Path(CFG["db"]).parent / "perf.jsonl")
    app.register_blueprint(mobile.make_blueprint(
        db_ro=db_ro, anno=anno, pc=pc, cache_dir=CACHE, static_dir=STATIC / "m",
        state_dir=Path(CFG["db"]).parent / "mobile"))
    app.register_blueprint(make_eval_blueprint(eval_dir=HERE.parent / "eval"))
    if a.server_pidfile:
        a.server_pidfile.write_text(str(os.getpid()))
        print(f"Review server PID {os.getpid()} -> {a.server_pidfile}")
    print(f"Review UI on http://{a.host}:{a.port}  (db={a.db}, annotations={CFG['annotations']})")
    app.run(host=a.host, port=a.port, threaded=True)


if __name__ == "__main__":
    main()
