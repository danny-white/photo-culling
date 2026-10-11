"""Culling Bay Mobile: the phone app's routes, under /m.

A Flask blueprint that review/server.py registers. It reads trial.db read-only through the
server's db_ro(), and keeps the phone's own state in annotations.db (cull_* tables), which the
review server already owns. Stack rules live in stacks.py.
"""
from __future__ import annotations

import functools
import hashlib
import json
import re
import sqlite3
import threading
import time
from datetime import date, datetime
from pathlib import Path

import numpy as np
from flask import Blueprint, abort, jsonify, request, send_file, send_from_directory

import stacks

LIBRARY_ROOT = "/mnt/passport/Pictures"
IMG_EDGE = {"thumb": 320, "view": 1616}   # 1616 = the embedded preview's full width
DAYS_TTL_S = 30

SCHEMA = """
CREATE TABLE IF NOT EXISTS cull_decisions(
  path       TEXT PRIMARY KEY,
  day        TEXT NOT NULL,
  flag       TEXT NOT NULL CHECK (flag IN ('pick','reject','none')),
  stars      INTEGER,
  note       TEXT NOT NULL DEFAULT '',
  via        TEXT NOT NULL,
  decided_at TEXT NOT NULL,
  state      TEXT NOT NULL DEFAULT 'draft',
  outcome    TEXT,
  sent_at    TEXT,
  landed_at  TEXT);
CREATE INDEX IF NOT EXISTS cull_decisions_day ON cull_decisions(day);
CREATE TABLE IF NOT EXISTS cull_actions(
  action_id  TEXT PRIMARY KEY,
  day        TEXT NOT NULL,
  at         TEXT NOT NULL,
  label      TEXT,
  before     TEXT NOT NULL,
  undone     INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS cull_days(
  day         TEXT PRIMARY KEY,
  pass        INTEGER,
  cursor      INTEGER,
  finished_at TEXT,
  sent_at     TEXT);
"""

ROW_COLS = ("rowid, path, filename, capture_ts, camera, sharpness, exposure_flag, mean_lum, "
            "blown_pct, phash")
DETAIL_COLS = "rowid, lens, caption, blown_pct, mean_lum"
FLAGS = ("pick", "reject", "none")
VIAS = ("sweep", "card", "burst", "rescue")


def now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def guarded(fn):
    """Writes need a JSON body and the X-Culling-Bay header. A cross-site page can send neither
    without a CORS preflight, which this server never answers."""
    @functools.wraps(fn)
    def wrapper(*a, **kw):
        if request.headers.get("X-Culling-Bay") != "1" or not request.is_json:
            return jsonify({"error": "missing X-Culling-Bay header or JSON body"}), 403
        return fn(*a, **kw)
    return wrapper


def day_of(path: str) -> str | None:
    """'/mnt/passport/Pictures/2026/2026-10-01/DSC05036.ARW' -> '2026/2026-10-01'."""
    if not path.startswith(LIBRARY_ROOT + "/"):
        return None
    rel = path[len(LIBRARY_ROOT) + 1:]
    return rel.rsplit("/", 1)[0] if "/" in rel else None


def day_date(day: str) -> str | None:
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", day.rsplit("/", 1)[-1])
    if not m:
        return None
    try:
        return date(int(m[1]), int(m[2]), int(m[3])).isoformat()
    except ValueError:
        return None


def make_blueprint(*, db_ro, anno, pc, cache_dir: Path, static_dir: Path, state_dir: Path) -> Blueprint:
    """db_ro/anno: the server's connection helpers. pc: the photo_cull module (image loading).
    state_dir: where derived per-day data is cached (trial_out/mobile)."""
    bp = Blueprint("mobile", __name__, url_prefix="/m")
    state_dir.mkdir(parents=True, exist_ok=True)
    pano_file = state_dir / "pano.json"
    lock = threading.Lock()
    cache = {"days": None, "days_at": 0.0, "days_key": None}

    def anno_db() -> sqlite3.Connection:
        con = anno()
        con.executescript(SCHEMA)
        return con

    # ---------------------------------------------------------------- stacks
    def library_rows():
        con = db_ro()
        try:
            rows = [dict(r) for r in con.execute(f"SELECT {ROW_COLS} FROM images WHERE status='ok'")]
        finally:
            con.close()
        by_day: dict[str, list[dict]] = {}
        for r in rows:
            d = day_of(r["path"])
            if d:
                by_day.setdefault(d, []).append(r)
        return by_day

    def day_rows(day: str) -> list[dict]:
        con = db_ro()
        try:
            prefix = f"{LIBRARY_ROOT}/{day}/"
            rows = [dict(r) for r in con.execute(
                f"SELECT {ROW_COLS} FROM images WHERE status='ok' AND path >= ? AND path < ?",
                (prefix, prefix[:-1] + "0"))]   # '0' sorts right after '/': exactly this folder's subtree
        finally:
            con.close()
        return [r for r in rows if day_of(r["path"]) == day]

    def load_pano() -> dict:
        try:
            return json.loads(pano_file.read_text())
        except (OSError, ValueError):
            return {}

    def grey(path: str):
        im = pc.load_source(Path(path)).convert("L")
        im.thumbnail((256, 256))
        return im

    def confirm_panos(day_stacks: list[dict]) -> None:
        """Pixel check for phash candidates, cached by the burst's frame ids."""
        todo = [s for s in day_stacks if s["pano_candidate"]]
        if not todo:
            return
        with lock:
            known = load_pano()
            changed = False
            for s in todo:
                key = ",".join(str(f["id"]) for f in s["frames"])
                if key not in known:
                    try:
                        ims = [grey(f["path"]) for f in s["frames"][:8]]
                        same = len({im.size for im in ims}) == 1
                        known[key] = bool(same and stacks.pano_confirmed(
                            [np.asarray(im, dtype=float) for im in ims]))
                    except Exception:  # unreadable frame: no hint, never an error
                        known[key] = False
                    changed = True
                if known[key]:
                    s["kind"] = "pano"
            if changed:
                tmp = pano_file.with_suffix(".tmp")
                tmp.write_text(json.dumps(known))
                tmp.replace(pano_file)

    # ---------------------------------------------------------------- routes: app shell
    @bp.route("/")
    def app_index():
        return send_from_directory(static_dir, "index.html")

    @bp.route("/<path:p>")
    def app_static(p):
        if p.startswith("api/"):
            abort(404)
        return send_from_directory(static_dir, p)

    # ---------------------------------------------------------------- routes: reads
    @bp.route("/api/days")
    def api_days():
        now = time.time()
        if cache["days"] is None or now - cache["days_at"] > DAYS_TTL_S:
            by_day = library_rows()
            summary = []
            for d, rows in by_day.items():
                st = stacks.build_stacks(rows)
                lead_ids = [s["lead"] for s in st]
                summary.append({
                    "day": d, "folder": d.rsplit("/", 1)[-1], "date": day_date(d),
                    "frames": sum(1 + len(f["partners"]) for s in st for f in s["frames"]),
                    "stacks": len(st),
                    "thumbs": [lead_ids[i * len(lead_ids) // 3] for i in range(min(3, len(lead_ids)))],
                    "last_ts": max((r["capture_ts"] or 0) for r in rows),
                })
            summary.sort(key=lambda x: (x["date"] or "", x["last_ts"]), reverse=True)
            cache.update(days=summary, days_at=now)
        con = anno_db()
        try:
            decided = {r["day"]: (r["n"], r["sent"], r["landed"], r["conflicts"]) for r in con.execute(
                "SELECT day, COUNT(*) n, SUM(state!='draft') sent, SUM(state='landed') landed, "
                "SUM(state='conflict') conflicts FROM cull_decisions GROUP BY day")}
            days_state = {r["day"]: dict(r) for r in con.execute("SELECT * FROM cull_days")}
        finally:
            con.close()
        out = []
        for d in cache["days"]:
            n, sent, landed, conflicts = decided.get(d["day"], (0, 0, 0, 0))
            ds = days_state.get(d["day"], {})
            out.append(dict(d, decided=n, sent=sent, landed=landed, conflicts=conflicts,
                            finished=bool(ds.get("finished_at")), sent_at=ds.get("sent_at")))
        return jsonify({"days": out})

    @bp.route("/api/day/<path:day>")
    def api_day(day):
        rows = day_rows(day)
        if not rows:
            return jsonify({"error": "no such day"}), 404
        day_stacks = stacks.build_stacks(rows)
        confirm_panos(day_stacks)
        paths = [p for s in day_stacks for f in s["frames"] for p in [f["path"]]]
        con = anno_db()
        try:
            q = ",".join("?" * len(paths))
            dec = {r["path"]: dict(r) for r in con.execute(
                f"SELECT path, flag, stars, note, state, outcome FROM cull_decisions WHERE path IN ({q})", paths)}
            ds = con.execute("SELECT * FROM cull_days WHERE day=?", (day,)).fetchone()
        finally:
            con.close()
        ids = [f["id"] for s in day_stacks for f in s["frames"]]
        con = db_ro()
        try:
            q = ",".join("?" * len(ids))
            details = {r["rowid"]: dict(r) for r in con.execute(
                f"SELECT {DETAIL_COLS} FROM images WHERE rowid IN ({q})", ids)}
        finally:
            con.close()
        for i, s in enumerate(day_stacks):
            s["id"] = i
            s.pop("pano_candidate", None)
            for f in s["frames"]:
                d = dec.get(f.pop("path"))
                f["decision"] = ({k: d[k] for k in ("flag", "stars", "note", "state", "outcome")}
                                 if d else None)
                det = details.get(f["id"], {})
                f["lens"] = det.get("lens")
                f["caption"] = det.get("caption")
                f["blown_pct"] = det.get("blown_pct")
                f["mean_lum"] = det.get("mean_lum")
        return jsonify({
            "day": day, "folder": day.rsplit("/", 1)[-1], "date": day_date(day),
            "stacks": day_stacks,
            "progress": {"pass": ds["pass"], "cursor": ds["cursor"]} if ds else None,
        })

    # ---------------------------------------------------------------- routes: writes
    def paths_for(ids: list[int]) -> dict[int, str]:
        con = db_ro()
        try:
            q = ",".join("?" * len(ids))
            return {r["rowid"]: r["path"] for r in con.execute(
                f"SELECT rowid, path FROM images WHERE rowid IN ({q})", ids)}
        finally:
            con.close()

    @bp.route("/api/decide", methods=["POST"])
    @guarded
    def api_decide():
        """One tap: {action_id, day, label, changes: [{id, flag, stars?, note?, via}]}. The
        rows as they were go into cull_actions, so undo is exact. A repeated action_id (a retry
        after a dropped response) is acknowledged and ignored."""
        body = request.get_json()
        action_id, day, changes = body.get("action_id"), body.get("day"), body.get("changes") or []
        if not action_id or not day or not changes:
            return jsonify({"error": "action_id, day and changes are required"}), 400
        for c in changes:
            if c.get("flag") not in FLAGS or c.get("via") not in VIAS or not isinstance(c.get("id"), int):
                return jsonify({"error": f"bad change: {c}"}), 400
        paths = paths_for([c["id"] for c in changes])
        if len(paths) != len({c["id"] for c in changes}) or any(day_of(p) != day for p in paths.values()):
            return jsonify({"error": "unknown frame, or a frame from another day"}), 400
        with lock:
            con = anno_db()
            try:
                if con.execute("SELECT 1 FROM cull_actions WHERE action_id=?", (action_id,)).fetchone():
                    return jsonify({"ok": True, "replay": True})
                q = ",".join("?" * len(paths))
                before = {r["path"]: dict(r) for r in con.execute(
                    f"SELECT * FROM cull_decisions WHERE path IN ({q})", list(paths.values()))}
                at = now_iso()
                con.execute("INSERT INTO cull_actions(action_id, day, at, label, before) VALUES (?,?,?,?,?)",
                            (action_id, day, at, body.get("label") or "",
                             json.dumps({p: before.get(p) for p in paths.values()})))
                for c in changes:
                    stars = c.get("stars") if c["flag"] == "pick" else None
                    con.execute(
                        """INSERT INTO cull_decisions(path, day, flag, stars, note, via, decided_at, state)
                           VALUES (?,?,?,?,?,?,?,'draft')
                           ON CONFLICT(path) DO UPDATE SET flag=excluded.flag, stars=excluded.stars,
                             note=excluded.note, via=excluded.via, decided_at=excluded.decided_at,
                             state='draft', outcome=NULL""",
                        (paths[c["id"]], day, c["flag"], stars, c.get("note") or "", c["via"], at))
                con.commit()
            finally:
                con.close()
        return jsonify({"ok": True})

    @bp.route("/api/undo", methods=["POST"])
    @guarded
    def api_undo():
        action_id = (request.get_json() or {}).get("action_id")
        with lock:
            con = anno_db()
            try:
                a = con.execute("SELECT * FROM cull_actions WHERE action_id=?", (action_id,)).fetchone()
                if not a:
                    return jsonify({"error": "unknown action"}), 404
                if a["undone"]:
                    return jsonify({"ok": True, "replay": True})
                for path, row in json.loads(a["before"]).items():
                    if row is None:
                        con.execute("DELETE FROM cull_decisions WHERE path=?", (path,))
                    else:
                        cols = list(row)
                        con.execute(
                            f"INSERT OR REPLACE INTO cull_decisions({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
                            [row[c] for c in cols])
                con.execute("UPDATE cull_actions SET undone=1 WHERE action_id=?", (action_id,))
                con.commit()
            finally:
                con.close()
        return jsonify({"ok": True})

    @bp.route("/api/day/<path:day>/progress", methods=["PUT"])
    @guarded
    def api_progress(day):
        body = request.get_json()
        p, cur = body.get("pass"), body.get("cursor")
        if p not in (1, 2) or not isinstance(cur, int):
            return jsonify({"error": "pass (1 or 2) and cursor are required"}), 400
        con = anno_db()
        try:
            con.execute(
                """INSERT INTO cull_days(day, pass, cursor, finished_at) VALUES (?,?,?,?)
                   ON CONFLICT(day) DO UPDATE SET pass=excluded.pass, cursor=excluded.cursor,
                     finished_at=COALESCE(excluded.finished_at, cull_days.finished_at)""",
                (day, p, cur, now_iso() if body.get("finished") else None))
            con.commit()
        finally:
            con.close()
        return jsonify({"ok": True})

    @bp.route("/api/img/<int:rowid>")
    def api_img(rowid):
        edge = IMG_EDGE.get(request.args.get("s", "view"), IMG_EDGE["view"])
        con = db_ro()
        try:
            r = con.execute("SELECT path FROM images WHERE rowid=?", (rowid,)).fetchone()
        finally:
            con.close()
        if not r:
            return jsonify({"error": "not found"}), 404
        key = hashlib.md5(f"m:{r['path']}:{edge}".encode()).hexdigest()
        cached = cache_dir / f"m-{key}.jpg"
        if not cached.exists():
            try:
                im = pc.to_working(pc.load_source(Path(r["path"])), edge)
                tmp = cached.with_suffix(".tmp")
                im.save(tmp, "JPEG", quality=85)
                tmp.replace(cached)
            except Exception as e:
                return jsonify({"error": f"decode failed: {pc._exc_text(e)[:120]}"}), 415
        return send_file(cached, mimetype="image/jpeg", max_age=86400)

    return bp
