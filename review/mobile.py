"""Culling Bay Mobile: the phone app's routes, under /m.

A Flask blueprint that review/server.py registers. It reads trial.db read-only through the
server's db_ro(), and keeps the phone's own state in annotations.db (cull_* tables), which the
review server already owns. Stack rules live in stacks.py.
"""
from __future__ import annotations

import fcntl
import functools
import hashlib
import io
import json
import mimetypes
import os
import re
import sqlite3
import threading
import time
from datetime import date, datetime, timedelta
from pathlib import Path

import numpy as np
from flask import Blueprint, Response, abort, jsonify, request, send_file, send_from_directory
from PIL import Image, ImageOps

import stacks

mimetypes.add_type("application/manifest+json", ".webmanifest")

LIBRARY_ROOT = "/mnt/passport/Pictures"
INBOX = Path("/mnt/Passport_AICullInbox")          # the narrow rw mount the watcher also writes
INBOX_SOURCE = "//mycloud/Passport/AICullInbox"     # ...and must come from this share (as in watch_ingest.sh)
DECISIONS_FILE = "cull-decisions.tsv"
DECISIONS_HEADER = "#cull-decisions v1"
RECEIPT_RE = re.compile(r"^(\d{8}-\d{6})-(receipt|catalog)\.tsv$")   # the plugin's two report files
LOST_AFTER = timedelta(seconds=60)                   # sent this long before a receipt that lacks it
IMG_EDGE = {"thumb": 320, "view": 1616}   # 1616 = the embedded preview's full width
DAYS_TTL_S = 30
CROP_MAX = 2400          # longest side of a crop, in source pixels
FULL_CACHE_FRAMES = 4    # full decodes kept in memory (~130 MB each for 42 MP)
DECODES_AT_ONCE = 2

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
CREATE TABLE IF NOT EXISTS cull_receipts(
  name    TEXT PRIMARY KEY,
  read_at TEXT,
  rows    INTEGER);
CREATE TABLE IF NOT EXISTS lr_state(      -- what Lightroom held at the last sync that covered the photo
  path     TEXT PRIMARY KEY,
  day      TEXT NOT NULL,
  pick     INTEGER NOT NULL,            -- 1 picked, 0 unflagged, -1 rejected
  rating   INTEGER NOT NULL,
  flag_by  TEXT NOT NULL,               -- 'you' (by hand), 'phone' (the plugin, from a Send), ''
  stars_by TEXT NOT NULL,
  seen_at  TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS lr_state_day ON lr_state(day);
"""

ROW_COLS = ("rowid, path, filename, capture_ts, camera, sharpness, exposure_flag, mean_lum, "
            "blown_pct, phash, place")
DETAIL_COLS = "rowid, lens, caption, blown_pct, mean_lum, place"
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


def tsv_row(path: str, d: dict) -> tuple[tuple[str, str], str]:
    """One cull-decisions.tsv line for a file, keyed like the plugin matches: (folder, file)."""
    p = Path(path)
    stars = str(d["stars"]) if d["flag"] == "pick" and d.get("stars") else ""
    note = (d.get("note") or "").replace("\t", " ").replace("\n", " ")
    return (p.parent.name, p.name), "\t".join((p.parent.name, p.name, d["flag"], stars, note))


def make_blueprint(*, db_ro, anno, pc, cache_dir: Path, static_dir: Path, state_dir: Path,
                   inbox: Path = INBOX, check_mount: bool = True) -> Blueprint:
    """db_ro/anno: the server's connection helpers. pc: the photo_cull module (image loading).
    state_dir: where derived per-day data is cached (trial_out/mobile). inbox: where Send writes
    cull-decisions.tsv and the plugin leaves receipts; check_mount refuses to write unless it is
    the narrow AICullInbox mount (tests turn it off and pass a temp dir)."""
    bp = Blueprint("mobile", __name__, url_prefix="/m")
    state_dir.mkdir(parents=True, exist_ok=True)
    pano_file = state_dir / "pano.json"
    lock = threading.Lock()
    cache = {"days": None, "days_at": 0.0, "days_key": None}
    full_cache: dict[str, Image.Image] = {}          # path -> full-resolution decode, oldest first
    full_lock = threading.Lock()
    decode_slots = threading.Semaphore(DECODES_AT_ONCE)

    def full_decode(path: str) -> Image.Image:
        """The whole frame at full resolution, upright. RAWs go through a full rawpy decode
        (about 1.2 s for a 42 MP ARW); anything else is opened directly."""
        with full_lock:
            im = full_cache.pop(path, None)
            if im is not None:
                full_cache[path] = im                 # most recently used goes last
                return im
        with decode_slots:
            src = Path(path)
            if src.suffix.lower() in stacks.RAW_EXTENSIONS:
                import rawpy
                with rawpy.imread(str(src)) as raw:
                    im = Image.fromarray(raw.postprocess(use_camera_wb=True))
            else:
                im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
        with full_lock:
            full_cache[path] = im
            while len(full_cache) > FULL_CACHE_FRAMES:
                full_cache.pop(next(iter(full_cache)))
        return im

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

    # ---------------------------------------------------------------- Lightroom round trip
    def inbox_problem() -> str | None:
        if not check_mount:
            return None
        if not os.path.ismount(inbox):
            return f"{inbox} is not mounted"
        with open("/proc/mounts") as fh:
            if not any(line.split()[:2] == [INBOX_SOURCE, str(inbox)] for line in fh):
                return f"{inbox} is not mounted from {INBOX_SOURCE}"
        return None

    def write_rows(lines: dict) -> None:
        """Merge lines into the inbox's cull-decisions.tsv, keyed by (folder, file). A local lock
        serialises writers; the temp-file swap means the plugin never reads half a file."""
        target = inbox / DECISIONS_FILE
        with open(state_dir / "decisions.lock", "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            rows = {}
            if target.exists():
                for line in target.read_text(encoding="utf-8").splitlines():
                    parts = line.split("\t")
                    if line and not line.startswith("#") and len(parts) >= 2:
                        rows[(parts[0], parts[1])] = line
            rows.update(lines)
            tmp = inbox / (DECISIONS_FILE + ".tmp")
            tmp.write_text(DECISIONS_HEADER + "\n" + "\n".join(rows.values()) + "\n", encoding="utf-8")
            os.replace(tmp, target)

    def remove_rows(keys: set) -> int:
        """Take rows back out of the inbox's cull-decisions.tsv (under the same lock as writes).
        A file left with no rows is removed, so the plugin has nothing to pick up."""
        target = inbox / DECISIONS_FILE
        if not target.exists():
            return 0
        with open(state_dir / "decisions.lock", "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            rows = [l for l in target.read_text(encoding="utf-8").splitlines() if l and not l.startswith("#")]
            kept = [l for l in rows if tuple(l.split("\t")[:2]) not in keys]
            if kept:
                tmp = inbox / (DECISIONS_FILE + ".tmp")
                tmp.write_text(DECISIONS_HEADER + "\n" + "\n".join(kept) + "\n", encoding="utf-8")
                os.replace(tmp, target)
            else:
                target.unlink()
        return len(rows) - len(kept)

    def partner_paths(day: str) -> dict[str, list[str]]:
        return {f["path"]: [p["path"] for p in f["partners"]] for f in stacks.pair_frames(day_rows(day))}

    def queue_decisions(con, decisions: list[dict]) -> int:
        """Write decisions (and their pair partners) to the inbox file and mark them queued."""
        lines = {}
        partners_by_day: dict[str, dict] = {}
        for d in decisions:
            partners = partners_by_day.setdefault(d["day"], partner_paths(d["day"]))
            for p in [d["path"]] + partners.get(d["path"], []):
                key, line = tsv_row(p, d)
                lines[key] = line
        write_rows(lines)
        at = now_iso()
        con.executemany("UPDATE cull_decisions SET state='queued', sent_at=? WHERE path=?",
                        [(at, d["path"]) for d in decisions])
        return len(lines)

    def library_keys() -> dict[tuple, str]:
        """(shoot folder, file name) -> library path: how the plugin's rows map back to files."""
        con = db_ro()
        try:
            return {(Path(r["path"]).parent.name, r["filename"]): r["path"]
                    for r in con.execute("SELECT path, filename FROM images")}
        finally:
            con.close()

    def ingest_catalog(con, path: Path, by_key: dict) -> int:
        """Upsert lr_state from a catalog file. Photos the sync didn't cover keep their old row."""
        at, rows = now_iso(), []
        for line in path.read_text(encoding="utf-8").splitlines():
            parts = line.split("\t")
            if not line or line.startswith("#") or len(parts) < 6:
                continue
            lib = by_key.get((parts[0], parts[1]))
            d = day_of(lib) if lib else None
            if not d:
                continue
            try:
                rows.append((lib, d, int(parts[2]), int(parts[3]), parts[4], parts[5], at))
            except ValueError:
                continue
        con.executemany("INSERT OR REPLACE INTO lr_state(path, day, pick, rating, flag_by, stars_by, seen_at) "
                        "VALUES (?,?,?,?,?,?,?)", rows)
        return len(rows)

    def ingest_receipts() -> None:
        """Read receipts the plugin left in applied/ since last time. Each queued decision becomes
        landed, conflict (your own flag kept) or missing (not in the selection; sent again next
        time). A queued decision that a newer receipt doesn't mention was lost (written while the
        plugin was mid-sync, then deleted with its input), so it is written to the inbox again."""
        applied = inbox / "applied"
        if not applied.is_dir():
            return
        with lock:
            con = anno_db()
            try:
                seen = {r["name"] for r in con.execute("SELECT name FROM cull_receipts")}
                fresh = sorted(p for p in applied.iterdir() if RECEIPT_RE.match(p.name) and p.name not in seen)
                lost: dict[str, dict] = {}
                by_key = None
                for rp in fresh:
                    m = RECEIPT_RE.match(rp.name)
                    if m[2] == "catalog":
                        if by_key is None:
                            by_key = library_keys()
                        n = ingest_catalog(con, rp, by_key)
                        con.execute("INSERT INTO cull_receipts(name, read_at, rows) VALUES (?,?,?)", (rp.name, now_iso(), n))
                        continue
                    stamp = datetime.strptime(m[1], "%Y%m%d-%H%M%S")
                    outcomes: dict[tuple, dict] = {}
                    for line in rp.read_text(encoding="utf-8").splitlines():
                        parts = line.split("\t")
                        if line and not line.startswith("#") and len(parts) >= 3:
                            outcomes.setdefault((parts[0], parts[1]), {})[parts[2]] = parts[3] if len(parts) > 3 else ""
                    for d in [dict(r) for r in con.execute("SELECT * FROM cull_decisions WHERE state='queued'")]:
                        p = Path(d["path"])
                        out = outcomes.get((p.parent.name, p.name))
                        if not out:
                            if d["sent_at"] and datetime.fromisoformat(d["sent_at"]) < stamp - LOST_AFTER:
                                lost[d["path"]] = d
                            continue
                        lost.pop(d["path"], None)
                        if "your_flag_kept" in out:
                            state, outcome = "conflict", out["your_flag_kept"]
                        elif "missing" in out:
                            state, outcome = "missing", "not in the Lightroom selection"
                        elif "applied" in out:
                            state, outcome = "landed", ("your " + out["your_stars_kept"] + " kept") if "your_stars_kept" in out else None
                        else:
                            continue
                        con.execute("UPDATE cull_decisions SET state=?, outcome=?, landed_at=? WHERE path=?",
                                    (state, outcome, now_iso() if state == "landed" else None, d["path"]))
                    con.execute("INSERT INTO cull_receipts(name, read_at, rows) VALUES (?,?,?)",
                                (rp.name, now_iso(), sum(len(v) for v in outcomes.values())))
                if lost and inbox_problem() is None:
                    queue_decisions(con, list(lost.values()))
                con.commit()
            finally:
                con.close()

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
        ingest_receipts()
        now = time.time()
        if cache["days"] is None or now - cache["days_at"] > DAYS_TTL_S:
            by_day = library_rows()
            summary = []
            stack_paths = {}
            for d, rows in by_day.items():
                st = stacks.build_stacks(rows)
                stack_paths[d] = [[f["path"] for f in s["frames"]] for s in st]
                towns = {}
                for r in rows:
                    if r.get("place"):
                        towns[r["place"]] = towns.get(r["place"], 0) + 1
                ranked = sorted(towns, key=towns.get, reverse=True)
                lead_ids = [s["lead"] for s in st]
                summary.append({
                    "day": d, "folder": d.rsplit("/", 1)[-1], "date": day_date(d),
                    "frames": sum(1 + len(f["partners"]) for s in st for f in s["frames"]),
                    "stacks": len(st),
                    "thumbs": [lead_ids[i * len(lead_ids) // 3] for i in range(min(3, len(lead_ids)))],
                    "last_ts": max((r["capture_ts"] or 0) for r in rows),
                    "place": ranked[0] if ranked else None,         # the town most frames were near
                    "places": ranked[:4],
                    "gps_frames": sum(towns.values()),
                })
            summary.sort(key=lambda x: (x["date"] or "", x["last_ts"]), reverse=True)
            cache.update(days=summary, days_at=now, stack_paths=stack_paths)
        con = anno_db()
        try:
            decided = {r["day"]: (r["n"], r["sent"], r["landed"], r["conflicts"]) for r in con.execute(
                "SELECT day, COUNT(*) n, SUM(state!='draft') sent, SUM(state='landed') landed, "
                "SUM(state='conflict') conflicts FROM cull_decisions GROUP BY day")}
            days_state = {r["day"]: dict(r) for r in con.execute("SELECT * FROM cull_days")}
            # what you did in Lightroom: a reject flag rejects; a pick flag or any star rating
            # (without a reject) means you have already been through the photo
            lr = {}
            for r in con.execute("SELECT path, pick, rating, flag_by, stars_by FROM lr_state "
                                 "WHERE (flag_by='you' AND pick != 0) OR (stars_by='you' AND rating > 0)"):
                rejected = r["flag_by"] == "you" and r["pick"] == -1
                lr[r["path"]] = -1 if rejected else 1
        finally:
            con.close()
        out = []
        for d in cache["days"]:
            n, sent, landed, conflicts = decided.get(d["day"], (0, 0, 0, 0))
            ds = days_state.get(d["day"], {})
            # a stack is culled in Lightroom when you picked a frame there, or rejected all of them
            lr_done = sum(1 for paths in cache["stack_paths"].get(d["day"], [])
                          if any(lr.get(p) == 1 for p in paths) or all(lr.get(p) == -1 for p in paths)) if lr else 0
            out.append(dict(d, decided=n, sent=sent, landed=landed, conflicts=conflicts, lr_done=lr_done,
                            finished=bool(ds.get("finished_at")), sent_at=ds.get("sent_at")))
        return jsonify({"days": out})

    @bp.route("/api/day/<path:day>")
    def api_day(day):
        ingest_receipts()
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
            lr = {r["path"]: dict(r) for r in con.execute(
                "SELECT path, pick, rating, flag_by, stars_by FROM lr_state WHERE day=?", (day,))}
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
                path = f.pop("path")
                l = lr.get(path)
                f["lr"] = ({"pick": l["pick"], "rating": l["rating"], "by": l["flag_by"], "stars_by": l["stars_by"]}
                           if l else None)
                d = dec.get(path)
                f["decision"] = ({k: d[k] for k in ("flag", "stars", "note", "state", "outcome")}
                                 if d else None)
                det = details.get(f["id"], {})
                f["lens"] = det.get("lens")
                f["caption"] = det.get("caption")
                f["blown_pct"] = det.get("blown_pct")
                f["mean_lum"] = det.get("mean_lum")
                f["place"] = det.get("place")
        return jsonify({
            "day": day, "folder": day.rsplit("/", 1)[-1], "date": day_date(day),
            "budget": {"stacks": stacks.keep_budget(rows), "per_hour": stacks.KEEP_PER_HOUR,
                       "hours": round(stacks.shooting_hours(rows), 2)},
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

    @bp.route("/api/day/<path:day>/send", methods=["POST"])
    @guarded
    def api_send(day):
        """Queue the day's unsent decisions for the next Lightroom sync. Decisions that landed or
        met your own flag (conflict) are not sent again unless you change them on the phone."""
        problem = inbox_problem()
        if problem:
            return jsonify({"error": problem + "; nothing was sent"}), 503
        ingest_receipts()
        with lock:
            con = anno_db()
            try:
                todo = [dict(r) for r in con.execute(
                    "SELECT * FROM cull_decisions WHERE day=? AND state IN ('draft','missing')", (day,))]
                rows = queue_decisions(con, todo) if todo else 0
                con.execute("""INSERT INTO cull_days(day, sent_at) VALUES (?,?)
                               ON CONFLICT(day) DO UPDATE SET sent_at=excluded.sent_at""", (day, now_iso()))
                con.commit()
            finally:
                con.close()
        return jsonify({"ok": True, "queued": len(todo), "file_rows": rows})

    @bp.route("/api/day/<path:day>/reset", methods=["POST"])
    @guarded
    def api_reset(day):
        """Start a day over on the phone: clear its decisions and its pass and position. Allowed
        until anything from the day reaches Lightroom; rows already queued in the inbox are
        withdrawn. (A sync running at that very moment may still apply what it already read.)"""
        ingest_receipts()
        with lock:
            con = anno_db()
            try:
                rows = [dict(r) for r in con.execute("SELECT path, state FROM cull_decisions WHERE day=?", (day,))]
                applied = sum(1 for r in rows if r["state"] in ("landed", "conflict"))
                if applied:
                    return jsonify({"error": f"{applied} decision(s) from this day are already in Lightroom; "
                                             "change those there", "applied": applied}), 409
                queued = [r["path"] for r in rows if r["state"] == "queued"]
                withdrawn = 0
                if queued:
                    problem = inbox_problem()
                    if problem:
                        return jsonify({"error": problem + "; nothing was reset"}), 503
                    partners = partner_paths(day)
                    withdrawn = remove_rows({(Path(p).parent.name, Path(p).name)
                                             for q in queued for p in [q] + partners.get(q, [])})
                con.execute("DELETE FROM cull_decisions WHERE day=?", (day,))
                con.execute("DELETE FROM cull_days WHERE day=?", (day,))
                con.commit()
            finally:
                con.close()
        return jsonify({"ok": True, "cleared": len(rows), "withdrawn": withdrawn})

    @bp.route("/api/crop/<int:rowid>")
    def api_crop(rowid):
        """A 1:1 crop from the full RAW: centre (x, y) as fractions of the upright frame, size
        (w, h) in source pixels, each at most CROP_MAX."""
        try:
            x, y = float(request.args["x"]), float(request.args["y"])
            w = max(64, min(CROP_MAX, int(request.args.get("w", 1200))))
            h = max(64, min(CROP_MAX, int(request.args.get("h", 1200))))
        except (KeyError, ValueError):
            return jsonify({"error": "x and y are required"}), 400
        con = db_ro()
        try:
            r = con.execute("SELECT path FROM images WHERE rowid=?", (rowid,)).fetchone()
        finally:
            con.close()
        if not r:
            return jsonify({"error": "not found"}), 404
        try:
            im = full_decode(r["path"])
        except Exception as e:
            return jsonify({"error": f"decode failed: {pc._exc_text(e)[:120]}"}), 415
        W, H = im.size
        w, h = min(w, W), min(h, H)
        cx = min(max(x, 0.0), 1.0) * W
        cy = min(max(y, 0.0), 1.0) * H
        left = int(min(max(cx - w / 2, 0), W - w))
        top_ = int(min(max(cy - h / 2, 0), H - h))
        buf = io.BytesIO()
        im.crop((left, top_, left + w, top_ + h)).save(buf, "JPEG", quality=88)
        resp = Response(buf.getvalue(), mimetype="image/jpeg")
        resp.headers["Cache-Control"] = "max-age=3600"
        resp.headers["X-Crop-Box"] = f"{left},{top_},{w},{h} of {W}x{H}"
        return resp

    @bp.route("/api/gps-health")
    def api_gps_health():
        """For the Pi status page: does the newest Sony shoot carry GPS? The camera records
        location only while its phone link is up, and the link drops without a word -- it was
        off from Aug 2025 to Oct 2026 before anyone noticed. ok: half or more of the newest
        shoot's frames have GPS; warn: some; bad: none; pending: not geotagged yet."""
        con = db_ro()
        try:
            rows = con.execute(
                "SELECT path, capture_ts, gps_lat IS NOT NULL AS has_gps, gps_checked FROM images "
                "WHERE status='ok' AND camera LIKE 'SONY%' AND capture_ts IS NOT NULL").fetchall()
        finally:
            con.close()
        days: dict[str, dict] = {}
        last_gps = None
        for r in rows:
            d = day_of(r["path"])
            if not d:
                continue
            x = days.setdefault(d, {"day": d, "date": day_date(d), "frames": 0, "with_gps": 0, "unchecked": 0, "last_ts": 0})
            x["frames"] += 1
            x["with_gps"] += r["has_gps"]
            x["unchecked"] += r["gps_checked"] is None
            x["last_ts"] = max(x["last_ts"], r["capture_ts"])
            if r["has_gps"] and (last_gps is None or r["capture_ts"] > last_gps):
                last_gps = r["capture_ts"]
        recent = sorted(days.values(), key=lambda x: x["last_ts"], reverse=True)[:5]
        if not recent:
            return jsonify({"status": "pending", "recent": [], "reason": "no Sony frames yet"})
        latest = recent[0]
        if latest["unchecked"] == latest["frames"]:
            status = "pending"
        elif latest["with_gps"] * 2 >= latest["frames"]:
            status = "ok"
        else:
            status = "warn" if latest["with_gps"] else "bad"
        without_since = sum(1 for r in rows if last_gps is None or r["capture_ts"] > last_gps)
        return jsonify({
            "status": status,
            "latest": latest,
            "recent": recent,
            "last_gps": datetime.fromtimestamp(last_gps).date().isoformat() if last_gps else None,
            "without_since": without_since,
            "advice": "Re-pair the camera's location link: Creators' App (or Imaging Edge Mobile) > "
                      "Location Information Link, with the phone's Bluetooth on.",
        })

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
