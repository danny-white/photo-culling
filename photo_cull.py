#!/usr/bin/env python3
"""
Batch photo culling for a Lightroom / Sony-ARW library, backed by local Qwen3.5
vision models via Ollama.

Designed to run unattended over several nights across a large library and be
fully resumable. Every image's result — and every failure — is persisted to a
SQLite database (the source of truth), so you can:

  * stop/resume at any time (already-done images are skipped),
  * see "N ok / M pending / K errors" and grep failure classes,
  * re-drive only the failures,
  * regenerate the CSV report and XMP sidecars from the DB at any time.

Design notes (why it's built this way — validated on an 8 GB RTX 2070 S):
  * Inputs are DOWNSCALED to ~1536 px before inference. Feeding a full 42 MP
    frame OOMs the 9B model on 8 GB; at 1536 px it runs comfortably (~2.6 s warm).
  * Technical quality (sharpness, exposure) is measured with deterministic CV
    (variance-of-Laplacian + luminance histogram), NOT the VLM — the VLM
    confabulates technical flaws (it "saw" overexposure a histogram disproved).
    The VLM is used only for semantics: caption, subject, tags, aesthetics,
    eyes-closed.
  * Ollama's structured output still wraps JSON in ```fences and returns loose
    types, so responses are fence-stripped and type-coerced.

Workflow:
    python photo_cull.py run  /path/to/ARW/library        # process (resumable)
    python photo_cull.py status                           # totals + error breakdown
    python photo_cull.py export --xmp                     # write cull.csv + .xmp sidecars
    python photo_cull.py run  /path/to/library --redrive  # retry failed images

Then in Lightroom Classic: select the photos -> Metadata > Read Metadata from File.
"""

import argparse
import io
import json
import re
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

import numpy as np
from PIL import Image, ImageOps

# ----------------------------------------------------------------------------
# Configuration (tunable)
# ----------------------------------------------------------------------------

DB_DEFAULT = "cull.db"
CSV_DEFAULT = "cull.csv"

MODEL_PRIMARY = "qwen3.5:9b"      # best quality; fits 8 GB once the image is downscaled
MODEL_FALLBACK = "qwen3.5:4b"     # faster / smaller; used by --fast and as an OOM fallback

MAX_EDGE = 1536                   # long-edge px sent to the VLM (controls VRAM + speed)
MAX_EDGE_OOM = 1024              # smaller retry if the primary size OOMs
JPEG_QUALITY = 85
NUM_CTX = 4096
KEEP_ALIVE = "60m"               # keep the model resident between images
CALL_TIMEOUT = 120               # seconds; a hung inference errors out instead of stalling the night

# Technical-quality thresholds. Sharpness (variance of Laplacian) is scene-dependent,
# so SHARP_FLOOR is deliberately low — it only catches clearly soft/blurred frames;
# fine ranking between similar frames is done relatively within a burst.
SHARP_FLOOR = 30.0
BLOWN_PCT_MAX = 5.0              # % of pixels at/near pure white before "overexposed"
BLOWN_PCT_SEVERE = 15.0
CRUSHED_PCT_MAX = 30.0          # % of pixels at/near pure black before "underexposed"
MEAN_LUM_LOW = 35              # overall very dark
MEAN_LUM_HIGH = 225           # overall very bright

BURST_GAP_S = 2.0               # frames within this many seconds are grouped as a burst
PHASH_NEAR = 6                  # perceptual-hash Hamming distance treated as a near-duplicate

RAW_EXTENSIONS = {".arw", ".cr2", ".cr3", ".nef", ".raf", ".rw2", ".dng", ".orf", ".pef", ".srw"}
IMG_EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".tif", ".tiff"}
ALL_EXTENSIONS = RAW_EXTENSIONS | IMG_EXTENSIONS

LABEL_FOR_VERDICT = {"keep": "Green", "review": "Yellow", "reject": "Red"}

# ----------------------------------------------------------------------------
# SQLite state store (the source of truth)
# ----------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS images (
    path            TEXT PRIMARY KEY,
    filename        TEXT,
    mtime           REAL,
    size            INTEGER,
    status          TEXT DEFAULT 'pending',   -- pending | ok | error
    attempts        INTEGER DEFAULT 0,
    error_class     TEXT,                     -- oom|timeout|json_parse|no_thumbnail|io|model
    error_msg       TEXT,
    model_used      TEXT,
    processed_at    TEXT,

    capture_ts      REAL,                      -- epoch seconds, for burst grouping
    camera          TEXT,
    lens            TEXT,

    sharpness       REAL,
    blown_pct       REAL,
    crushed_pct     REAL,
    mean_lum        REAL,
    exposure_flag   TEXT,                      -- ok | over | under

    caption         TEXT,
    subject         TEXT,
    scene           TEXT,
    people_count    INTEGER,
    eyes_closed     INTEGER,
    aesthetic       INTEGER,
    tags            TEXT,                      -- JSON array
    issues          TEXT,                      -- JSON array

    phash           TEXT,
    burst_id        INTEGER,
    burst_size      INTEGER DEFAULT 1,
    is_best_in_burst INTEGER DEFAULT 1,

    base_verdict    TEXT,                      -- per-image judgment before burst logic
    quality_stars   INTEGER,
    verdict         TEXT,                      -- effective (after burst demotion)
    color_label     TEXT,
    reason          TEXT
);
CREATE INDEX IF NOT EXISTS idx_status ON images(status);
CREATE INDEX IF NOT EXISTS idx_capture ON images(capture_ts);
"""


def connect(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def register_targets(conn: sqlite3.Connection, folder: Path, recursive: bool) -> int:
    """Insert any new/changed files as 'pending'. Returns count of newly-queued files."""
    walker = folder.rglob("*") if recursive else folder.glob("*")
    queued = 0
    for p in walker:
        if not p.is_file() or p.suffix.lower() not in ALL_EXTENSIONS:
            continue
        st = p.stat()
        row = conn.execute("SELECT mtime, size, status FROM images WHERE path=?", (str(p),)).fetchone()
        if row is None:
            conn.execute(
                "INSERT INTO images(path, filename, mtime, size, status) VALUES(?,?,?,?, 'pending')",
                (str(p), p.name, st.st_mtime, st.st_size),
            )
            queued += 1
        elif row["mtime"] != st.st_mtime or row["size"] != st.st_size:
            # file changed on disk -> reprocess
            conn.execute(
                "UPDATE images SET mtime=?, size=?, status='pending', error_class=NULL, error_msg=NULL WHERE path=?",
                (st.st_mtime, st.st_size, str(p)),
            )
            queued += 1
    conn.commit()
    return queued


def upsert_result(conn: sqlite3.Connection, path: str, fields: dict):
    cols = ", ".join(f"{k}=?" for k in fields)
    conn.execute(f"UPDATE images SET {cols} WHERE path=?", (*fields.values(), path))
    conn.commit()


# ----------------------------------------------------------------------------
# Image loading: ARW embedded-preview extraction / direct decode
# ----------------------------------------------------------------------------

class LoadError(Exception):
    """Raised when an image can't be read/decoded."""


def _exc_text(e: Exception) -> str:
    """Readable exception text. LibRaw raises errors whose arg is raw bytes."""
    if e.args and isinstance(e.args[0], (bytes, bytearray)):
        return e.args[0].decode(errors="replace")
    return str(e)


def load_source(path: Path) -> Image.Image:
    """Return an upright RGB PIL image for `path`.

    For RAW files, extract the camera's embedded JPEG preview (near-instant, no
    demosaic). For everything else, decode directly. Orientation is normalized.
    """
    ext = path.suffix.lower()
    try:
        if ext in RAW_EXTENSIONS:
            import rawpy
            with rawpy.imread(str(path)) as raw:
                try:
                    thumb = raw.extract_thumb()
                except rawpy.LibRawNoThumbnailError:
                    rgb = raw.postprocess(half_size=True, use_camera_wb=True, no_auto_bright=False)
                    return Image.fromarray(rgb)
                if thumb.format == rawpy.ThumbFormat.JPEG:
                    im = Image.open(io.BytesIO(thumb.data))
                else:  # BITMAP -> numpy RGB
                    im = Image.fromarray(thumb.data)
        else:
            im = Image.open(path)
        im = ImageOps.exif_transpose(im)   # honor orientation, then drop the tag
        return im.convert("RGB")
    except Exception as e:  # noqa: BLE001 - normalize to one error type for the pipeline
        raise LoadError(_exc_text(e)) from e


def read_exif(path: Path) -> dict:
    """Best-effort capture time + camera/lens. Falls back to file mtime for ordering.

    RAW files are read with exifread straight from the file (authoritative
    DateTimeOriginal + lens, which the embedded preview often strips); everything
    else is read from its own EXIF with PIL.
    """
    out = {"capture_ts": None, "camera": None, "lens": None}
    dto = sub = None
    try:
        if path.suffix.lower() in RAW_EXTENSIONS:
            import exifread
            with open(path, "rb") as f:
                tags = exifread.process_file(f, details=False)
            dto = tags.get("EXIF DateTimeOriginal") or tags.get("Image DateTime")
            sub = tags.get("EXIF SubSecTimeOriginal")
            make = str(tags.get("Image Make") or "").strip()
            model = str(tags.get("Image Model") or "").strip()
            out["camera"] = (f"{make} {model}".strip() or None)
            lens = tags.get("EXIF LensModel") or tags.get("MakerNote LensType")
            out["lens"] = str(lens).strip() if lens else None
        else:
            with Image.open(path) as im:
                exif = im.getexif()
                make = str(exif.get(271) or "").strip()
                model = str(exif.get(272) or "").strip()
                out["camera"] = (f"{make} {model}".strip() or None)
                ifd = exif.get_ifd(0x8769)               # Exif sub-IFD
                dto = ifd.get(36867) or exif.get(306)    # DateTimeOriginal, else DateTime
                sub = ifd.get(37521)                     # SubSecTimeOriginal
                lens = ifd.get(42036)                    # LensModel
                out["lens"] = str(lens).strip() if lens else None
        if dto:
            ts = datetime.strptime(str(dto).strip(), "%Y:%m:%d %H:%M:%S")
            sub = str(sub or "").strip()
            frac = float(f"0.{sub}") if sub.isdigit() else 0.0
            out["capture_ts"] = ts.timestamp() + frac
    except Exception:
        pass
    # Normalize camera/lens: drop empties and Sony's "----" manual-lens placeholder.
    for k in ("camera", "lens"):
        v = str(out[k]).strip() if out[k] is not None else ""
        out[k] = v if v.strip("- ") else None
    if out["capture_ts"] is None:
        try:
            out["capture_ts"] = path.stat().st_mtime
        except OSError:
            out["capture_ts"] = None
    return out


def to_working(im: Image.Image, max_edge: int) -> Image.Image:
    work = im.copy()
    work.thumbnail((max_edge, max_edge), Image.LANCZOS)
    return work


def jpeg_bytes(im: Image.Image) -> bytes:
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=JPEG_QUALITY)
    return buf.getvalue()


# ----------------------------------------------------------------------------
# Deterministic CV metrics (technical quality) + perceptual hash
# ----------------------------------------------------------------------------

def cv_metrics(im: Image.Image) -> dict:
    """Sharpness (variance of a 4-neighbour Laplacian) + exposure from the histogram."""
    g = np.asarray(im.convert("L"), dtype=np.float64)
    lap = (-4 * g[1:-1, 1:-1] + g[:-2, 1:-1] + g[2:, 1:-1] + g[1:-1, :-2] + g[1:-1, 2:])
    sharp = float(lap.var())

    lum = np.asarray(im.convert("L"))
    blown = float((lum >= 250).mean() * 100)
    crushed = float((lum <= 5).mean() * 100)
    mean_lum = float(lum.mean())

    if blown > BLOWN_PCT_MAX or mean_lum > MEAN_LUM_HIGH:
        flag = "over"
    elif crushed > CRUSHED_PCT_MAX or mean_lum < MEAN_LUM_LOW:
        flag = "under"
    else:
        flag = "ok"
    return {
        "sharpness": round(sharp, 1),
        "blown_pct": round(blown, 2),
        "crushed_pct": round(crushed, 2),
        "mean_lum": round(mean_lum, 1),
        "exposure_flag": flag,
    }


def compute_phash(im: Image.Image) -> str:
    import imagehash
    return str(imagehash.phash(im))


# ----------------------------------------------------------------------------
# VLM semantic analysis (Qwen3.5 via Ollama)
# ----------------------------------------------------------------------------

VLM_SCHEMA = {
    "type": "object",
    "properties": {
        "caption": {"type": "string"},
        "subject": {"type": "string"},
        "scene": {"type": "string"},
        "people_count": {"type": "integer"},
        "eyes_closed": {"type": "boolean"},
        "aesthetic": {"type": "integer"},
        "tags": {"type": "array", "items": {"type": "string"}},
        "issues": {"type": "array", "items": {"type": "string"}},
        "keep_hint": {"type": "boolean"},
    },
    "required": ["caption", "subject", "scene", "people_count", "eyes_closed",
                 "aesthetic", "tags", "issues", "keep_hint"],
}

VLM_PROMPT = (
    "You are a photo-culling editor doing a first pass. Look at the image and return JSON.\n"
    "Do NOT judge exposure, focus or sharpness — those are measured separately.\n"
    "Judge only what you can see about content and composition:\n"
    "- caption: one natural sentence describing the photo.\n"
    "- subject: the single main subject (a few words).\n"
    "- scene: one genre word (portrait, landscape, wildlife, street, macro, architecture, food, event, other).\n"
    "- people_count: number of people whose faces are visible.\n"
    "- eyes_closed: true only if a person's eyes are clearly closed/blinking.\n"
    "- aesthetic: 1-10 for composition, framing and overall appeal.\n"
    "- tags: 4-8 short lowercase keywords (subject, setting, activity, mood).\n"
    "- issues: composition problems you can see (e.g. 'tilted horizon', 'subject cut off', "
    "'cluttered background', 'obstructed'); empty list if none.\n"
    "- keep_hint: true if this looks worth keeping as a photograph.\n"
    "Return only JSON."
)


def extract_json(raw: str) -> dict:
    if not raw or not raw.strip():
        raise ValueError("empty model response")
    match = re.search(r"\{.*\}", raw, re.DOTALL)   # tolerate ```json fences / stray prose
    if not match:
        raise ValueError(f"no JSON object in response: {raw[:200]}")
    cleaned = re.sub(r",\s*([\]}])", r"\1", match.group(0))   # trailing commas
    return json.loads(cleaned)


def _as_str(x, limit):
    if isinstance(x, list):
        x = ", ".join(str(t) for t in x)
    return ("" if x is None else str(x)).strip()[:limit]


def _as_int(x, lo, hi, default):
    try:
        v = int(round(float(x)))
    except (TypeError, ValueError):
        v = default
    return max(lo, min(hi, v))


def _as_bool(x):
    if isinstance(x, bool):
        return x
    return str(x).strip().lower() in ("true", "yes", "1")


def _as_taglist(x, limit):
    if isinstance(x, list):
        items = x
    elif isinstance(x, str):
        items = re.split(r"[,;]", x)
    else:
        items = []
    seen, out = set(), []
    for t in items:
        t = str(t).strip().lower()
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out[:limit]


def coerce_vlm(d: dict) -> dict:
    return {
        "caption": _as_str(d.get("caption"), 300),
        "subject": _as_str(d.get("subject"), 120),
        "scene": _as_str(d.get("scene"), 40).lower(),
        "people_count": _as_int(d.get("people_count"), 0, 100, 0),
        "eyes_closed": _as_bool(d.get("eyes_closed")),
        "aesthetic": _as_int(d.get("aesthetic"), 1, 10, 5),
        "tags": _as_taglist(d.get("tags"), 8),
        "issues": _as_taglist(d.get("issues"), 6),
        "keep_hint": _as_bool(d.get("keep_hint")),
    }


def is_oom(err: Exception) -> bool:
    m = str(err).lower()
    return any(k in m for k in ("out of memory", "cudamalloc", "cuda error", "vram", "oom"))


def analyze_vlm(client, work: Image.Image, fast: bool) -> tuple[dict, str]:
    """Run the VLM with an OOM ladder: primary@1536 -> primary@1024 -> fallback@1024.
    Returns (coerced_fields, model_used)."""
    if fast:
        ladder = [(MODEL_FALLBACK, MAX_EDGE), (MODEL_FALLBACK, MAX_EDGE_OOM)]
    else:
        ladder = [(MODEL_PRIMARY, MAX_EDGE), (MODEL_PRIMARY, MAX_EDGE_OOM), (MODEL_FALLBACK, MAX_EDGE_OOM)]

    last_err = None
    for model, edge in ladder:
        img = jpeg_bytes(work if edge == MAX_EDGE else to_working(work, edge))
        try:
            resp = client.chat(
                model=model,
                messages=[{"role": "user", "content": VLM_PROMPT, "images": [img]}],
                think=False,
                format=VLM_SCHEMA,
                options={"num_ctx": NUM_CTX, "temperature": 0},
                keep_alive=KEEP_ALIVE,
            )
            return coerce_vlm(extract_json(resp["message"]["content"])), model
        except Exception as e:  # noqa: BLE001
            last_err = e
            if is_oom(e):
                continue          # shrink / downshift and retry
            raise
    raise last_err


# ----------------------------------------------------------------------------
# Verdict / rating derivation
# ----------------------------------------------------------------------------

def derive(cv: dict, vlm: dict) -> dict:
    blurry = cv["sharpness"] < SHARP_FLOOR
    bad_exp = cv["exposure_flag"] != "ok"
    severe_exp = cv["blown_pct"] > BLOWN_PCT_SEVERE
    portrait = vlm["people_count"] > 0
    closed = portrait and vlm["eyes_closed"]

    stars = round(vlm["aesthetic"] / 2)
    stars -= 1 if blurry else 0
    stars -= 1 if bad_exp else 0
    stars -= 1 if closed else 0
    stars = max(1, min(5, stars))

    if blurry or severe_exp or closed or vlm["aesthetic"] <= 3:
        verdict = "reject"
    elif (not blurry) and (not bad_exp) and vlm["aesthetic"] >= 7 and vlm["keep_hint"]:
        verdict = "keep"
    else:
        verdict = "review"

    bits = []
    if blurry:
        bits.append("soft/blurred")
    if bad_exp:
        bits.append(f"{cv['exposure_flag']}exposed")
    if closed:
        bits.append("eyes closed")
    if vlm["issues"]:
        bits.append(vlm["issues"][0])
    if not bits:
        bits.append(vlm["subject"] or "clean frame")
    reason = f"{verdict}: " + ", ".join(bits)

    return {
        "base_verdict": verdict,
        "quality_stars": stars,
        "verdict": verdict,
        "color_label": LABEL_FOR_VERDICT[verdict],
        "reason": reason[:300],
    }


# ----------------------------------------------------------------------------
# Per-image processing
# ----------------------------------------------------------------------------

def process_one(client, path: Path, fast: bool) -> dict:
    """Full pipeline for one image. Returns a dict of DB columns to write.
    On failure returns status='error' with an error_class."""
    try:
        source = load_source(path)
    except LoadError as e:
        cls = "no_thumbnail" if "thumbnail" in str(e).lower() else "io"
        return {"status": "error", "error_class": cls, "error_msg": str(e)[:500]}

    work = to_working(source, MAX_EDGE)
    cv = cv_metrics(work)
    meta = read_exif(path)
    try:
        phash = compute_phash(work)
    except Exception:  # noqa: BLE001 - hashing is non-critical
        phash = None

    try:
        vlm, model_used = analyze_vlm(client, work, fast)
    except Exception as e:  # noqa: BLE001
        if is_oom(e):
            cls = "oom"
        elif isinstance(e, (json.JSONDecodeError, ValueError)):
            cls = "json_parse"
        elif "time" in type(e).__name__.lower() or "timeout" in str(e).lower():
            cls = "timeout"
        else:
            cls = "model"
        return {"status": "error", "error_class": cls, "error_msg": _exc_text(e)[:500]}

    verdict = derive(cv, vlm)
    return {
        "status": "ok",
        "error_class": None,
        "error_msg": None,
        "model_used": model_used,
        "processed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "capture_ts": meta["capture_ts"],
        "camera": meta["camera"],
        "lens": meta["lens"],
        **cv,
        "caption": vlm["caption"],
        "subject": vlm["subject"],
        "scene": vlm["scene"],
        "people_count": vlm["people_count"],
        "eyes_closed": int(vlm["eyes_closed"]),
        "aesthetic": vlm["aesthetic"],
        "tags": json.dumps(vlm["tags"]),
        "issues": json.dumps(vlm["issues"]),
        "phash": phash,
        **verdict,
    }


# ----------------------------------------------------------------------------
# Burst clustering (pick best of a series) — recomputed on export
# ----------------------------------------------------------------------------

def cluster_bursts(conn: sqlite3.Connection, burst_gap: float):
    rows = conn.execute(
        "SELECT path, capture_ts, sharpness, aesthetic, phash, base_verdict, camera "
        "FROM images WHERE status='ok' ORDER BY capture_ts, filename"
    ).fetchall()

    burst_id = 0
    prev_ts = None
    prev_cam = None
    members: list[dict] = []

    def flush(group):
        if not group:
            return
        # best = highest aesthetic, tie-broken by sharpness
        best = max(group, key=lambda r: (r["aesthetic"] or 0, r["sharpness"] or 0))
        size = len(group)
        for r in group:
            is_best = 1 if r["path"] == best["path"] else 0
            verdict = r["base_verdict"]
            # A keeper that isn't the best of a multi-frame burst -> demote to review.
            if size > 1 and not is_best and verdict == "keep":
                verdict = "review"
            conn.execute(
                "UPDATE images SET burst_id=?, burst_size=?, is_best_in_burst=?, verdict=?, color_label=? WHERE path=?",
                (r["_bid"], size, is_best, verdict, LABEL_FOR_VERDICT[verdict], r["path"]),
            )

    group: list = []
    for r in rows:
        r = dict(r)
        ts = r["capture_ts"]
        same_burst = (
            prev_ts is not None and ts is not None
            and (ts - prev_ts) <= burst_gap
            and r["camera"] == prev_cam
        )
        if not same_burst:
            flush(group)
            group = []
            burst_id += 1
        r["_bid"] = burst_id
        group.append(r)
        prev_ts, prev_cam = ts, r["camera"]
    flush(group)
    conn.commit()


# ----------------------------------------------------------------------------
# Outputs: CSV report + XMP sidecars
# ----------------------------------------------------------------------------

CSV_COLUMNS = [
    "filename", "verdict", "quality_stars", "color_label", "aesthetic",
    "sharpness", "exposure_flag", "blown_pct", "crushed_pct",
    "subject", "scene", "caption", "tags", "issues",
    "people_count", "eyes_closed", "is_best_in_burst", "burst_id",
    "reason", "status", "error_class", "error_msg", "model_used", "path",
]


def export_csv(conn: sqlite3.Connection, csv_path: Path):
    import csv
    rows = conn.execute("SELECT * FROM images ORDER BY capture_ts, filename").fetchall()
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            d = dict(r)
            for jcol in ("tags", "issues"):
                if d.get(jcol):
                    try:
                        d[jcol] = ", ".join(json.loads(d[jcol]))
                    except (json.JSONDecodeError, TypeError):
                        pass
            w.writerow(d)
    return len(rows)


XMP_TEMPLATE = """<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
    xmp:Rating="{rating}"
    xmp:Label="{label}">
   <dc:description><rdf:Alt><rdf:li xml:lang="x-default">{caption}</rdf:li></rdf:Alt></dc:description>
   <dc:subject><rdf:Bag>
{subjects}   </rdf:Bag></dc:subject>
   <lr:hierarchicalSubject><rdf:Bag>
{hier}   </rdf:Bag></lr:hierarchicalSubject>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
"""


def build_keywords(row: dict) -> tuple[list, list]:
    tags = json.loads(row["tags"]) if row["tags"] else []
    flat = list(tags)
    if row["subject"]:
        flat.append(row["subject"].lower())
    if row["is_best_in_burst"] and (row["burst_size"] or 1) > 1:
        flat.append("pick:best")
    # de-dup preserving order
    seen, flat_u = set(), []
    for t in flat:
        if t and t not in seen:
            seen.add(t)
            flat_u.append(t)
    hier = [f"Cull|{row['verdict']}"]
    if row["scene"]:
        hier.append(f"Scene|{row['scene']}")
    return flat_u, hier


def write_xmp_sidecars(conn: sqlite3.Connection, force: bool) -> dict:
    stats = {"written": 0, "skipped_exists": 0, "skipped_notok": 0}
    rows = conn.execute("SELECT * FROM images").fetchall()
    for r in rows:
        row = dict(r)
        if row["status"] != "ok":
            stats["skipped_notok"] += 1
            continue
        sidecar = Path(row["path"]).with_suffix(".xmp")
        if sidecar.exists() and not force:
            stats["skipped_exists"] += 1
            continue
        flat, hier = build_keywords(row)
        subjects = "".join(f"    <rdf:li>{xml_escape(k)}</rdf:li>\n" for k in flat)
        hiers = "".join(f"    <rdf:li>{xml_escape(k)}</rdf:li>\n" for k in hier)
        xml = XMP_TEMPLATE.format(
            rating=row["quality_stars"] or 0,
            label=xml_escape(row["color_label"] or ""),
            caption=xml_escape(row["caption"] or ""),
            subjects=subjects,
            hier=hiers,
        )
        sidecar.write_text(xml, encoding="utf-8")
        stats["written"] += 1
    return stats


# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------

def _fmt_eta(seconds: float) -> str:
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"


def cmd_run(args):
    folder = args.folder
    if not folder.is_dir():
        sys.exit(f"Not a folder: {folder}")
    import ollama

    conn = connect(args.db)
    newly = register_targets(conn, folder, recursive=not args.no_recursive)

    statuses = ["pending"] + (["error"] if args.redrive else [])
    if args.force:
        statuses.append("ok")
    placeholders = ",".join("?" * len(statuses))
    todo = conn.execute(
        f"SELECT path FROM images WHERE status IN ({placeholders}) ORDER BY filename",
        statuses,
    ).fetchall()
    todo = [Path(r["path"]) for r in todo]
    if args.limit:
        todo = todo[: args.limit]

    total_all = conn.execute("SELECT COUNT(*) c FROM images").fetchone()["c"]
    print(f"Library: {total_all} images tracked ({newly} newly queued). "
          f"Processing {len(todo)} now with {'4b (fast)' if args.fast else '9b'} "
          f"at {MAX_EDGE}px.\n")
    if not todo:
        print("Nothing to do. (Use --redrive to retry errors, --force to reprocess.)")
        return

    client = ollama.Client(timeout=CALL_TIMEOUT)
    done = 0
    t_start = time.time()
    try:
        for i, path in enumerate(todo, 1):
            prev = conn.execute("SELECT attempts FROM images WHERE path=?", (str(path),)).fetchone()
            attempts = (prev["attempts"] if prev else 0) + 1
            t0 = time.time()
            result = process_one(client, path, args.fast)
            result["attempts"] = attempts
            upsert_result(conn, str(path), result)
            done += 1
            dt = time.time() - t0
            avg = (time.time() - t_start) / done
            eta = avg * (len(todo) - i)
            if result["status"] == "ok":
                msg = (f"{result['verdict'].upper():6s} {result['quality_stars']}* "
                       f"sharp={result['sharpness']:.0f} exp={result['exposure_flag']:5s} "
                       f"{result['subject'][:32]}")
            else:
                msg = f"ERROR [{result['error_class']}] {result['error_msg'][:60]}"
            print(f"[{i}/{len(todo)}] {path.name:24s} -> {msg}  ({dt:.1f}s, ETA {_fmt_eta(eta)})")
    except KeyboardInterrupt:
        print("\nInterrupted — progress saved. Re-run to resume.")

    print(f"\nProcessed {done} image(s) in {_fmt_eta(time.time() - t_start)}.")
    _print_summary(conn)
    print("\nNext: `photo_cull.py export --xmp` to write cull.csv + XMP sidecars.")


def _print_summary(conn: sqlite3.Connection):
    total = conn.execute("SELECT COUNT(*) c FROM images").fetchone()["c"]
    by_status = {r["status"]: r["c"] for r in
                 conn.execute("SELECT status, COUNT(*) c FROM images GROUP BY status")}
    ok = by_status.get("ok", 0)
    pending = by_status.get("pending", 0)
    errors = by_status.get("error", 0)
    print(f"State: {ok} ok / {pending} pending / {errors} error  (of {total} tracked)")
    if errors:
        print("  Errors by class:")
        for r in conn.execute(
            "SELECT error_class, COUNT(*) c FROM images WHERE status='error' "
            "GROUP BY error_class ORDER BY c DESC"):
            print(f"    {r['error_class'] or 'unknown':12s} {r['c']}")
    if ok:
        print("  Verdicts:")
        for r in conn.execute(
            "SELECT verdict, COUNT(*) c FROM images WHERE status='ok' "
            "GROUP BY verdict ORDER BY c DESC"):
            print(f"    {r['verdict'] or '-':8s} {r['c']}")


def cmd_status(args):
    if not args.db.exists():
        sys.exit(f"No database at {args.db}. Run `photo_cull.py run <folder>` first.")
    conn = connect(args.db)
    _print_summary(conn)
    if args.errors:
        print("\nError rows:")
        for r in conn.execute(
            "SELECT filename, error_class, error_msg FROM images WHERE status='error' "
            "ORDER BY error_class"):
            print(f"  {r['filename']:24s} [{r['error_class']}] {r['error_msg'][:80]}")


def cmd_export(args):
    if not args.db.exists():
        sys.exit(f"No database at {args.db}. Run `photo_cull.py run <folder>` first.")
    conn = connect(args.db)
    cluster_bursts(conn, args.burst_gap)
    n = export_csv(conn, args.csv)
    print(f"Wrote {n} rows to {args.csv}")
    if args.xmp:
        stats = write_xmp_sidecars(conn, force=args.force_xmp)
        print(f"XMP sidecars: {stats['written']} written, "
              f"{stats['skipped_exists']} skipped (already exist; use --force-xmp), "
              f"{stats['skipped_notok']} skipped (not ok).")
        print("In Lightroom Classic: select photos -> Metadata > Read Metadata from File.")


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("run", help="Process a folder (resumable).")
    r.add_argument("folder", type=Path)
    r.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    r.add_argument("--fast", action="store_true", help=f"Use {MODEL_FALLBACK} instead of {MODEL_PRIMARY}.")
    r.add_argument("--limit", type=int, help="Process at most N images this run.")
    r.add_argument("--redrive", action="store_true", help="Also retry rows that previously errored.")
    r.add_argument("--force", action="store_true", help="Reprocess even images already marked ok.")
    r.add_argument("--no-recursive", action="store_true", help="Do not descend into subfolders.")
    r.set_defaults(func=cmd_run)

    s = sub.add_parser("status", help="Show counts and error breakdown.")
    s.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    s.add_argument("--errors", action="store_true", help="List every error row.")
    s.set_defaults(func=cmd_status)

    e = sub.add_parser("export", help="Cluster bursts, write CSV (+ optional XMP sidecars).")
    e.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    e.add_argument("--csv", type=Path, default=Path(CSV_DEFAULT))
    e.add_argument("--xmp", action="store_true", help="Also write .xmp sidecars next to each photo.")
    e.add_argument("--force-xmp", action="store_true", help="Overwrite existing .xmp sidecars.")
    e.add_argument("--burst-gap", type=float, default=BURST_GAP_S, help="Seconds between frames to group as a burst.")
    e.set_defaults(func=cmd_export)
    return p


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
