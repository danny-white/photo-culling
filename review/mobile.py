"""Culling Bay Mobile: the phone app's routes, under /m.

A Flask blueprint that review/server.py registers. It reads trial.db read-only through the
server's db_ro(), and keeps the phone's own state in annotations.db (cull_* tables), which the
review server already owns. Stack rules live in stacks.py.
"""
from __future__ import annotations

import collections
import contextlib
import fcntl
import functools
import hashlib
import io
import json
import logging
import mimetypes
import os
import re
import sqlite3
import threading
import time
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import numpy as np
from flask import (Blueprint, Response, abort, jsonify, render_template_string, request,
                   send_file, send_from_directory, url_for)
from PIL import Image, ImageOps

import perf
import previews
import region_decode
import search
import stacks

log = logging.getLogger(__name__)

mimetypes.add_type("application/manifest+json", ".webmanifest")

LIBRARY_ROOT = "/mnt/passport/Pictures"
INBOX = Path("/mnt/Passport_AICullInbox")          # the narrow rw mount the watcher also writes
INBOX_SOURCE = "//mycloud/Passport/AICullInbox"     # ...and must come from this share (as in watch_ingest.sh)
INGEST_LOG = Path(__file__).resolve().parents[1] / "trial_out" / "ingest_watch.log"   # ops/watch_ingest.sh
KNOWN_UNREADABLE = INGEST_LOG.parent / "known-unreadable.txt"   # originals Danny has accepted as lost
OLLAMA_URL = "http://localhost:11434"
DECISIONS_FILE = "cull-decisions.tsv"
DECISIONS_HEADER = "#cull-decisions v1"
RECEIPT_RE = re.compile(r"^(\d{8}-\d{6})-(receipt|catalog)\.tsv$")   # the plugin's two report files
LOST_AFTER = timedelta(seconds=60)                   # sent this long before a receipt that lacks it
IMG_EDGE = {"thumb": 320, "view": 1616}   # 1616 = the embedded preview's full width
DAYS_TTL_S = 30
AS_IS = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".heic": "image/heic", ".heif": "image/heif"}
CROP_MAX = 2400          # longest side of a crop, in source pixels
FULL_CACHE_FRAMES = 16   # full decodes kept in memory (~127 MB each for 42 MP, ~2 GB in all)
DECODES_AT_ONCE = 2      # decodes someone is waiting for (a 1:1 check, an HD zoom, a save)
WARM_WORKERS = 2         # decode-ahead: RAWs decoded in the background once their picture is asked for
WARM_QUEUE = 4           # decode-ahead requests waiting; swiping fast drops the oldest

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
  cursor_path TEXT,
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
CREATE TABLE IF NOT EXISTS practice_state(
  id            TEXT PRIMARY KEY,
  status        TEXT NOT NULL,
  note          TEXT NOT NULL DEFAULT '',
  updated_at    TEXT NOT NULL,
  downloaded_at TEXT,
  done_at       TEXT);
"""

ROW_COLS = ("rowid, path, filename, capture_ts, camera, sharpness, exposure_flag, mean_lum, "
            "blown_pct, phash, place, drive, seq, ev, af_u, af_v")
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
        if request.headers.get("X-Culling-Bay") != "1":
            return jsonify({"error": "missing X-Culling-Bay header"}), 403
        if not request.is_json and request.get_data():
            return jsonify({"error": "missing JSON content type"}), 403
        if not isinstance(request.get_json(silent=True), dict):
            return jsonify({"error": "a JSON object body is required"}), 400
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


def read_known_unreadable(path: Path) -> set[str]:
    """Paths listed in known-unreadable.txt: one per line, `#` starts a comment (a whole line, or
    after a space), a missing file is an empty list."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return set()
    out = set()
    for line in text.splitlines():
        line = line.split(" #", 1)[0].strip()
        if line and not line.startswith("#"):
            out.add(line)
    return out


def tsv_row(path: str, d: dict) -> tuple[tuple[str, str], str]:
    """One cull-decisions.tsv line for a file, keyed like the plugin matches: (folder, file)."""
    p = Path(path)
    stars = str(d["stars"]) if d["flag"] == "pick" and d.get("stars") else ""
    note = (d.get("note") or "").replace("\t", " ").replace("\n", " ")
    return (p.parent.name, p.name), "\t".join((p.parent.name, p.name, d["flag"], stars, note))


def failure_reason(pc, e: Exception) -> tuple[str, bool]:
    """(one line saying what went wrong, whether it is a type of failure nobody expected). An
    unreadable or unsupported file (LoadError, OSError: the NAS, a bad RAW) says enough in a
    line; anything else is a bug, and its log entry keeps the traceback. The line is plain ASCII
    with no quotes, so it can also go in the Server-Timing header."""
    text = " ".join(pc._exc_text(e).replace('"', "'").split()).encode("ascii", "replace").decode()
    return f"{type(e).__name__}: {text}"[:120], not isinstance(e, (OSError, getattr(pc, "LoadError", OSError)))


def decode_failed(pc, rowid: int, path: str | None, e: Exception):
    """The 415 for a photo that would not decode. The phone gets the reason as before; the
    journal gets a warning naming the photo, and the request's timing line gets `error`."""
    reason, unexpected = failure_reason(pc, e)
    log.warning("decode failed for photo %s (%s): %s", rowid, Path(path).name if path else "unknown file",
                reason, exc_info=e if unexpected else None)
    perf.note(error=reason)
    return jsonify({"error": f"decode failed: {pc._exc_text(e)[:120]}"}), 415


def make_blueprint(*, db_ro, anno, pc, cache_dir: Path, static_dir: Path, state_dir: Path,
                   inbox: Path = INBOX, check_mount: bool = True, ingest_log: Path = INGEST_LOG,
                   known_unreadable: Path = KNOWN_UNREADABLE, ollama_url: str = OLLAMA_URL, ios_dir: Path | None = None,
                   raw_decoder=None, region_decoder=None, backup_status: Path | None = None,
                   prime_search: bool = False) -> Blueprint:
    """db_ro/anno: the server's connection helpers. pc: the photo_cull module (image loading).
    state_dir: where derived per-day data is cached (trial_out/mobile). inbox: where Send writes
    cull-decisions.tsv and the plugin leaves receipts; check_mount refuses to write unless it is
    the narrow AICullInbox mount (tests turn it off and pass a temp dir). known_unreadable: the
    list of originals pipeline-health stops reporting as unreadable. raw_decoder(path) ->
    PIL image replaces the rawpy decode (tests pass a fast fake); region_decoder(path, x, y, w, h)
    -> (image, box) replaces region_decode.decode_region for the offline crops. backup_status: the file
    ops/backup.sh writes after each run, read by the pipeline-health alerts (default: next to the DB).
    prime_search: after the search index is built, also load CLIP's text half and the caption model
    in Ollama (the server turns it on; tests leave it off, so they don't load a 250 MB model each)."""
    bp = Blueprint("mobile", __name__, url_prefix="/m")
    ios_dir = (ios_dir if ios_dir is not None else state_dir.parent / "ios").resolve()
    backup_status = backup_status if backup_status is not None else state_dir.parent / "backup-status.json"
    state_dir.mkdir(parents=True, exist_ok=True)
    pano_file = state_dir / "pano.json"
    practice_file = state_dir / "practice.json"
    practice_cache = {"stamp": object(), "items": [], "error": None}
    practice_lock = threading.Lock()
    lock = threading.Lock()
    cache = {"days": None, "days_at": 0.0, "days_key": None}
    full_cache: dict[str, Image.Image] = {}          # path -> full-resolution decode, oldest first
    full_lock = threading.Lock()
    decode_slots = threading.Semaphore(DECODES_AT_ONCE)
    offline_slots = threading.Semaphore(2)            # the phone saving days for offline: two at a time
    decoding: dict[str, threading.Event] = {}         # path -> set when its decode has finished
    ahead: set[str] = set()                           # decoded in the background, not yet used
    warm_pending: collections.deque[str] = collections.deque(maxlen=WARM_QUEUE)
    warm_cond = threading.Condition()

    def decode_raw(path: Path) -> Image.Image:
        if raw_decoder is not None:
            return raw_decoder(path)
        import rawpy
        with rawpy.imread(str(path)) as raw:
            return Image.fromarray(raw.postprocess(use_camera_wb=True))
    finder = search.Search(db_ro=db_ro, pc=pc, day_of=day_of, day_date=day_date, ollama_url=ollama_url,
                           library_root=LIBRARY_ROOT)

    def warm_search():   # the first search would otherwise wait a few seconds for the vectors to load
        try:
            finder.index()
            if prime_search:
                finder.prime()
        except Exception:  # noqa: BLE001 - a search will try again, and report what is wrong
            pass
    threading.Thread(target=warm_search, daemon=True, name="search-warm-up").start()

    def offline_decode(path: str) -> Image.Image:
        """A full decode for the phone's offline copy of a day (`keep=0` on a crop): one at a
        time beside the decodes someone is waiting for, and not kept, so saving a day doesn't
        push your recent 1:1s out of the cache. A frame already in memory is used as it is."""
        with full_lock:
            im = full_cache.get(path)
        if im is not None:
            perf.note(decode_cache="hit")
            return im
        perf.note(decode_cache="offline", ext=Path(path).suffix.lower())
        with perf.stage("decode_wait"):
            offline_slots.acquire()
        try:
            src = Path(path)
            with perf.stage("full_decode"):
                if src.suffix.lower() in stacks.RAW_EXTENSIONS:
                    return decode_raw(src)
                return ImageOps.exif_transpose(Image.open(src)).convert("RGB")
        finally:
            offline_slots.release()

    def full_decode(path: str, background: bool = False) -> Image.Image:
        """The whole frame at full resolution, upright. RAWs go through a full rawpy decode
        (about 2.5 s for a 42 MP ARW); anything else is opened directly. One decode per photo
        at a time: a request for a photo already being decoded (often decode-ahead's) waits for
        that decode instead of starting another. background: a decode-ahead, which neither
        records timings nor uses the slots kept for decodes someone is waiting for."""
        waited = False
        while True:
            with full_lock:
                im = full_cache.pop(path, None)
                if im is not None:
                    full_cache[path] = im             # most recently used goes last
                    if not background:
                        # hit: decoded for an earlier request; ahead: decode-ahead had it ready;
                        # ahead-wait: decode-ahead was still running and this waited for it.
                        first_use = path in ahead
                        ahead.discard(path)
                        perf.note(decode_cache=("ahead-wait" if waited else "ahead") if first_use else "hit")
                    return im
                running = decoding.get(path)
                if running is None:
                    decoding[path] = done = threading.Event()
                    break
            if background:
                return None                           # someone else is decoding it already
            with perf.stage("decode_wait"):           # decode-ahead (or another request) is on it
                running.wait(timeout=60)
            waited = True                             # then take it from the cache, or decode it
        try:
            if not background:
                perf.note(decode_cache="miss", ext=Path(path).suffix.lower())
                with perf.stage("decode_wait"):       # queued behind other full decodes
                    decode_slots.acquire()
            try:
                src = Path(path)
                with (perf.stage("full_decode") if not background else contextlib.nullcontext()):
                    if src.suffix.lower() in stacks.RAW_EXTENSIONS:
                        im = decode_raw(src)
                    else:
                        im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
            finally:
                if not background:
                    decode_slots.release()
            with full_lock:
                full_cache[path] = im
                if background:
                    ahead.add(path)
                while len(full_cache) > FULL_CACHE_FRAMES:
                    oldest = next(iter(full_cache))
                    del full_cache[oldest]
                    ahead.discard(oldest)
            return im
        finally:
            with full_lock:
                decoding.pop(path, None)
            done.set()

    def warm_decode(path: str) -> None:
        """Decode-ahead: a RAW's picture was just asked for (a card shown or pre-fetched, a
        photo in the viewer), so its 1:1 check or HD zoom is likely next. Queue a background
        decode unless it is cached, running or queued already."""
        if Path(path).suffix.lower() not in stacks.RAW_EXTENSIONS:
            return
        with full_lock:
            if path in full_cache or path in decoding:
                return
        with warm_cond:
            if path in warm_pending:
                return
            warm_pending.append(path)                 # a full queue drops its oldest request
            warm_cond.notify()

    def warm_worker() -> None:
        while True:
            with warm_cond:
                while not warm_pending:
                    warm_cond.wait()
                path = warm_pending.popleft()
            try:
                full_decode(path, background=True)
            except Exception as e:  # noqa: BLE001 - a failed decode-ahead is retried when asked for
                reason, unexpected = failure_reason(pc, e)
                log.warning("decode-ahead failed for %s: %s", Path(path).name, reason,
                            exc_info=e if unexpected else None)

    for _ in range(WARM_WORKERS):
        threading.Thread(target=warm_worker, daemon=True, name="decode-ahead").start()

    def anno_db() -> sqlite3.Connection:
        con = anno()
        try:
            con.executescript(SCHEMA)
            if "cursor_path" not in {r["name"] for r in con.execute("PRAGMA table_info(cull_days)")}:
                # Recheck under a database write lock: another worker may migrate it first.
                with con:
                    con.execute("BEGIN IMMEDIATE")
                    if "cursor_path" not in {r["name"] for r in con.execute("PRAGMA table_info(cull_days)")}:
                        con.execute("ALTER TABLE cull_days ADD COLUMN cursor_path TEXT")
        except Exception:
            con.close()
            raise
        return con

    def load_practice_file() -> tuple[list[dict], str | None]:
        """Read the hand-maintained challenge list again whenever practice.json changes."""
        try:
            st = practice_file.stat()
            stamp = (st.st_mtime_ns, st.st_size)
        except FileNotFoundError:
            stamp = None
        except OSError:
            stamp = ("unreadable",)
        with practice_lock:
            if stamp == practice_cache["stamp"]:
                return practice_cache["items"], practice_cache["error"]
            items, error = [], None
            if stamp == ("unreadable",):
                error = "practice.json could not be read"
            elif stamp is not None:
                try:
                    data = json.loads(practice_file.read_text(encoding="utf-8"))
                    raw = data.get("challenges") if isinstance(data, dict) else None
                    if not isinstance(raw, list):
                        raise ValueError("challenges must be a list")
                    seen = set()
                    for i, item in enumerate(raw):
                        if not isinstance(item, dict):
                            raise ValueError("challenge must be an object")
                        cid = item.get("id")
                        if not isinstance(cid, str) or not cid.strip() or len(cid) > 200 or cid in seen:
                            raise ValueError("challenge id is missing, invalid, or repeated")
                        seen.add(cid)
                        if not isinstance(item.get("path"), str) or not item["path"]:
                            raise ValueError("challenge path is missing")
                        for key in ("title", "aim", "why", "picked_by", "added"):
                            if not isinstance(item.get(key), str):
                                raise ValueError(f"challenge {key} must be a string")
                        if item.get("mode") not in ("phone", "mac"):
                            raise ValueError("challenge mode must be phone or mac")
                        if item.get("level") not in ("easy", "medium", "hard"):
                            raise ValueError("challenge level must be easy, medium, or hard")
                        if not isinstance(item.get("minutes"), int) or isinstance(item.get("minutes"), bool) or item["minutes"] < 1:
                            raise ValueError("challenge minutes must be a positive integer")
                        for key in ("tools", "hints"):
                            if key == "tools" and key not in item:
                                raise ValueError("challenge tools are missing")
                            values = item.get(key, [])
                            if not isinstance(values, list) or any(not isinstance(v, str) for v in values):
                                raise ValueError(f"challenge {key} must be a list of strings")
                        for key, kind in (("needs_desktop", bool), ("desktop_reason", str), ("companion_of", str)):
                            if key in item and not isinstance(item[key], kind):
                                raise ValueError(f"challenge {key} must be a {kind.__name__}")
                        items.append(dict(item))
                    # A companion names a Needs Desktop challenge in this file, which is not itself a companion.
                    by_id = {i["id"]: i for i in items}
                    for item in items:
                        if "companion_of" not in item:
                            continue
                        parent = by_id.get(item["companion_of"])
                        if parent is None or parent.get("needs_desktop") is not True or "companion_of" in parent:
                            raise ValueError("companion_of must name a Needs Desktop challenge")
                        if item.get("needs_desktop") is True:
                            raise ValueError("a companion cannot need the desktop")
                except (OSError, UnicodeError, json.JSONDecodeError, ValueError, TypeError, AttributeError) as e:
                    # Do not include file content or paths in this message.
                    error = "practice.json is malformed" if not isinstance(e, OSError) else "practice.json could not be read"
                    items = []
            practice_cache.update(stamp=stamp, items=items, error=error)
            return items, error

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

    def day_summaries() -> dict[str, str]:
        """{shoot folder path: two-line summary} from photo_cull.py daysum; empty before it runs."""
        con = db_ro()
        try:
            return {r["folder"]: r["summary"] for r in con.execute("SELECT folder, summary FROM day_summaries")}
        except sqlite3.OperationalError:
            return {}
        finally:
            con.close()

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

    def known_day(con, day: str) -> bool:
        """Accept library days or retained phone state, without building stacks."""
        if con.execute("SELECT 1 FROM cull_days WHERE day=?", (day,)).fetchone() or con.execute(
                "SELECT 1 FROM cull_decisions WHERE day=? LIMIT 1", (day,)).fetchone():
            return True
        library = db_ro()
        try:
            prefix = f"{LIBRARY_ROOT}/{day}/"
            # Unary + keeps SQLite on the path index instead of scanning the status index.
            return library.execute(
                "SELECT 1 FROM images WHERE +status='ok' AND path >= ? AND path < ? "
                "AND instr(substr(path, ?), '/')=0 LIMIT 1",
                (prefix, prefix[:-1] + "0", len(prefix) + 1)).fetchone() is not None
        finally:
            library.close()

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

    def withdraw_queued(day: str, decisions: list[dict]) -> int:
        """Withdraw queued paths and their partners. Caller checks the inbox before any changes."""
        queued = [d["path"] for d in decisions if d["state"] == "queued"]
        if not queued:
            return 0
        partners = partner_paths(day)
        return remove_rows({(Path(p).parent.name, Path(p).name)
                            for q in queued for p in [q] + partners.get(q, [])})

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

    # ---------------------------------------------------------------- routes: iPhone builds
    def ios_file(name):
        # Even a fixed-name symlink must stay inside the delivery directory.
        try:
            path = (ios_dir / name).resolve()
            if path.is_relative_to(ios_dir) and path.is_file():
                return path
        except (OSError, RuntimeError):
            pass
        return None

    def ios_metadata():
        path = ios_file("latest.json")
        if path is None:
            return None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if (not isinstance(data, dict)
                    or not all(isinstance(data.get(k), str) for k in
                               ("version", "git", "built_at", "sha256", "file"))
                    or type(data.get("build")) is not int or data["build"] < 0
                    or type(data.get("bytes")) is not int or data["bytes"] < 0
                    or data["file"] != f"CullingBay-{data['build']}.ipa"):
                return None
            datetime.fromisoformat(data["built_at"])
            return data
        except (OSError, ValueError):
            return None

    @bp.get("/ios/")
    def ios_index():
        latest = ios_metadata()
        previous = sorted(
            (p.name for p in ios_dir.glob("CullingBay-*.ipa")
             if re.fullmatch(r"CullingBay-[0-9]+\.ipa", p.name) and ios_file(p.name)
             and (latest is None or p.name != latest["file"])),
            key=lambda name: int(name[11:-4]), reverse=True)
        built = (datetime.fromisoformat(latest["built_at"]).astimezone()
                 .strftime("%Y-%m-%d %H:%M:%S %Z") if latest else "")
        html = render_template_string("""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Culling Bay builds</title><style>
:root { color-scheme: light dark; font: 17px/1.5 system-ui, sans-serif; }
body { max-width: 36rem; margin: auto; padding: 1.5rem; overflow-wrap: anywhere; }
h1 { font-size: 1.8rem; } a { color: light-dark(#174caa, #9fc4ff); }
.download { display: block; padding: 1rem; border-radius: .6rem; text-align: center;
background: #2055ae; color: white; font-weight: bold; text-decoration: none; }
dt { font-weight: bold; } dd { margin: 0 0 .6rem; }
li { margin: .6rem 0; }
</style></head><body><h1>Culling Bay builds</h1>
{% if latest %}<dl><dt>Version</dt><dd>{{ latest.version }}</dd>
<dt>Build</dt><dd>{{ latest.build }}</dd><dt>Git commit</dt><dd>{{ latest.git }}</dd>
<dt>Built (server local time)</dt><dd>{{ built }}</dd>
<dt>Size</dt><dd>{{ '%.1f'|format(latest.bytes / 1048576) }} MiB ({{ latest.bytes }} bytes)</dd></dl>
<a class="download" href="{{ url_for('mobile.ios_latest_ipa') }}">Download CullingBay.ipa</a>
<p>Download, then Share → SideStore, or open it from Files in SideStore.</p>
{% else %}<p>No build yet.</p>{% endif %}
<p><a href="{{ url_for('mobile.ios_source', _external=True) }}">SideStore source JSON</a>:
SideStore may refuse a plain-HTTP source; test this on the phone.</p>
{% if previous %}<h2>Previous builds</h2><ul>{% for name in previous %}
<li><a href="{{ url_for('mobile.ios_kept_ipa', name=name) }}">{{ name }}</a></li>
{% endfor %}</ul>{% endif %}</body></html>""", latest=latest, built=built, previous=previous)
        return Response(html, mimetype="text/html", headers={"Cache-Control": "no-cache"})

    def ios_download(name):
        path = ios_file(name)
        if path is None:
            return jsonify(error="iOS build not found"), 404
        response = send_file(path, as_attachment=True, download_name=name,
                             mimetype="application/octet-stream")
        response.headers["Cache-Control"] = "no-cache"
        return response

    @bp.get("/ios/CullingBay.ipa")
    def ios_latest_ipa():
        return ios_download("CullingBay.ipa")

    @bp.get("/ios/latest.json")
    def ios_latest():
        data = ios_metadata()
        return jsonify(data) if data else (jsonify(error="No iOS build yet"), 404)

    @bp.get("/ios/source.json")
    def ios_source():
        data = ios_metadata()
        if data is None:
            return jsonify(error="No iOS build yet"), 404
        # Use the versioned file so a source fetch and subsequent download agree.
        download = url_for("mobile.ios_kept_ipa", name=data["file"], _external=True)
        version = {"version": data["version"], "buildVersion": str(data["build"]),
                   "date": data["built_at"], "downloadURL": download, "size": data["bytes"]}
        return jsonify(name="Culling Bay", identifier="co.dannywhite.cullingbay.source", news=[],
                       apps=[{"name": "Culling Bay", "bundleIdentifier": "co.dannywhite.cullingbay",
                              "developerName": "Danny White",
                              "localizedDescription": "Browse and cull your photos with Culling Bay.",
                              "versions": [version], "version": data["version"],
                              "versionDate": data["built_at"], "downloadURL": download,
                              "size": data["bytes"]}])

    @bp.get("/ios/<path:name>")
    def ios_kept_ipa(name):
        # This also blocks unknown iOS paths from falling through to app_static.
        if not re.fullmatch(r"CullingBay-[0-9]+\.ipa", name):
            return jsonify(error="iOS build not found"), 404
        return ios_download(name)

    # ---------------------------------------------------------------- routes: app shell
    @bp.route("/")
    def app_index():
        return send_from_directory(static_dir, "index.html")

    @bp.route("/<path:p>")
    def app_static(p):
        if p.startswith("api/"):
            abort(404)
        return send_from_directory(static_dir, p)

    @bp.after_request
    def revalidate(resp):
        """JSON reads get an ETag, so the app can ask "anything new?" and get a bodiless 304."""
        if (request.method == "GET" and resp.status_code == 200 and resp.mimetype == "application/json"
                and not resp.direct_passthrough):
            resp.add_etag()
            resp.headers.setdefault("Cache-Control", "no-cache")
            resp.make_conditional(request)
        return resp

    # ---------------------------------------------------------------- routes: reads
    def refresh_days():
        """Rebuild the day list and each day's stacks when the cache is older than DAYS_TTL_S."""
        now = time.time()
        if cache["days"] is not None and now - cache["days_at"] <= DAYS_TTL_S:
            perf.note(days_cache="hit")
            return
        perf.note(days_cache="miss")
        with perf.stage("days_rebuild"):
            by_day = library_rows()
            sums = day_summaries()
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
                    "summary": sums.get(f"{LIBRARY_ROOT}/{d}"),
                })
            summary.sort(key=lambda x: (x["date"] or "", x["last_ts"]), reverse=True)
            stack_of = {p: (d, i) for d, sts in stack_paths.items() for i, paths in enumerate(sts) for p in paths}
            cache.update(days=summary, days_at=now, stack_paths=stack_paths, stack_of=stack_of)

    @bp.route("/api/days")
    def api_days():
        with perf.stage("receipts"):
            ingest_receipts()
        refresh_days()
        con = anno_db()
        try:
            decided = {r["day"]: (r["n"], r["sent"], r["landed"], r["conflicts"], r["unsent"]) for r in con.execute(
                "SELECT day, COUNT(*) n, SUM(state!='draft') sent, SUM(state='landed') landed, "
                "SUM(state='conflict') conflicts, SUM(state IN ('draft','missing')) unsent "
                "FROM cull_decisions GROUP BY day")}
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
            n, sent, landed, conflicts, unsent = decided.get(d["day"], (0, 0, 0, 0, 0))
            ds = days_state.get(d["day"], {})
            # a stack is culled in Lightroom when you picked a frame there, or rejected all of them
            lr_done = sum(1 for paths in cache["stack_paths"].get(d["day"], [])
                          if any(lr.get(p) == 1 for p in paths) or all(lr.get(p) == -1 for p in paths)) if lr else 0
            out.append(dict(d, decided=n, sent=sent, landed=landed, conflicts=conflicts, lr_done=lr_done,
                            finished=bool(ds.get("finished_at")), sent_at=ds.get("sent_at"), unsent=unsent))
        return jsonify({"days": out})

    @bp.route("/api/search")
    def api_search():
        """Days to review for a query: by words, places, dates, caption meaning and picture
        meaning (review/search.py). Each day comes with its matching photo ids."""
        q = request.args.get("q", "").strip()[:200]
        if not q:
            return jsonify({"error": "missing q"}), 400
        return jsonify(finder.search(q))

    @bp.route("/api/like/<int:rowid>")
    def api_like(rowid):
        """More like this: other days with photos like this one."""
        out = finder.like(rowid)
        if out is None:
            return jsonify({"error": "no such photo"}), 404
        return jsonify(out)

    @bp.route("/api/day/<path:day>")
    def api_day(day):
        with perf.stage("receipts"):
            ingest_receipts()
        with perf.stage("rows"):
            rows = day_rows(day)
        if not rows:
            return jsonify({"error": "no such day"}), 404
        with perf.stage("stacks"):
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
        progress = None
        if ds and ds["pass"] is not None:
            cursor = ds["cursor"]
            if ds["cursor_path"]:
                path_by_id = {r["rowid"]: r["path"] for r in rows}
                cursor = next((i for i, s in enumerate(day_stacks) for f in s["frames"]
                               if ds["cursor_path"] == f["path"] or any(
                                   path_by_id.get(pid) == ds["cursor_path"] for pid in f["partner_ids"])), cursor)
            progress = {"pass": ds["pass"], "cursor": cursor}
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
            "summary": day_summaries().get(f"{LIBRARY_ROOT}/{day}"),
            "budget": {"stacks": stacks.keep_budget(rows), "per_hour": stacks.KEEP_PER_HOUR,
                       "hours": round(stacks.shooting_hours(rows), 2)},
            "stacks": day_stacks,
            "progress": progress,
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
        body = request.get_json(silent=True)
        action_id, day, changes = body.get("action_id"), body.get("day"), body.get("changes")
        if not isinstance(action_id, str) or not action_id or not isinstance(day, str) or not day:
            return jsonify({"error": "action_id, day and changes are required"}), 400
        if not isinstance(changes, list) or not changes:
            return jsonify({"error": "changes must be a non-empty list of objects"}), 400
        if body.get("label") is not None and not isinstance(body["label"], str):
            return jsonify({"error": "label must be a string or null"}), 400
        for c in changes:
            if (not isinstance(c, dict) or c.get("flag") not in FLAGS or c.get("via") not in VIAS
                    or type(c.get("id")) is not int):
                return jsonify({"error": f"bad change: {c}"}), 400
            if c["flag"] == "pick" and c.get("stars") is not None and (
                    type(c["stars"]) is not int or not 1 <= c["stars"] <= 5):
                return jsonify({"error": "pick stars must be an int from 1 to 5 or null"}), 400
            if c.get("note") is not None and not isinstance(c["note"], str):
                return jsonify({"error": "note must be a string or null"}), 400
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
                if any(d["state"] == "queued" for d in before.values()):
                    problem = inbox_problem()
                    if problem:
                        return jsonify({"error": problem + "; nothing was changed"}), 503
                withdraw_queued(day, list(before.values()))
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
        action_id = request.get_json(silent=True).get("action_id")
        if not isinstance(action_id, str) or not action_id:
            return jsonify({"error": "action_id must be a non-empty string"}), 400
        ingest_receipts()   # a receipt not read yet may say the action already landed
        with lock:
            con = anno_db()
            try:
                a = con.execute("SELECT * FROM cull_actions WHERE action_id=?", (action_id,)).fetchone()
                if not a:
                    return jsonify({"error": "unknown action"}), 404
                if a["undone"]:
                    return jsonify({"ok": True, "replay": True})
                before = json.loads(a["before"])
                q = ",".join("?" * len(before))
                current = [dict(r) for r in con.execute(
                    f"SELECT path, state FROM cull_decisions WHERE path IN ({q})", list(before))]
                applied = sum(r["state"] in ("landed", "conflict") for r in current)
                if applied:
                    return jsonify({"error": f"{applied} decision(s) from this action are already in Lightroom; "
                                             "change those there", "applied": applied}), 409
                restore_queued = [r for r in before.values() if r and r["state"] == "queued"]
                if restore_queued or any(r["state"] == "queued" for r in current):
                    problem = inbox_problem()
                    if problem:
                        return jsonify({"error": problem + "; nothing was undone"}), 503
                withdraw_queued(a["day"], current)
                for path, row in before.items():
                    if row is None:
                        con.execute("DELETE FROM cull_decisions WHERE path=?", (path,))
                    else:
                        cols = list(row)
                        con.execute(
                            f"INSERT OR REPLACE INTO cull_decisions({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
                            [row[c] for c in cols])
                if restore_queued:
                    queue_decisions(con, restore_queued)
                con.execute("UPDATE cull_actions SET undone=1 WHERE action_id=?", (action_id,))
                con.commit()
            finally:
                con.close()
        return jsonify({"ok": True})

    @bp.route("/api/day/<path:day>/progress", methods=["PUT"])
    @guarded
    def api_progress(day):
        body = request.get_json(silent=True)
        p, cur = body.get("pass"), body.get("cursor")
        if type(p) is not int or p not in (1, 2) or type(cur) is not int:
            return jsonify({"error": "pass (1 or 2) and cursor are required"}), 400
        if "finished" in body and type(body["finished"]) is not bool:
            return jsonify({"error": "finished must be a bool"}), 400
        cursor_path = None
        if body.get("lead") is not None:     # null is the same as leaving it out
            if type(body["lead"]) is not int:
                return jsonify({"error": "lead must be an int"}), 400
            cursor_path = paths_for([body["lead"]]).get(body["lead"])
            if cursor_path is None or day_of(cursor_path) != day:
                return jsonify({"error": "unknown frame, or a frame from another day"}), 400
        con = anno_db()
        try:
            if not known_day(con, day):
                return jsonify({"error": "no such day"}), 404
            con.execute(
                """INSERT INTO cull_days(day, pass, cursor, cursor_path, finished_at) VALUES (?,?,?,?,?)
                   ON CONFLICT(day) DO UPDATE SET pass=excluded.pass, cursor=excluded.cursor,
                     cursor_path=excluded.cursor_path,
                     finished_at=COALESCE(excluded.finished_at, cull_days.finished_at)""",
                (day, p, cur, cursor_path, now_iso() if body.get("finished") else None))
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
        if not problem:
            ingest_receipts()
        with lock:
            con = anno_db()
            try:
                if not known_day(con, day):
                    return jsonify({"error": "no such day"}), 404
                if problem:
                    return jsonify({"error": problem + "; nothing was sent"}), 503
                queued, rows, _ = send_days(con, [day])
                con.commit()
            finally:
                con.close()
        return jsonify({"ok": True, "queued": queued, "file_rows": rows})

    def send_days(con, days: list[str]) -> tuple[int, int, dict[str, int]]:
        """Queue these days' unsent decisions (draft, or missing from the last sync) in one write
        to the inbox file, and stamp each day sent. Returns (decisions, file rows, per day)."""
        per_day, todo = {}, []
        for day in days:
            rows = [dict(r) for r in con.execute(
                "SELECT * FROM cull_decisions WHERE day=? AND state IN ('draft','missing')", (day,))]
            per_day[day] = len(rows)
            todo += rows
        file_rows = queue_decisions(con, todo) if todo else 0
        at = now_iso()
        con.executemany("""INSERT INTO cull_days(day, sent_at) VALUES (?,?)
                           ON CONFLICT(day) DO UPDATE SET sent_at=excluded.sent_at""", [(d, at) for d in days])
        return len(todo), file_rows, per_day

    @bp.route("/api/send", methods=["POST"])
    @guarded
    def api_send_days():
        """Send to Lightroom for several days at once (the Cull tab's Send all): one write to
        the inbox file for every day listed."""
        body = request.get_json(silent=True) or {}
        days = body.get("days")
        if not isinstance(days, list) or not days or len(days) > 1000 or not all(isinstance(d, str) for d in days):
            return jsonify({"error": "days must be a non-empty list of day ids"}), 400
        days = list(dict.fromkeys(days))
        problem = inbox_problem()
        if not problem:
            ingest_receipts()
        with lock:
            con = anno_db()
            try:
                unknown = [d for d in days if not known_day(con, d)]
                if unknown:
                    return jsonify({"error": "no such day: " + ", ".join(unknown[:5])}), 404
                if problem:
                    return jsonify({"error": problem + "; nothing was sent"}), 503
                queued, rows, per_day = send_days(con, days)
                con.commit()
            finally:
                con.close()
        return jsonify({"ok": True, "queued": queued, "file_rows": rows,
                        "days": [{"day": d, "queued": per_day[d]} for d in days]})

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
                if not known_day(con, day):
                    return jsonify({"error": "no such day"}), 404
                rows = [dict(r) for r in con.execute("SELECT path, state FROM cull_decisions WHERE day=?", (day,))]
                applied = sum(1 for r in rows if r["state"] in ("landed", "conflict"))
                if applied:
                    return jsonify({"error": f"{applied} decision(s) from this day are already in Lightroom; "
                                             "change those there", "applied": applied}), 409
                if any(r["state"] == "queued" for r in rows):
                    problem = inbox_problem()
                    if problem:
                        return jsonify({"error": problem + "; nothing was reset"}), 503
                withdrawn = withdraw_queued(day, rows)
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
        if request.args.get("keep") == "0":
            # The phone saving a day for offline: a RAW not already in memory is decoded for the
            # crop's area only (region_decode, ~0.35 s against ~1.4 s for the whole frame).
            made = offline_region(r["path"], x, y, w, h)
            if made is not None:
                crop, (left, top_, w, h, W, H) = made
                return crop_response(crop, left, top_, w, h, W, H)
        try:
            # keep=0 otherwise: the whole frame decoded aside, not cached
            im = offline_decode(r["path"]) if request.args.get("keep") == "0" else full_decode(r["path"])
        except Exception as e:
            return decode_failed(pc, rowid, r["path"], e)
        W, H = im.size
        w, h = min(w, W), min(h, H)
        cx = min(max(x, 0.0), 1.0) * W
        cy = min(max(y, 0.0), 1.0) * H
        left = int(min(max(cx - w / 2, 0), W - w))
        top_ = int(min(max(cy - h / 2, 0), H - h))
        return crop_response(im.crop((left, top_, left + w, top_ + h)), left, top_, w, h, W, H)

    def crop_response(crop: Image.Image, left: int, top: int, w: int, h: int, W: int, H: int) -> Response:
        buf = io.BytesIO()
        with perf.stage("encode"):
            # Quality 80: a third smaller than 88 (317 KB to 215 KB for a 1200 px tile), with no
            # difference you can see at 1:1; the transfer to the phone is most of a zoom's wait.
            crop.save(buf, "JPEG", quality=80)
        resp = Response(buf.getvalue(), mimetype="image/jpeg")
        resp.headers["Cache-Control"] = "max-age=3600"
        resp.headers["X-Crop-Box"] = f"{left},{top},{w},{h} of {W}x{H}"
        return resp

    def offline_region(path: str, x: float, y: float, w: int, h: int):
        """(crop, box) for an offline crop of a RAW not already in memory, or None to decode the
        whole frame instead (in memory already, not a RAW, or a RAW region_decode can't read)."""
        if Path(path).suffix.lower() not in stacks.RAW_EXTENSIONS:
            return None
        with full_lock:
            if path in full_cache:
                return None
        decode = region_decoder or region_decode.decode_region
        with perf.stage("decode_wait"):
            offline_slots.acquire()
        try:
            with perf.stage("region_decode"):
                made = decode(path, x, y, w, h)
            perf.note(decode_cache="region", ext=Path(path).suffix.lower())
            return made
        except Exception as e:  # noqa: BLE001 - an unusual sensor layout: decode it whole instead
            log.info("region decode fell back for %s: %s", Path(path).name, pc._exc_text(e)[:120])
            return None
        finally:
            offline_slots.release()

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

    @bp.route("/api/pipeline-health")
    def api_pipeline_health():
        """For the Pi status page: problems in the photo pipeline that don't stop the ingest, so
        never turn its systemd unit red. The search model vanished from Ollama in Aug 2026 and
        1,625 photos went unindexed for seven weeks unnoticed. Each alert reads the pipeline's
        current state, not the log, so it clears itself once fixed; the log only adds history."""
        alerts: list[dict] = []
        def alert(level, title, detail, fix=""):
            alerts.append({"level": level, "title": title, "detail": detail, "fix": fix})
        cutoff = (datetime.now(timezone.utc) - timedelta(minutes=30)).isoformat(timespec="seconds")
        con = db_ro()
        try:
            ok = con.execute("SELECT COUNT(*) FROM images WHERE status='ok'").fetchone()[0]
            unindexed = con.execute(
                "SELECT COUNT(*) FROM images i WHERE status='ok' AND COALESCE(processed_at, '') < ? AND NOT EXISTS "
                "(SELECT 1 FROM embeddings e WHERE e.path = i.path AND e.embed_version = ?)",
                (cutoff, pc.EMBED_VERSION)).fetchone()[0]
            nopic = con.execute(
                "SELECT COUNT(*) FROM images i WHERE status='ok' AND COALESCE(processed_at, '') < ? AND NOT EXISTS "
                "(SELECT 1 FROM embeddings e WHERE e.path = i.path AND e.embed_version = ?)",
                (cutoff, pc.CLIP_VERSION)).fetchone()[0]
            noshot = con.execute("SELECT COUNT(*) FROM images WHERE status='ok' AND shot_checked IS NULL "
                                 "AND COALESCE(processed_at, '') < ?", (cutoff,)).fetchone()[0]
            ungeo = con.execute("SELECT COUNT(*) FROM images WHERE status='ok' AND gps_checked IS NULL "
                                "AND COALESCE(processed_at, '') < ?", (cutoff,)).fetchone()[0]
            folders: dict[str, str] = {}
            for r in con.execute("SELECT path, processed_at FROM images WHERE status='ok'"):
                f = os.path.dirname(r["path"])
                folders[f] = max(folders.get(f, ""), r["processed_at"] or "")
            summed = {r["folder"] for r in con.execute("SELECT folder FROM day_summaries")}
            errored = con.execute("SELECT COUNT(*) FROM images WHERE status='error'").fetchone()[0]
            # Failed photos: those another try can still help, and those no try will (empty files,
            # or all their tries used). The same test as photo_cull's `--retry-failed`.
            retrying = con.execute(f"SELECT path, error_class FROM images WHERE {pc.RETRYABLE_SQL}").fetchall()
            unreadable_all = con.execute(
                f"SELECT path, size, error_class, error_msg FROM images WHERE status='error' "
                f"AND NOT ({pc.RETRYABLE_SQL}) ORDER BY path").fetchall()
        finally:
            con.close()
        known = read_known_unreadable(known_unreadable)
        unreadable = [r for r in unreadable_all if r["path"] not in known]
        acknowledged = len(unreadable_all) - len(unreadable)

        def by_folder(rows) -> str:
            """'35 in 2026-09-29, 7 in 2026-06-27 and 5 in 2024-04-14' for the three biggest folders."""
            top = collections.Counter(os.path.basename(os.path.dirname(r["path"])) for r in rows).most_common(3)
            names = [f"{n} in {f}" for f, n in top]
            return ", ".join(names[:-1]) + " and " + names[-1] if len(names) > 1 else names[0]
        unsummed = sorted(f for f, t in folders.items() if f not in summed and t < cutoff)

        model = {"name": pc.EMBED_MODEL, "installed": None}
        try:
            with urllib.request.urlopen(ollama_url + "/api/tags", timeout=3) as r:
                names = [m.get("name", "") for m in json.load(r).get("models", [])]
            model["installed"] = any(n == pc.EMBED_MODEL or n.startswith(pc.EMBED_MODEL + ":") for n in names)
        except Exception as e:  # noqa: BLE001
            model["error"] = f"{type(e).__name__}"
        if model["installed"] is False:
            alert("bad", "Search model missing",
                  f"{pc.EMBED_MODEL} isn't installed in Ollama, so photo search fails and new shoots go unindexed.",
                  f"ollama pull {pc.EMBED_MODEL}")
        elif model["installed"] is None:
            alert("warn", "Ollama not answering", "Search queries and new shoots' indexing need it.",
                  "systemctl status ollama")
        if unindexed:
            alert("bad" if unindexed >= 200 else "warn", f"{unindexed:,} photos not searchable",
                  "They have no search embedding.",
                  "cd ~/photo-culling && ./venv/bin/python photo_cull.py embed --db trial_out/trial.db")
        if not (pc.CLIP_DIR / "visual" / "model.onnx").exists():
            alert("warn", "Picture search model missing", f"No CLIP model in {pc.CLIP_DIR}, so More like this "
                  "and searches by what's in a picture are off.",
                  f"Download visual/ and textual/ from huggingface.co/immich-app/{pc.CLIP_MODEL}")
        elif nopic:
            alert("warn", f"{nopic:,} photos without picture search", "They have no picture embedding yet.",
                  "cd ~/photo-culling && ./venv/bin/python photo_cull.py embed-images --db trial_out/trial.db")
        if ungeo:
            alert("warn", f"{ungeo:,} photos not geotagged", "Their GPS and nearest town were never read.",
                  "cd ~/photo-culling && ./venv/bin/python photo_cull.py geotag --db trial_out/trial.db")
        if noshot:
            alert("warn", f"{noshot:,} photos without shot info", "Their drive mode and AF point were never read, "
                  "so their stacks use the 2-second rule and the focus check opens at the centre.",
                  "cd ~/photo-culling && ./venv/bin/python photo_cull.py shotinfo --db trial_out/trial.db")
        if unsummed:
            alert("warn", f"{len(unsummed)} day{'s' if len(unsummed) > 1 else ''} without a summary",
                  ", ".join(os.path.basename(f) for f in unsummed[:4]) + (" …" if len(unsummed) > 4 else ""),
                  "cd ~/photo-culling && ./venv/bin/python photo_cull.py daysum --db trial_out/trial.db")
        if retrying:
            n = len(retrying)
            classes = ", ".join(f"{k} ({c})" for k, c in collections.Counter(
                r["error_class"] or "unknown" for r in retrying).most_common())
            alert("warn", f"{n:,} photo{'s' if n > 1 else ''} waiting for a retry",
                  f"Tagging failed for {by_folder(retrying)}. Causes: {classes}.",
                  f"The watcher retries them every 15 minutes, up to {pc.MAX_ATTEMPTS} tries each. To do it now: "
                  "cd ~/photo-culling && ./venv/bin/python photo_cull.py run <folder> --db trial_out/trial.db --retry-failed")
        if unreadable:
            n = len(unreadable)
            names = ", ".join(os.path.basename(r["path"]) for r in unreadable[:3])
            alert("warn", f"{n:,} original{'s' if n > 1 else ''} can't be read",
                  f"{by_folder(unreadable)}, for example {names}. They are empty, damaged or out of retries, "
                  "so they never reach Culling Bay.",
                  "Look for another copy (the camera card, another drive). If they are gone for good, list their paths "
                  "in ~/photo-culling/trial_out/known-unreadable.txt (one per line) to silence this.")
        mount = None
        if check_mount:
            mount = inbox_problem()
            if mount:
                alert("bad", "Ingest is stopped", f"{mount}; the watcher refuses to write until it is.",
                      "Remount the AICull inbox (see ~/nas-drive/docs/open-tasks.md)")

        # The watcher's log, last 7 days: failures, each marked resolved where the state says so.
        # "last_ingest" is the last shoot it finished; "last_poll" is the newest timestamped line,
        # which the watcher writes at least once an hour (a "poll:" line) even when nothing changed.
        recent, last, last_poll = [], None, None
        week = datetime.now().astimezone() - timedelta(days=7)
        log_mtime = None
        try:
            with open(ingest_log, "rb") as fh:
                log_mtime = datetime.fromtimestamp(os.fstat(fh.fileno()).st_mtime).astimezone()
                fh.seek(0, 2)
                fh.seek(max(0, fh.tell() - 600_000))
                tail = fh.read().decode("utf-8", "replace").splitlines()[1:]
        except OSError:
            tail = []
        done_after: dict[str, str] = {}
        for line in tail:
            m = re.match(r"^\[([^\]]+)\] (.*)$", line)
            if not m:
                continue
            try:
                at = datetime.fromisoformat(m.group(1))
            except ValueError:
                continue
            last_poll = at if last_poll is None or at > last_poll else last_poll
            msg = m.group(2)
            if msg.startswith("poll:"):          # the heartbeat: never a failure, whatever it says
                continue
            if msg.startswith("done: "):
                done_after[msg[6:].split(" -> ")[0]] = m.group(1)
                last = {"at": at.isoformat(timespec="seconds"), "shoot": os.path.basename(msg[6:].split(" -> ")[0])}
            if at < week or not ("FAILED" in msg or msg.startswith("ABORT")) or msg.startswith("msmtp"):
                continue
            step = "inbox" if msg.startswith("ABORT") else msg.split(" ", 1)[0]
            folder = (re.search(r" for (\S+)", msg) or [None, ""])[1]
            recent.append({"at": at.isoformat(timespec="seconds"), "step": step, "folder": folder, "what": msg[:160]})
        for r in recent:
            r["resolved"] = {"embed": not unindexed, "embed-images": not nopic, "geotag": not ungeo, "shotinfo": not noshot, "daysum": not unsummed,
                             "inbox": check_mount and not mount}.get(
                r["step"], bool(r["folder"]) and done_after.get(r["folder"], "") > r["at"])
        if log_mtime is not None:
            # A single run can write no timestamped line for hours (a backlog ran 8 hours in
            # October) but it writes the log all the while, so the file's own time counts too.
            alive = max(last_poll, log_mtime) if last_poll else log_mtime
            silent = datetime.now().astimezone() - alive
            if silent > timedelta(hours=2):
                alert("bad", f"Ingest watcher hasn't run for {int(silent.total_seconds() // 3600)} hours",
                      "Nothing has been written to its log since "
                      f"{alive.strftime('%a %d %b %H:%M')}; it normally writes a line at least once an hour.",
                      "systemctl --user status photo-cull-ingest.timer photo-cull-ingest.service; "
                      "tail ~/photo-culling/trial_out/ingest_watch.log")
        for step in ("run", "export"):
            open_ = [r for r in recent if r["step"] == step and not r["resolved"]]
            if open_:
                alert("bad", f"Ingest {step} failing", f"{len(open_)} failure{'s' if len(open_) > 1 else ''} this week, last for "
                      f"{os.path.basename(open_[-1]['folder'])}; it retries every 15 minutes.", "tail ~/photo-culling/trial_out/ingest_watch.log")
        # The nightly backup (ops/backup.sh) leaves what it did in backup_status.
        backup = {"at": None, "ok": None, "last_ok_at": None, "folder": None, "push_ok": None}
        backup_fix = "tail ~/photo-culling/trial_out/backup.log"
        run_now = "systemctl --user start culling-bay-backup.service"
        try:
            bk = json.loads(backup_status.read_text(encoding="utf-8"))
            if not isinstance(bk, dict):
                raise ValueError("not an object")
        except FileNotFoundError:
            bk = None
            alert("warn", "No backup yet", "Phone decisions and the photo index are on this PC's disk only.", run_now)
        except (OSError, ValueError):
            bk = None
            alert("warn", "Backup status unreadable", f"{backup_status.name} is not valid, so nothing says whether "
                  "the last backup worked.", run_now)
        if bk is not None:
            def when(v):
                try:
                    t = datetime.fromisoformat(v)
                except (TypeError, ValueError):
                    return None
                return t if t.tzinfo else t.astimezone()
            push = bk.get("push") if isinstance(bk.get("push"), dict) else {}
            ran = when(bk.get("at"))
            good = when(bk.get("last_ok_at")) or (ran if bk.get("ok") is True else None)
            backup.update({"at": bk.get("at"), "ok": bk.get("ok"), "folder": bk.get("folder"),
                           "last_ok_at": good.isoformat(timespec="seconds") if good else None,
                           "push_ok": push.get("ok")})
            if bk.get("ok") is False:
                alert("bad", f"Last backup failed: {bk.get('error') or 'no reason recorded'}"[:200],
                      "Nothing new was saved by that run." + (f" The last good backup was on {good.date().isoformat()}."
                                                              if good else " No backup has worked yet."),
                      f"{backup_fix}, then {run_now}")
            if good is not None:
                days = (datetime.now().astimezone() - good).days
                if days >= 2:
                    alert("bad" if days >= 4 else "warn", f"Backup is {days} days old",
                          f"The last good backup was on {good.date().isoformat()}. The timer runs a backup every "
                          "night the PC is on.", f"{backup_fix}, then {run_now}")
            if push.get("ok") is False:
                alert("warn", f"GitHub push didn't go through: {push.get('message') or 'no reason recorded'}"[:200],
                      "The newest commits are on this PC only.",
                      "cd ~/photo-culling && git status -sb  (the reason is also in trial_out/backup.log)")
        status = "bad" if any(a["level"] == "bad" for a in alerts) else "warn" if alerts else "ok"
        return jsonify({
            "status": status, "alerts": alerts, "checked_at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "index": {"ok": ok, "unindexed": unindexed, "no_picture": nopic, "no_shot_info": noshot, "ungeotagged": ungeo, "unsummarised": len(unsummed),
                      "days": len(folders), "caption_errors": errored, "retrying": len(retrying),
                      "unreadable": len(unreadable), "acknowledged_unreadable": acknowledged,
                      "unreadable_files": [{"path": r["path"], "size": r["size"],
                                            "error": r["error_msg"] or r["error_class"]} for r in unreadable[:100]]},
            "model": model, "last_ingest": last, "recent": recent[-8:],
            "backup": backup,
            "last_poll": last_poll.isoformat(timespec="seconds") if last_poll else None,
        })

    # ---------------------------------------------------------------- routes: timing
    @bp.route("/api/perf", methods=["POST"])
    @guarded
    def api_perf():
        """Measurements from the phone pages (image load times, swipe-to-photo, ...), written
        to the timing log as kind "client". See review/perf.py."""
        items = (request.get_json(silent=True) or {}).get("items")
        if not isinstance(items, list):
            return jsonify({"error": "items must be a list"}), 400
        return jsonify({"logged": perf.client_lines(items, request.remote_addr, request.headers.get("User-Agent", ""))})

    # ---------------------------------------------------------------- routes: gallery
    # A read-only view for finding and showing photos (static/m/gallery.html). Nothing here
    # writes decisions; Save makes a JPEG for the phone's camera roll.
    def gallery_items(ids: list[int], *, best: bool, bursts: bool) -> list[dict]:
        """Details for photos in the given order. best: only photos you picked or gave 3+
        stars, in Lightroom or on the phone. bursts: one photo per stack (the first one listed)."""
        if not ids:
            return []
        refresh_days()
        with perf.stage("details"):
            return _gallery_items(ids, best=best, bursts=bursts)

    def _gallery_items(ids: list[int], *, best: bool, bursts: bool) -> list[dict]:
        con = db_ro()
        try:
            q = ",".join("?" * len(ids))
            rows = {r["rowid"]: dict(r) for r in con.execute(
                f"SELECT rowid, path, filename, size, capture_ts, camera, lens, caption, place FROM images "
                f"WHERE rowid IN ({q})", ids)}
        finally:
            con.close()
        paths = [r["path"] for r in rows.values()]
        con = anno_db()
        try:
            q = ",".join("?" * len(paths))
            lr = {r["path"]: (r["pick"], r["rating"]) for r in con.execute(
                f"SELECT path, pick, rating FROM lr_state WHERE path IN ({q})", paths)}
            phone = {r["path"]: (r["flag"], r["stars"]) for r in con.execute(
                f"SELECT path, flag, stars FROM cull_decisions WHERE path IN ({q})", paths)}
        finally:
            con.close()
        out, seen = [], set()
        for rid in ids:
            r = rows.get(rid)
            if not r:
                continue
            pick, rating = lr.get(r["path"], (0, 0))
            flag, stars = phone.get(r["path"], (None, 0))
            stars = max(rating or 0, stars or 0)
            picked = pick == 1 or flag == "pick"
            rejected = pick == -1 or flag == "reject"
            if best and (rejected or not (picked or stars >= 3)):
                continue
            stack = cache["stack_of"].get(r["path"])
            if bursts and stack:
                if stack in seen:
                    continue
                seen.add(stack)
            day = day_of(r["path"])
            out.append({"id": rid, "day": day, "date": day_date(day) if day else None,
                        "ts": r["capture_ts"], "file": r["filename"], "bytes": r["size"], "camera": r["camera"],
                        "lens": r["lens"], "caption": r["caption"], "place": r["place"],
                        "stars": stars, "picked": picked, "rejected": rejected,
                        "raw": Path(r["path"]).suffix.lower() in stacks.RAW_EXTENSIONS})
        return out

    # --------------------------------------------------------------- practice
    @bp.get("/api/practice")
    def api_practice():
        configured, error = load_practice_file()
        if error:
            return jsonify(challenges=[], error=error)

        matched = []
        missing = 0
        if configured:
            con = db_ro()
            try:
                for challenge in configured:
                    row = con.execute("SELECT rowid FROM images WHERE path=? LIMIT 1", (challenge["path"],)).fetchone()
                    if row is None:
                        missing += 1
                    else:
                        matched.append((challenge, row["rowid"]))
            finally:
                con.close()

        photos = {p["id"]: p for p in gallery_items([rowid for _, rowid in matched], best=False, bursts=False)}
        con = anno_db()
        try:
            states = {r["id"]: dict(r) for r in con.execute("SELECT * FROM practice_state")}
        finally:
            con.close()

        out = []
        for challenge, rowid in matched:
            photo = photos.get(rowid)
            if photo is None:
                missing += 1
                continue
            item = {k: v for k, v in challenge.items() if k != "path"}
            state = states.get(challenge["id"], {})
            item.update({"photo": photo,
                         "status": state.get("status", "todo"),
                         "note": state.get("note", ""),
                         "updated_at": state.get("updated_at"),
                         "downloaded_at": state.get("downloaded_at"),
                         "done_at": state.get("done_at")})
            out.append(item)
        # A companion whose parent is missing from this answer stands alone, so null the link.
        present = {item["id"] for item in out}
        for item in out:
            item["needs_desktop"] = item.get("needs_desktop", False)
            item["desktop_reason"] = item.get("desktop_reason")
            if item.get("companion_of") not in present:
                item["companion_of"] = None
        for item in out:
            item["companions"] = [o["id"] for o in out if o["companion_of"] == item["id"]]
        return jsonify(challenges=out, missing=missing)

    @bp.post("/api/practice/<path:cid>")
    @guarded
    def api_practice_update(cid):
        configured, error = load_practice_file()
        if error or not any(c["id"] == cid for c in configured):
            return jsonify(error="unknown practice challenge"), 404
        body = request.get_json(silent=True) or {}
        if not body or set(body) - {"status", "note"}:
            return jsonify(error="body must contain status or note"), 400
        if "status" in body and (not isinstance(body["status"], str) or
                                  body["status"] not in {"todo", "downloaded", "done", "skipped"}):
            return jsonify(error="status must be todo, downloaded, done, or skipped"), 400
        if "note" in body and (not isinstance(body["note"], str) or len(body["note"]) > 2000):
            return jsonify(error="note must be a string up to 2000 characters"), 400

        con = anno_db()
        try:
            con.execute("BEGIN IMMEDIATE")
            old = con.execute("SELECT * FROM practice_state WHERE id=?", (cid,)).fetchone()
            old_state = dict(old) if old else {"status": "todo", "note": "", "updated_at": None,
                                                "downloaded_at": None, "done_at": None}
            requested = body.get("status", old_state["status"])
            status = "done" if old_state["status"] == "done" and requested == "downloaded" else requested
            note = body.get("note", old_state["note"])
            updated_at = now_iso()
            downloaded_at = old_state["downloaded_at"]
            if requested == "downloaded" and downloaded_at is None:
                downloaded_at = updated_at
            done_at = old_state["done_at"]
            if status == "done":
                done_at = done_at or updated_at
            else:
                done_at = None
            con.execute("INSERT INTO practice_state(id,status,note,updated_at,downloaded_at,done_at) "
                        "VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET "
                        "status=excluded.status,note=excluded.note,updated_at=excluded.updated_at, "
                        "downloaded_at=excluded.downloaded_at,done_at=excluded.done_at",
                        (cid, status, note, updated_at, downloaded_at, done_at))
            con.commit()
            state = {"id": cid, "status": status, "note": note, "updated_at": updated_at,
                     "downloaded_at": downloaded_at, "done_at": done_at}
        except Exception:
            con.rollback()
            raise
        finally:
            con.close()
        return jsonify(ok=True, **state)

    def gallery_flags():
        return request.args.get("best") == "1", request.args.get("bursts", "1") == "1"

    @bp.route("/api/gallery/search")
    def api_gallery_search():
        q = request.args.get("q", "").strip()[:200]
        if not q:
            return jsonify({"error": "missing q"}), 400
        best, bursts = gallery_flags()
        found = finder.photos(q)
        return jsonify(dict(found, photos=gallery_items(found.pop("ids"), best=best, bursts=bursts)))

    @bp.route("/api/gallery/like/<int:rowid>")
    def api_gallery_like(rowid):
        best, bursts = gallery_flags()
        found = finder.like_photos(rowid)
        if found is None:
            return jsonify({"error": "no such photo"}), 404
        return jsonify(dict(found, photos=gallery_items(found.pop("ids"), best=best, bursts=bursts)))

    @bp.route("/api/gallery/day/<path:day>")
    def api_gallery_day(day):
        rows = day_rows(day)
        if not rows:
            return jsonify({"error": "no such day"}), 404
        best, bursts = gallery_flags()
        rows.sort(key=lambda r: (r["capture_ts"] or 0, r["rowid"]))
        if bursts:   # each stack's lead, in time order
            leads = {s["lead"] for s in stacks.build_stacks(rows)}
            rows = [r for r in rows if r["rowid"] in leads]
        return jsonify({"day": day, "date": day_date(day), "summary": day_summaries().get(f"{LIBRARY_ROOT}/{day}"),
                        "photos": gallery_items([r["rowid"] for r in rows], best=best, bursts=False)})

    def photo_path(rowid: int) -> str | None:
        """A photo's path, for a log line about a failure; None if it can't be read."""
        try:
            con = db_ro()
            try:
                r = con.execute("SELECT path FROM images WHERE rowid=?", (rowid,)).fetchone()
            finally:
                con.close()
            return r["path"] if r else None
        except Exception:  # noqa: BLE001 - the log line is a courtesy
            return None

    def export_jpeg(rowid: int, edge: int | None) -> tuple[bytes, str] | None:
        """A JPEG of the whole frame for the camera roll, carrying the capture time and
        place so it lands on the right day in Photos. edge: longest side, None = full size."""
        con = db_ro()
        try:
            r = con.execute("SELECT path, filename, capture_ts, gps_lat, gps_lon FROM images WHERE rowid=?",
                            (rowid,)).fetchone()
        finally:
            con.close()
        if not r:
            return None
        im = full_decode(r["path"])
        if edge and max(im.size) > edge:
            with perf.stage("resize"):
                im = im.copy()
                im.thumbnail((edge, edge), Image.LANCZOS)
        exif = Image.Exif()
        if r["capture_ts"]:
            stamp = datetime.fromtimestamp(r["capture_ts"]).strftime("%Y:%m:%d %H:%M:%S")
            exif[306] = stamp                               # DateTime
            exif.get_ifd(0x8769)[36867] = stamp             # DateTimeOriginal
            exif.get_ifd(0x8769)[36868] = stamp             # DateTimeDigitized
        if r["gps_lat"] is not None and r["gps_lon"] is not None:
            def dms(v):
                v = abs(v)
                d = int(v)
                m = int((v - d) * 60)
                return (d, m, round(((v - d) * 60 - m) * 60, 4))
            gps = exif.get_ifd(0x8825)
            gps[1], gps[2] = ("N" if r["gps_lat"] >= 0 else "S"), dms(r["gps_lat"])
            gps[3], gps[4] = ("E" if r["gps_lon"] >= 0 else "W"), dms(r["gps_lon"])
        buf = io.BytesIO()
        with perf.stage("encode"):
            im.save(buf, "JPEG", quality=92, exif=exif)
        return buf.getvalue(), Path(r["filename"]).stem + ".jpg"

    @bp.route("/api/export/<int:rowid>")
    def api_export(rowid):
        """?s=full (default) or large (3000 px, also the viewer's zoom image) for a JPEG; ?s=original
        for the file exactly as it is on the NAS, RAWs included, always as a download; ?dl=1 to download."""
        size = request.args.get("s", "full")
        edge = {"full": None, "large": 3000}.get(size, None)
        how = "attachment" if request.args.get("dl") == "1" else "inline"
        if edge is None:
            con = db_ro()
            try:
                r = con.execute("SELECT path, filename FROM images WHERE rowid=?", (rowid,)).fetchone()
            finally:
                con.close()
            if r and size == "original":   # e.g. a RAW to edit in Lightroom or Darkroom on the phone
                perf.note(served="original")
                kind = AS_IS.get(Path(r["path"]).suffix.lower(), "application/octet-stream")
                return send_file(r["path"], mimetype=kind, as_attachment=True, download_name=r["filename"],
                                 max_age=3600)
            # a phone or camera JPEG/HEIC goes as it is, with all its own metadata
            if r and Path(r["path"]).suffix.lower() in AS_IS:
                perf.note(served="as-is")
                return send_file(r["path"], mimetype=AS_IS[Path(r["path"]).suffix.lower()], max_age=3600,
                                 as_attachment=how == "attachment", download_name=r["filename"])
        try:
            made = export_jpeg(rowid, edge)
        except Exception as e:
            return decode_failed(pc, rowid, photo_path(rowid), e)
        if made is None:
            return jsonify({"error": "not found"}), 404
        data, name = made
        resp = Response(data, mimetype="image/jpeg")
        resp.headers["Content-Disposition"] = f'{how}; filename="{name}"'
        resp.headers["Cache-Control"] = "max-age=3600"
        return resp

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
        if edge == IMG_EDGE["view"] and request.args.get("warm") != "0":
            warm_decode(r["path"])                    # its 1:1 check or HD zoom is likely next
        cached = previews.preview_path(cache_dir, r["path"], edge)
        perf.note(cache="hit" if cached.exists() else "miss", size=request.args.get("s", "view"),
                  ext=Path(r["path"]).suffix.lower())
        if not cached.exists():
            try:
                with perf.stage("load"):          # NAS read + embedded preview (or full open)
                    src = pc.load_source(Path(r["path"]))
                with perf.stage("resize"):
                    im = pc.to_working(src, edge)
                with perf.stage("encode"):
                    previews.write_atomic(im, cached)
            except Exception as e:
                return decode_failed(pc, rowid, r["path"], e)
        return send_file(cached, mimetype="image/jpeg", max_age=86400)

    return bp
