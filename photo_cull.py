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
import hashlib
import io
import json
import logging
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

import numpy as np
from PIL import Image, ImageOps
import pillow_heif

pillow_heif.register_heif_opener()

# exifread logs "File format not recognized." for ISO-BMFF raws (e.g. CR3); we fall back to
# exiftool for those, so silence that noisy per-file warning.
logging.getLogger("exifread").setLevel(logging.CRITICAL)

# ----------------------------------------------------------------------------
# Configuration (tunable)
# ----------------------------------------------------------------------------

DB_DEFAULT = "cull.db"
CSV_DEFAULT = "cull.csv"

MODEL_PRIMARY = "qwen3.5:9b"      # best quality; fits 8 GB once the image is downscaled
MODEL_FALLBACK = "qwen3.5:4b"     # faster / smaller; used by --fast and as an OOM fallback

EMBED_MODEL = "nomic-embed-text"  # text embedding model for semantic search (see `embed` subcommand)

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
MONOCHROME_SAT_MAX = 12.0    # mean HSV saturation (0-255) below which a frame reads as B&W

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
    prompt_version  TEXT,                      -- sha256(VLM_PROMPT)[:12]; joins to prompts table
    harness_version TEXT,                      -- git short SHA (+ -dirty) of the code that ran

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
    keep_hint       INTEGER,                   -- qwen's boolean "worth keeping?"; a derive() input
    tags            TEXT,                      -- JSON array
    issues          TEXT,                      -- JSON array
    activity        TEXT,
    indoor_outdoor  TEXT,                      -- indoor | outdoor | unknown
    time_of_day     TEXT,                      -- day | golden_hour | blue_hour | night | unknown
    animals         TEXT,                      -- JSON array
    content_type    TEXT,                      -- photo | screenshot | document | graphic
    visible_text    TEXT,                      -- OCR of legible signage/text only, never guessed
    monochrome      INTEGER,                   -- CV-measured (mean HSV saturation), not VLM

    phash           TEXT,
    burst_id        INTEGER,
    burst_size      INTEGER DEFAULT 1,
    is_best_in_burst INTEGER DEFAULT 1,

    base_verdict    TEXT,                      -- per-image judgment before burst logic
    quality_stars   INTEGER,
    verdict         TEXT,                      -- effective (after burst demotion)
    color_label     TEXT,
    reason          TEXT,
    user_rating     INTEGER,                   -- your final LR star rating, read back from XMP (feedback)
    user_label      TEXT                       -- your final LR color label, read back from XMP (feedback)
);
CREATE INDEX IF NOT EXISTS idx_status ON images(status);
CREATE INDEX IF NOT EXISTS idx_capture ON images(capture_ts);

-- Reconstructable registry: map a prompt_version hash back to the exact prompt text.
CREATE TABLE IF NOT EXISTS prompts (
    prompt_version  TEXT PRIMARY KEY,   -- sha256(prompt text)[:12], = images.prompt_version
    prompt          TEXT NOT NULL,      -- the exact VLM_PROMPT string, for reconstruction
    first_seen      TEXT                -- ISO-8601 UTC when this prompt was first registered
);

-- Per-(photo x model x prompt) VLM outputs + derived verdict, for A/B model comparison. The
-- model-INDEPENDENT facts (CV metrics, EXIF, bursts, your ratings) stay in `images`; `analyses`
-- reuses that shared CV via a path join, so only the model's judgment varies.
CREATE TABLE IF NOT EXISTS analyses (
    path            TEXT NOT NULL,
    model           TEXT NOT NULL,
    prompt_version  TEXT NOT NULL,
    harness_version TEXT,
    processed_at    TEXT,
    status          TEXT DEFAULT 'ok',        -- ok | error
    error_class     TEXT,
    error_msg       TEXT,
    caption         TEXT,
    subject         TEXT,
    scene           TEXT,
    people_count    INTEGER,
    eyes_closed     INTEGER,
    aesthetic       INTEGER,
    keep_hint       INTEGER,
    tags            TEXT,
    issues          TEXT,
    base_verdict    TEXT,
    quality_stars   INTEGER,
    verdict         TEXT,
    color_label     TEXT,
    reason          TEXT,
    duration_s      REAL,                      -- wall time of the infer_openai() call itself, for A/B speed comparisons
    PRIMARY KEY (path, model, prompt_version)
);

-- Semantic-search vectors, one row per (photo x embed_version) -- versioned the same way prompts
-- are, so changing the embed model or the text recipe (build_embed_text) just means a fresh
-- embed_version and a re-embed, never a migration. vector is float32 packed bytes (array('f')).
CREATE TABLE IF NOT EXISTS embeddings (
    path            TEXT NOT NULL,
    embed_version   TEXT NOT NULL,
    model           TEXT,
    dims            INTEGER,
    vector          BLOB,
    created_at      TEXT,
    PRIMARY KEY (path, embed_version)
);

-- Two-line summaries of each shoot folder, written by a local text model from the annotations
-- above (see cmd_daysum). input_hash covers the facts the model saw plus the prompt version, so a
-- folder that gains photos, or a new prompt, gets summarised again.
CREATE TABLE IF NOT EXISTS day_summaries (
    folder          TEXT PRIMARY KEY,          -- the shoot folder's path
    summary         TEXT,                      -- line 1: what the day was; line 2: highlights
    model           TEXT,
    version         TEXT,
    frames          INTEGER,
    input_hash      TEXT,
    created_at      TEXT
);
"""


def connect(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")   # readers (status/export/sqlite3) never block the running writer
    conn.execute("PRAGMA busy_timeout=5000")  # wait, don't error, on the rare commit collision
    conn.executescript(SCHEMA)
    # Upgrade DBs created before these columns were added: SCHEMA's CREATE TABLE IF NOT EXISTS
    # defines them for fresh DBs, but won't add them to an already-existing images table.
    for col, decl in (("prompt_version", "TEXT"), ("harness_version", "TEXT"),
                      ("keep_hint", "INTEGER"), ("user_rating", "INTEGER"), ("user_label", "TEXT"),
                      ("activity", "TEXT"), ("indoor_outdoor", "TEXT"), ("time_of_day", "TEXT"),
                      ("animals", "TEXT"), ("content_type", "TEXT"), ("visible_text", "TEXT"),
                      ("monochrome", "INTEGER"),
                      ("gps_lat", "REAL"), ("gps_lon", "REAL"), ("gps_checked", "INTEGER"),
                      ("place", "TEXT")):
        try:
            conn.execute(f"ALTER TABLE images ADD COLUMN {col} {decl}")
        except sqlite3.OperationalError:
            pass  # column already present
    for col, decl in (("duration_s", "REAL"),):
        try:
            conn.execute(f"ALTER TABLE analyses ADD COLUMN {col} {decl}")
        except sqlite3.OperationalError:
            pass  # column already present
    conn.commit()
    return conn


def register_targets(conn: sqlite3.Connection, folder: Path, recursive: bool, exts=ALL_EXTENSIONS) -> int:
    """Insert any new/changed files as 'pending'. Returns count of newly-queued files.

    `exts` restricts which file extensions are queued (default: all supported raw/image types)."""
    walker = folder.rglob("*") if recursive else folder.glob("*")
    queued = 0
    for p in walker:
        if p.name.startswith("."):        # skip dotfiles: macOS AppleDouble (._*), .DS_Store, etc.
            continue
        if not p.is_file() or p.suffix.lower() not in exts:
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


def register_prompt(conn: sqlite3.Connection, version: str, text: str):
    """Persist the (prompt_version -> exact prompt text) pair once, so any row's prompt_version is
    reconstructable later. No-op if this version is already recorded."""
    conn.execute(
        "INSERT OR IGNORE INTO prompts(prompt_version, prompt, first_seen) VALUES(?,?,?)",
        (version, text, datetime.now(timezone.utc).isoformat(timespec="seconds")),
    )
    conn.commit()


def harness_version() -> str:
    """Identity of the *code* that produced a row — derive(), the CV thresholds and the model
    params all affect outputs, not just the prompt. Short git SHA of HEAD, plus '-dirty' if
    photo_cull.py has uncommitted changes (a '-dirty' row isn't reproducible from the SHA alone).
    Falls back to a hash of this file's bytes when not in a git checkout."""
    here = Path(__file__).resolve().parent
    try:
        sha = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=here, text=True, stderr=subprocess.DEVNULL).strip()
        dirty = subprocess.check_output(
            ["git", "status", "--porcelain", "--", str(Path(__file__).resolve())],
            cwd=here, text=True).strip()
        return sha + ("-dirty" if dirty else "")
    except Exception:  # noqa: BLE001 - provenance must never crash a run
        try:
            return "nogit-" + hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]
        except Exception:  # noqa: BLE001
            return "unknown"


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


_EXIFTOOL_PATH = None


def _exiftool_available() -> str:
    """Cached path to the exiftool binary ('' if not installed)."""
    global _EXIFTOOL_PATH
    if _EXIFTOOL_PATH is None:
        _EXIFTOOL_PATH = shutil.which("exiftool") or ""
    return _EXIFTOOL_PATH


def _exif_via_exiftool(path: Path) -> dict:
    """Capture time / camera / lens via exiftool — the one parser that reads CR3 (ISO-BMFF) as
    well as CR2/NEF/JPEG/ARW. Returns {} if exiftool is unavailable or fails. Used only as a
    fallback for files our TIFF/JPEG parsers can't read, so it costs nothing on the common path."""
    exe = _exiftool_available()
    if not exe:
        return {}
    try:
        proc = subprocess.run(
            [exe, "-j", "-m",
             "-SubSecDateTimeOriginal", "-DateTimeOriginal", "-CreateDate",
             "-Make", "-Model", "-LensModel", "-LensType", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        data = json.loads(proc.stdout or "[]")
    except Exception:  # noqa: BLE001 - metadata is best-effort
        return {}
    if not data:
        return {}
    d = data[0]
    res = {"capture_ts": None, "camera": None, "lens": None}
    dt = d.get("SubSecDateTimeOriginal") or d.get("DateTimeOriginal") or d.get("CreateDate")
    if dt:
        m = re.match(r"\s*(\d{4}):(\d\d):(\d\d)[ T](\d\d):(\d\d):(\d\d)(\.\d+)?", str(dt))
        if m:
            y, mo, da, h, mi, s = (int(m.group(i)) for i in range(1, 7))
            frac = float(m.group(7)) if m.group(7) else 0.0
            try:
                res["capture_ts"] = datetime(y, mo, da, h, mi, s).timestamp() + frac
            except ValueError:
                pass
    make = str(d.get("Make") or "").strip()
    model = str(d.get("Model") or "").strip()
    res["camera"] = f"{make} {model}".strip() or None
    lens = d.get("LensModel") or d.get("LensType")
    res["lens"] = str(lens).strip() if lens else None
    return res


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
    # For files our TIFF/JPEG parsers can't read (notably CR3), fill any gaps with exiftool.
    if out["capture_ts"] is None or out["camera"] is None:
        alt = _exif_via_exiftool(path)
        for k in ("capture_ts", "camera", "lens"):
            if out.get(k) is None and alt.get(k) is not None:
                out[k] = alt[k]
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
    """Sharpness (variance of a 4-neighbour Laplacian) + exposure from the histogram +
    monochrome (mean HSV saturation) — all deterministic, no VLM confabulation risk."""
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

    sat = np.asarray(im.convert("HSV"))[:, :, 1]
    monochrome = bool(sat.mean() < MONOCHROME_SAT_MAX)

    return {
        "sharpness": round(sharp, 1),
        "blown_pct": round(blown, 2),
        "crushed_pct": round(crushed, 2),
        "mean_lum": round(mean_lum, 1),
        "exposure_flag": flag,
        "monochrome": int(monochrome),
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
        "activity": {"type": "string"},
        "indoor_outdoor": {"type": "string"},
        "time_of_day": {"type": "string"},
        "animals": {"type": "array", "items": {"type": "string"}},
        "content_type": {"type": "string"},
        "visible_text": {"type": "string"},
    },
    "required": ["caption", "subject", "scene", "people_count", "eyes_closed",
                 "aesthetic", "tags", "issues", "keep_hint",
                 "activity", "indoor_outdoor", "time_of_day", "animals",
                 "content_type", "visible_text"],
}

VLM_PROMPT = (
    "You are a photo-culling editor doing a first pass. Return JSON.\n"
    "Do NOT judge exposure, focus or sharpness — those are measured separately.\n"
    "Judge only what you can clearly see:\n"
    "- caption: one sentence describing ONLY what is visibly present. Do NOT name a specific "
    "city, landmark, brand, or art style unless text/signage in the image states it — stay "
    "generic (say 'an old European town', not 'Granada').\n"
    "- subject: the single main subject (a few words).\n"
    "- scene: one genre word (portrait, landscape, wildlife, street, macro, architecture, "
    "food, event, sports, night, other).\n"
    "- people_count: number of people whose faces are visible.\n"
    "- eyes_closed: true ONLY if the main subject's eyelids are clearly shut mid-blink. A "
    "downward gaze, squinting from a smile or laugh, singing, or a face turned away is NOT "
    "eyes_closed; do not set true just because someone in the background might be blinking.\n"
    "- aesthetic: 1-10, and use the whole range: 1-3 throwaway, 4-6 competent but ordinary, "
    "7-8 strong, 9-10 exceptional. Most frames are 4-6; reserve 8+ for genuinely strong "
    "images. Weak composition scores low even if the subject is appealing.\n"
    "- tags: 4-8 short lowercase keywords (subject, setting, activity, mood); no filler like "
    "'photo', 'image', 'picture'.\n"
    "- issues: every distracting element you can find, including easily-missed ones — cable or "
    "power lines across the frame, poles, cranes, signs, a stray limb, a merge (a pole growing "
    "out of a head), or a horizon line through a person. Empty list only if truly clean.\n"
    "- keep_hint: true if this looks worth keeping as a photograph.\n"
    "- activity: what the subject is doing, a few words (e.g. 'hiking a ridge trail', 'blowing "
    "out birthday candles'). Empty string if nothing identifiable is happening.\n"
    "- indoor_outdoor: one of indoor, outdoor, unknown.\n"
    "- time_of_day: one of day, golden_hour, blue_hour, night, unknown. Only golden_hour/blue_hour "
    "if the warm/cool cast is unmistakable; default to day or night otherwise.\n"
    "- animals: any animals clearly visible (e.g. ['dog']); empty list if none.\n"
    "- content_type: one of photo, screenshot, document, graphic. 'photo' unless this is "
    "obviously a screen capture, a scanned/photographed document or receipt, or a graphic/meme.\n"
    "- visible_text: transcribe short legible text ONLY if you can actually read it clearly — a "
    "sign, menu, plaque, license plate, or similar. Do NOT guess, complete, or infer text you "
    "can't read cleanly, and do NOT name a location from it beyond what's literally written. "
    "Empty string if there's no legible text.\n"
    "Return only JSON."
)

# Auto-derived prompt identity: changes exactly when the prompt text changes, so a row's
# prompt_version can never silently drift from the text that produced it. The full text is also
# saved to the `prompts` table (register_prompt) so any version is reconstructable.
VLM_PROMPT_VERSION = hashlib.sha256(VLM_PROMPT.encode("utf-8")).hexdigest()[:12]


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


def _as_enum(x, choices, default):
    v = str(x or "").strip().lower().replace(" ", "_")
    return v if v in choices else default


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
        "activity": _as_str(d.get("activity"), 80),
        "indoor_outdoor": _as_enum(d.get("indoor_outdoor"), {"indoor", "outdoor"}, "unknown"),
        "time_of_day": _as_enum(d.get("time_of_day"), {"day", "golden_hour", "blue_hour", "night"}, "unknown"),
        "animals": _as_taglist(d.get("animals"), 5),
        "content_type": _as_enum(d.get("content_type"), {"photo", "screenshot", "document", "graphic"}, "photo"),
        "visible_text": _as_str(d.get("visible_text"), 200),
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


def infer_openai(base_url: str, api_key: "str | None", model: str, jpeg: bytes,
                 timeout: float = CALL_TIMEOUT, think: "bool | None" = None) -> str:
    """One OpenAI-compatible /chat/completions call with an inline image — the pluggable backend.
    Works against vLLM, LM Studio, or Ollama's OpenAI endpoint (base_url like http://host:port/v1).
    Returns the raw assistant text (JSON per VLM_PROMPT); caller runs it through coerce_vlm."""
    import base64
    import urllib.error
    import urllib.request
    b64 = base64.b64encode(jpeg).decode()
    body = {
        "model": model,
        "temperature": 0,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": VLM_PROMPT},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
        ]}],
        "response_format": {"type": "json_object"},
    }
    if think is not None:
        body["think"] = think  # Ollama extension: skip chain-of-thought on thinking-capable models
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(base_url.rstrip("/") + "/chat/completions",
                                 data=json.dumps(body).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:                       # surface the server's real message
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}") from None
    return data["choices"][0]["message"]["content"]


# ----------------------------------------------------------------------------
# Semantic search: text embeddings over the VLM's own caption/tags/scene output
# ----------------------------------------------------------------------------

EMBED_RECIPE_VERSION = "v1"  # bump when build_embed_text()'s field selection changes
EMBED_VERSION = f"{EMBED_MODEL}:{EMBED_RECIPE_VERSION}"  # composite key for the embeddings table


def build_embed_text(row: dict) -> str:
    """Flatten a photo's already-generated VLM fields into one text blob to embed. Reuses the
    caption/subject/scene/tags/etc already produced during `run` -- no extra model call needed
    beyond the embedding itself, and search recall tracks whatever the VLM prompt actually asks for."""
    tags = []
    try:
        tags = json.loads(row.get("tags") or "[]")
    except (TypeError, ValueError):
        pass
    bits = [row.get("caption") or ""]
    for label, key in (("Subject", "subject"), ("Scene", "scene"), ("Activity", "activity"),
                        ("Setting", "indoor_outdoor"), ("Time", "time_of_day"),
                        ("Animals", "animals"), ("Contains", "content_type")):
        val = (row.get(key) or "").strip()
        if val and val.lower() not in ("none", "n/a", "unknown", "no"):
            bits.append(f"{label}: {val}.")
    if tags:
        bits.append("Tags: " + ", ".join(str(t) for t in tags) + ".")
    return " ".join(b for b in bits if b).strip()


def infer_embed(base_url: str, api_key: "str | None", model: str, text: str,
                timeout: float = 30) -> list:
    """One OpenAI-compatible /embeddings call -- same base_url convention as infer_openai
    (Ollama's /v1 endpoint by default)."""
    import urllib.error
    import urllib.request
    body = {"model": model, "input": text}
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(base_url.rstrip("/") + "/embeddings",
                                 data=json.dumps(body).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}") from None
    return data["data"][0]["embedding"]


def pack_vector(vec) -> bytes:
    return np.asarray(vec, dtype=np.float32).tobytes()


def unpack_vector(blob: bytes) -> np.ndarray:
    return np.frombuffer(blob, dtype=np.float32)


# ----------------------------------------------------------------------------
# Verdict / rating derivation
# ----------------------------------------------------------------------------

def derive(cv: dict, vlm: dict) -> dict:
    blurry = cv["sharpness"] < SHARP_FLOOR
    bad_exp = cv["exposure_flag"] != "ok"
    severe_exp = cv["blown_pct"] > BLOWN_PCT_SEVERE
    portrait = vlm["people_count"] > 0
    closed = portrait and vlm["eyes_closed"]

    # A frame qwen rates a keeper (aesthetic >= 7) OR any night frame is "trusted" over the CV
    # gate: its soft/over/under flags are usually SCENE ARTIFACTS, not defects — a bright sky or
    # snow field reads as "over", a flash-lit night portrait as "under", an intentionally
    # shallow-DoF macro as "soft". A trusted frame is never hard-rejected on CV, and only a
    # *severe* blowout docks a star (mild over/under is too noisy to score). Eyes-closed and
    # genuinely weak (aes<=3) frames still reject.
    trusted = vlm["aesthetic"] >= 7 or vlm.get("scene") == "night"

    stars = (vlm["aesthetic"] + 1) // 2   # 9-10->5, 7-8->4, 5-6->3, 3-4->2, 1-2->1
    stars -= 1 if (blurry and not trusted) else 0
    stars -= 1 if severe_exp else 0
    stars -= 1 if closed else 0
    stars = max(1, min(5, stars))

    if closed or vlm["aesthetic"] <= 3:
        verdict = "reject"
    elif (blurry or severe_exp) and not trusted:
        verdict = "reject"
    elif vlm["keep_hint"] and vlm["aesthetic"] >= 7 and not blurry:
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
        "keep_hint": int(vlm["keep_hint"]),
        "tags": json.dumps(vlm["tags"]),
        "issues": json.dumps(vlm["issues"]),
        "activity": vlm["activity"],
        "indoor_outdoor": vlm["indoor_outdoor"],
        "time_of_day": vlm["time_of_day"],
        "animals": json.dumps(vlm["animals"]),
        "content_type": vlm["content_type"],
        "visible_text": vlm["visible_text"],
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
        # best = the top *keeper* (so a burst with any keeper always retains exactly one keep);
        # fall back to overall best only when no frame in the burst was judged keep.
        keepers = [r for r in group if r["base_verdict"] == "keep"]
        best = max(keepers or group, key=lambda r: (r["aesthetic"] or 0, r["sharpness"] or 0))
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
        # Only cluster frames with reliable EXIF (a known camera + capture time). Formats whose
        # EXIF we can't read (e.g. CR3 -> camera is NULL, capture_ts fell back to file mtime) are
        # left as singletons rather than falsely grouped by copy-time.
        same_burst = (
            prev_ts is not None and ts is not None
            and r["camera"] is not None and prev_cam is not None
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
    "sharpness", "exposure_flag", "blown_pct", "crushed_pct", "monochrome",
    "subject", "scene", "caption", "tags", "issues",
    "activity", "indoor_outdoor", "time_of_day", "animals", "content_type", "visible_text",
    "people_count", "eyes_closed", "keep_hint", "is_best_in_burst", "burst_id",
    "reason", "user_rating", "user_label", "status", "error_class", "error_msg", "model_used",
    "prompt_version", "harness_version", "path",
]


def export_csv(conn: sqlite3.Connection, csv_path: Path):
    import csv
    rows = conn.execute("SELECT * FROM images ORDER BY capture_ts, filename").fetchall()
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            d = dict(r)
            for jcol in ("tags", "issues", "animals"):
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
    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
{rating_attr}    xmp:Label="{label}"
    photoshop:Instructions="{instructions}">
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
    """Flat keywords for BOTH dc:subject and lr:hierarchicalSubject. Everything must be flat and in
    dc:subject: Lightroom Classic's "Read Metadata from File" builds its keyword list from dc:subject
    and ignores hierarchical-only keywords, so the AI facets go in as flat, searchable tags
    (Stars-3, Cull-review, Scene-sports) instead of a Cull|review hierarchy LrC would silently drop."""
    tags = json.loads(row["tags"]) if row["tags"] else []
    kws = list(tags)
    if row["subject"]:
        kws.append(row["subject"].lower())
    if row["verdict"]:
        kws.append(f"Cull-{row['verdict']}")            # e.g. Cull-review  (search "Cull" or "review")
    if row["scene"]:
        kws.append(f"Scene-{row['scene']}")             # e.g. Scene-sports
    if row.get("quality_stars"):
        kws.append(f"Stars-{row['quality_stars']}")     # e.g. Stars-3  (search "Stars")
    if row["is_best_in_burst"] and (row["burst_size"] or 1) > 1:
        kws.append("pick-best")
    if row.get("activity"):
        kws.append(row["activity"].lower())
    if row.get("indoor_outdoor") in ("indoor", "outdoor"):
        kws.append(row["indoor_outdoor"].capitalize())  # Indoor / Outdoor
    if row.get("time_of_day") and row["time_of_day"] != "unknown":
        kws.append(f"Time-{row['time_of_day'].replace('_', '')}")  # e.g. Time-goldenhour
    if row.get("animals"):
        kws += [a.lower() for a in json.loads(row["animals"])]
    if row.get("content_type") and row["content_type"] != "photo":
        kws.append(f"Type-{row['content_type']}")       # e.g. Type-screenshot (photos stay untagged)
    if row.get("visible_text"):
        kws.append(row["visible_text"][:80])
    if row.get("monochrome"):
        kws.append("Monochrome")
    seen, out = set(), []                               # de-dup, preserve order
    for t in kws:
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out, out


def _ai_note(row: dict) -> str:
    """One-line AI readout for the Instructions field — a channel LR shows but you don't cull by:
    'AI 3* review - soft/blurred'. Keeps the model's suggestion visible without touching Rating."""
    stars = row.get("quality_stars") or 0
    parts = [f"AI {stars}★", row.get("verdict") or "?"]
    reason = row.get("reason") or ""
    tail = reason.split(":", 1)[1].strip() if ":" in reason else ""
    if tail:
        parts.append(tail)
    return " · ".join(parts)


def _read_xmp_fields(path: Path) -> dict:
    """Read Rating/Label/Description already present in a sidecar (via exiftool)."""
    exe = _exiftool_available()
    if not exe:
        return {}
    try:
        proc = subprocess.run([exe, "-j", "-XMP:Rating", "-XMP:Label", "-XMP-dc:Description",
                               "-XMP-dc:Subject", "-XMP-lr:HierarchicalSubject",
                               "-XMP-photoshop:Instructions", str(path)],
                              capture_output=True, text=True, timeout=30)
        data = json.loads(proc.stdout or "[]")
    except Exception:  # noqa: BLE001 - best effort
        return {}
    return data[0] if data else {}


def _read_xmp_ratings(sidecars: "list[Path]") -> dict:
    """Batch-read {sidecar-path-str -> exiftool dict (Rating/Label)} in one exiftool call per chunk."""
    exe = _exiftool_available()
    if not exe or not sidecars:
        return {}
    out = {}
    for i in range(0, len(sidecars), 500):
        chunk = [str(p) for p in sidecars[i:i + 500]]
        try:
            proc = subprocess.run([exe, "-j", "-XMP:Rating", "-XMP:Label", *chunk],
                                  capture_output=True, text=True, timeout=300)
            for d in json.loads(proc.stdout or "[]"):
                out[d.get("SourceFile", "")] = d
        except Exception:  # noqa: BLE001 - best effort
            pass
    return out


def _merge_ai_into_sidecar(target: Path, row: dict, ai_rating: bool = False) -> bool:
    """Add AI caption/keywords/label/Cull-verdict + a Stars|N keyword + an Instructions note to an
    existing sidecar WITHOUT overwriting anything you set. xmp:Rating is written only when
    ai_rating=True (and even then only into a blank), so your star distribution stays yours. Needs
    exiftool."""
    exe = _exiftool_available()
    if not exe:
        return False
    have = _read_xmp_fields(target)
    flat, hier = build_keywords(row)

    def _have_set(v):        # exiftool returns a str for one value, a list for many
        return set() if v in (None, "") else ({v} if isinstance(v, str) else set(v))
    have_subj, have_hier = _have_set(have.get("Subject")), _have_set(have.get("HierarchicalSubject"))

    args = [exe, "-overwrite_original", "-m", "-P"]
    args += [f"-XMP-dc:Subject+={k}" for k in flat if k not in have_subj]            # add only new
    args += [f"-XMP-lr:HierarchicalSubject+={k}" for k in hier if k not in have_hier]
    if row.get("caption") and not have.get("Description"):
        args.append(f"-XMP-dc:Description={row['caption']}")
    if ai_rating and have.get("Rating") in (None, ""):
        args.append(f"-XMP-xmp:Rating={row['quality_stars'] or 0}")
    if have.get("Label") in (None, "") and row.get("color_label"):
        args.append(f"-XMP-xmp:Label={row['color_label']}")
    note, cur = _ai_note(row), (have.get("Instructions") or "")
    if note != cur and (cur == "" or cur.startswith("AI ")):    # AI-owned note; never clobber yours
        args.append(f"-XMP-photoshop:Instructions={note}")
    if len(args) == 4:       # nothing new to add (all present) -> idempotent no-op
        return True
    args.append(str(target))
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=60).returncode == 0
    except Exception:  # noqa: BLE001
        return False


def _is_under(path: Path, base: Path) -> bool:
    try:
        path.relative_to(base)
        return True
    except ValueError:
        return False


def write_xmp_sidecars(conn: sqlite3.Connection, force: bool, xmp_dir: "Path | None" = None,
                       merge: bool = False, folders: "list[Path] | None" = None,
                       ai_rating: bool = False) -> dict:
    stats = {"written": 0, "merged": 0, "merge_failed": 0, "skipped_exists": 0, "skipped_notok": 0}
    if merge and not _exiftool_available():
        print("  (exiftool not found -> falling back to non-merge: existing sidecars are left "
              "untouched; only missing ones are written, so nothing you set is clobbered.)")
        merge = False
    rows = [dict(r) for r in conn.execute("SELECT * FROM images").fetchall()]
    if xmp_dir is not None:
        xmp_dir = Path(xmp_dir)
    folders = [Path(f).resolve() for f in folders] if folders else None

    for row in rows:
        if row["status"] != "ok":
            stats["skipped_notok"] += 1
            continue
        src = Path(row["path"])
        if folders and not any(_is_under(src, f) for f in folders):
            continue
        if xmp_dir is not None:
            # Mirror the full source path (minus the leading '/') under xmp_dir, so every
            # sidecar maps 1:1 to its RAW and can later be rsync'd back next to it.
            rel = Path(*src.parts[1:]) if src.is_absolute() else src
            sidecar = xmp_dir / rel.with_suffix(".xmp")
            sidecar.parent.mkdir(parents=True, exist_ok=True)
        else:
            sidecar = src.with_suffix(".xmp")

        # --merge: start from the user's existing sidecar (their rating/label/develop) and only
        # ADD the AI fields, so nothing set by hand is lost.
        existing = src.with_suffix(".xmp")
        if merge and existing.exists():
            if sidecar != existing and sidecar.exists() and not force:
                stats["skipped_exists"] += 1
                continue
            try:
                if sidecar != existing:
                    shutil.copy2(existing, sidecar)
            except OSError:
                stats["merge_failed"] += 1
                continue
            stats["merged" if _merge_ai_into_sidecar(sidecar, row, ai_rating) else "merge_failed"] += 1
            continue

        if sidecar.exists() and not force:
            stats["skipped_exists"] += 1
            continue
        flat, hier = build_keywords(row)
        subjects = "".join(f"    <rdf:li>{xml_escape(k)}</rdf:li>\n" for k in flat)
        hiers = "".join(f"    <rdf:li>{xml_escape(k)}</rdf:li>\n" for k in hier)
        rating_attr = f'    xmp:Rating="{row["quality_stars"] or 0}"\n' if ai_rating else ""
        xml = XMP_TEMPLATE.format(
            rating_attr=rating_attr,
            label=xml_escape(row["color_label"] or ""),
            instructions=xml_escape(_ai_note(row)),
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
    folders = [Path(f) for f in args.folder]
    for folder in folders:
        if not folder.is_dir():
            sys.exit(f"Not a folder: {folder}")
    import ollama

    # Emit our PID so the run can be stopped even if you forgot to capture $! at launch.
    pidfile = args.pidfile or Path(str(args.db) + ".pid")
    try:
        pidfile.write_text(str(os.getpid()))
    except OSError:
        pidfile = None

    try:
        conn = connect(args.db)
        exts = {"." + e.lower().lstrip(".") for e in args.ext} if args.ext else ALL_EXTENSIONS
        newly = 0
        for folder in folders:
            newly += register_targets(conn, folder, recursive=not args.no_recursive, exts=exts)

        if args.reprocess:
            ph = ",".join("?" * len(args.reprocess))
            n = conn.execute(
                f"UPDATE images SET status='pending' WHERE status='ok' AND base_verdict IN ({ph})",
                args.reprocess).rowcount
            conn.commit()
            print(f"Reprocess: reset {n} row(s) with verdict {args.reprocess} back to pending.")

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
              f"at {MAX_EDGE}px.")
        if pidfile:
            print(f"PID {os.getpid()} written to {pidfile}  (stop with: kill -INT $(cat {pidfile}))")
        print()
        if not todo:
            print("Nothing to do. (Use --redrive to retry errors, --force to reprocess.)")
            return

        harness_ver = harness_version()
        register_prompt(conn, VLM_PROMPT_VERSION, VLM_PROMPT)
        print(f"Prompt {VLM_PROMPT_VERSION} · harness {harness_ver}  "
              f"(stamped on every row; prompt text saved to the `prompts` table)")

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
                result["prompt_version"] = VLM_PROMPT_VERSION
                result["harness_version"] = harness_ver
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
    finally:
        if pidfile:
            try:
                pidfile.unlink()
            except OSError:
                pass


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


def write_plugin_data(conn: sqlite3.Connection, out_path: Path,
                      folders: "list[Path] | None" = None, append: bool = False) -> int:
    """Write a TSV for the Lightroom 'AI Cull Sync' plugin — one ok photo per line:
        <shootFolder>\\t<filename>\\t<colorLabel>\\t<kw1|kw2|...>\\t<caption>
    The plugin applies ONLY these (color label + keywords + caption) to the catalog, never
    rating/flags, so nothing you set is overwritten. Uses the flat keywords from build_keywords
    (Stars-N, Cull-*, …). Caption goes into LrC's Caption field, IPTC-safe and independent of
    your ratings/flags. Matched by (shootFolder, filename) -- not filename alone -- since Sony
    resets its file counter across shoots, so this TSV can safely cover the WHOLE library in one
    sync (select All Photographs), not just one shoot at a time.

    append=True merges into an existing out_path instead of overwriting it -- keyed by
    (shootFolder, filename), so re-running the same shoot just refreshes its rows in place. Lets
    the ingest watcher accumulate many shoots into one pending TSV between Lightroom syncs,
    instead of leaving one file per shoot for you to click through."""
    folders = [Path(f).resolve() for f in folders] if folders else None
    rows: "dict[tuple, str]" = {}
    order = []

    if append and Path(out_path).exists():
        for line in Path(out_path).read_text(encoding="utf-8").splitlines():
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            key = (parts[0], parts[1])
            rows[key] = line
            order.append(key)

    for row in (dict(r) for r in conn.execute("SELECT * FROM images WHERE status='ok'")):
        path = Path(row["path"])
        if folders and not any(_is_under(path, f) for f in folders):
            continue
        flat, _ = build_keywords(row)
        kws = "|".join(k.replace("|", "/").replace("\t", " ") for k in flat)
        label = (row["color_label"] or "").replace("\t", " ")
        caption = (row["caption"] or "").replace("\t", " ").replace("\n", " ")
        shoot_folder = path.parent.name.replace("\t", " ")
        key = (shoot_folder, row["filename"])
        if key not in rows:
            order.append(key)
        rows[key] = f"{shoot_folder}\t{row['filename']}\t{label}\t{kws}\t{caption}"

    lines = [rows[k] for k in order]
    Path(out_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(lines)


def cmd_export(args):
    if not args.db.exists():
        sys.exit(f"No database at {args.db}. Run `photo_cull.py run <folder>` first.")
    conn = connect(args.db)
    cluster_bursts(conn, args.burst_gap)
    n = export_csv(conn, args.csv)
    print(f"Wrote {n} rows to {args.csv}")
    if args.plugin_data:
        m = write_plugin_data(conn, args.plugin_data, args.folder, append=args.plugin_data_append)
        verb = "row(s) now in" if args.plugin_data_append else "row(s) to"
        print(f"{'Merged' if args.plugin_data_append else 'Wrote'} {m} {verb} {args.plugin_data}  (for the Lightroom AI-Cull plugin).")
    if args.xmp or args.xmp_dir:
        stats = write_xmp_sidecars(conn, force=args.force_xmp, xmp_dir=args.xmp_dir,
                                   merge=args.merge, folders=args.folder, ai_rating=args.ai_rating)
        dest = f" into {args.xmp_dir}/ (mirroring the source tree)" if args.xmp_dir else " next to each photo"
        parts = [f"{stats['written']} written"]
        if stats["merged"]:
            parts.append(f"{stats['merged']} merged into existing")
        if stats["merge_failed"]:
            parts.append(f"{stats['merge_failed']} merge failed")
        parts += [f"{stats['skipped_exists']} skipped (exist; use --force-xmp)",
                  f"{stats['skipped_notok']} skipped (not ok)"]
        print(f"XMP sidecars{dest}: " + ", ".join(parts) + ".")
        if not args.xmp_dir:
            print("In Lightroom Classic: select photos -> Metadata > Read Metadata from File.")


def cmd_rederive(args):
    """Recompute each ok row's judgment (base_verdict / quality_stars / verdict / color_label /
    reason) from already-stored CV + VLM columns — no model calls. Use after a derive()/threshold
    change to re-judge the whole library in seconds instead of reprocessing. Idempotent. Leaves
    verdict == base_verdict (un-clustered), mirroring `run`; run `export` to re-cluster bursts."""
    if not args.db.exists():
        sys.exit(f"No database at {args.db}. Run `photo_cull.py run <folder>` first.")
    conn = connect(args.db)

    def base_dist():
        return {r["base_verdict"]: r["c"] for r in conn.execute(
            "SELECT base_verdict, COUNT(*) c FROM images WHERE status='ok' GROUP BY base_verdict")}

    before = base_dist()
    rows = conn.execute(
        "SELECT path, base_verdict, sharpness, exposure_flag, blown_pct, aesthetic, scene, "
        "people_count, eyes_closed, keep_hint, issues, subject FROM images WHERE status='ok'"
    ).fetchall()
    for r in rows:
        # keep_hint wasn't persisted before P1. If unknown, INFER it from the existing verdict:
        # a row already judged `keep` must have had keep_hint=True (old logic required it), and the
        # new keep rule is strictly more permissive — so preserving those is always safe. Unknowns
        # on non-keep rows stay False, so nothing is newly promoted without real data.
        keep_hint = bool(r["keep_hint"]) if r["keep_hint"] is not None else (r["base_verdict"] == "keep")
        cv = {"sharpness": r["sharpness"], "exposure_flag": r["exposure_flag"],
              "blown_pct": r["blown_pct"]}
        vlm = {"aesthetic": r["aesthetic"], "scene": r["scene"],
               "people_count": r["people_count"] or 0,
               "eyes_closed": bool(r["eyes_closed"]),
               "keep_hint": keep_hint,
               "issues": json.loads(r["issues"]) if r["issues"] else [],
               "subject": r["subject"] or ""}
        d = derive(cv, vlm)
        conn.execute(
            "UPDATE images SET base_verdict=?, quality_stars=?, verdict=?, color_label=?, reason=? "
            "WHERE path=?",
            (d["base_verdict"], d["quality_stars"], d["verdict"], d["color_label"], d["reason"], r["path"]))
    conn.commit()

    after = base_dist()
    print(f"Re-derived {len(rows)} ok row(s) from stored columns — no model calls, "
          f"harness {harness_version()}. pending/error rows untouched.")
    n_keephint = conn.execute(
        "SELECT COUNT(*) c FROM images WHERE status='ok' AND keep_hint IS NULL").fetchone()["c"]
    print("  base_verdict:")
    for v in ("keep", "review", "reject"):
        b, a = before.get(v, 0), after.get(v, 0)
        delta = f"  ({a - b:+d})" if a != b else ""
        print(f"    {v:7s} {b:6d} -> {a:6d}{delta}")
    if n_keephint:
        print(f"  note: {n_keephint} ok row(s) predate keep_hint -> existing keeps are preserved, "
              f"but review->keep promotions need a reprocess to capture keep_hint.")
    print("Next: `photo_cull.py export --xmp` to re-cluster bursts + regenerate CSV/sidecars.")


def _pearson(xs: list, ys: list):
    n = len(xs)
    if n < 2:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    sx = sum((x - mx) ** 2 for x in xs)
    sy = sum((y - my) ** 2 for y in ys)
    if sx == 0 or sy == 0:
        return None
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    return cov / (sx ** 0.5 * sy ** 0.5)


def _print_agreement(rows: list):
    """rows: dicts with quality_stars, verdict, user_rating (>=1). Print AI-vs-you agreement."""
    n = len(rows)
    print(f"\nAI suggestion vs your ratings (n={n} rated):")
    if not n:
        return
    ai = [r["quality_stars"] or 0 for r in rows]
    us = [r["user_rating"] for r in rows]
    exact = sum(1 for a, u in zip(ai, us) if a == u)
    within1 = sum(1 for a, u in zip(ai, us) if abs(a - u) <= 1)
    corr = _pearson(ai, us)
    print(f"  stars exact match : {exact}/{n} ({100 * exact // n}%)")
    print(f"  stars within +/-1 : {within1}/{n} ({100 * within1 // n}%)")
    if corr is not None:
        print(f"  star correlation  : {corr:+.2f}  (1.0 = perfect, 0 = none)")
    # The costly error: AI rejected a frame you actually rated a keeper. Cheap error: the reverse.
    false_reject = [r for r in rows if r["verdict"] == "reject" and r["user_rating"] >= 4]
    false_keep = [r for r in rows if r["verdict"] == "keep" and r["user_rating"] <= 2]
    print(f"  false REJECTS (AI reject, you rated >=4*): {len(false_reject)}   <- the costly misses")
    for r in false_reject[:10]:
        print(f"      {Path(r['path']).name:24s} you={r['user_rating']}*  ai={r['quality_stars']}*")
    print(f"  false keeps   (AI keep,   you rated <=2*): {len(false_keep)}")


def cmd_feedback(args):
    """Read your final Lightroom star rating (+ color label) back from each photo's XMP sidecar into
    the DB (user_rating/user_label), then report how well the AI's suggestion agreed with your call —
    the objective signal for tuning derive()/the prompt."""
    if not args.db.exists():
        sys.exit(f"No database at {args.db}. Run `photo_cull.py run <folder>` first.")
    if not _exiftool_available():
        sys.exit("feedback needs exiftool to read ratings from the .xmp sidecars.")
    conn = connect(args.db)
    folders = [Path(f).resolve() for f in args.folder] if args.folder else None

    want = []
    for r in conn.execute("SELECT path FROM images WHERE status='ok'"):
        src = Path(r["path"])
        if folders and not any(_is_under(src, f) for f in folders):
            continue
        side = src.with_suffix(".xmp")
        if side.exists():
            want.append((r["path"], side))
    read = _read_xmp_ratings([side for _, side in want])

    def _int(v):
        try:
            return int(v)
        except (TypeError, ValueError):
            return None

    n_rated = 0
    for path, side in want:
        d = read.get(str(side), {})
        ur = _int(d.get("Rating"))
        ul = d.get("Label") or None
        conn.execute("UPDATE images SET user_rating=?, user_label=? WHERE path=?", (ur, ul, path))
        if ur and ur >= 1:
            n_rated += 1
    conn.commit()

    print(f"Read {len(want)} sidecar(s) next to your RAWs; {n_rated} carry a star rating you set.")
    if not n_rated:
        print("No ratings found yet. In Lightroom: rate photos, then Metadata > Save Metadata to Files "
              "(or enable auto-write to XMP), and re-run feedback.")
        return
    rows = [dict(r) for r in conn.execute(
        "SELECT path, quality_stars, verdict, user_rating FROM images "
        "WHERE status='ok' AND user_rating >= 1")]
    if folders:
        rows = [r for r in rows if any(_is_under(Path(r["path"]), f) for f in folders)]
    _print_agreement(rows)


def cmd_analyze(args):
    """Run a model over a folder's `ok` images via an OpenAI-compatible endpoint and store its
    outputs in `analyses` (path, model, prompt_version) for A/B comparison. Reuses the CV metrics
    already in `images` and the same VLM_PROMPT, so only the model's judgment varies. Resumable:
    skips paths already analyzed by this model+prompt_version unless --force."""
    if not args.db.exists():
        sys.exit(f"No database at {args.db}. Run `photo_cull.py run <folder>` first.")
    conn = connect(args.db)
    api_key = args.api_key or os.environ.get("VLM_API_KEY")
    register_prompt(conn, VLM_PROMPT_VERSION, VLM_PROMPT)
    hv = harness_version()
    folders = [Path(f).resolve() for f in args.folder] if args.folder else None

    done_paths = set()
    if not args.force:
        done_paths = {r["path"] for r in conn.execute(
            "SELECT path FROM analyses WHERE model=? AND prompt_version=? AND status='ok'",
            (args.model, VLM_PROMPT_VERSION))}

    rows = [dict(r) for r in conn.execute(
        "SELECT path, sharpness, exposure_flag, blown_pct FROM images WHERE status='ok'")
        if r["path"] not in done_paths]
    if folders:
        rows = [r for r in rows if any(_is_under(Path(r["path"]), f) for f in folders)]
    if args.limit:
        rows = rows[: args.limit]
    if not rows:
        sys.exit("No matching ok images (need `run` to have populated `images` first).")
    print(f"Analyzing {len(rows)} image(s) with '{args.model}' via {args.base_url}  "
          f"(prompt {VLM_PROMPT_VERSION}, harness {hv}) -> analyses.")

    done = errs = 0
    t0 = time.time()
    for i, r in enumerate(rows, 1):
        path = r["path"]
        rec = {"path": path, "model": args.model, "prompt_version": VLM_PROMPT_VERSION,
               "harness_version": hv,
               "processed_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
        t_call = time.time()
        try:
            work = to_working(load_source(Path(path)), MAX_EDGE)
            raw = infer_openai(args.base_url, api_key, args.model, jpeg_bytes(work), CALL_TIMEOUT,
                               think=(False if args.no_think else None))
            rec["duration_s"] = round(time.time() - t_call, 2)
            vlm = coerce_vlm(extract_json(raw))
            cv = {"sharpness": r["sharpness"], "exposure_flag": r["exposure_flag"],
                  "blown_pct": r["blown_pct"]}
            d = derive(cv, vlm)
            rec.update({"status": "ok", "caption": vlm["caption"], "subject": vlm["subject"],
                        "scene": vlm["scene"], "people_count": vlm["people_count"],
                        "eyes_closed": int(vlm["eyes_closed"]), "aesthetic": vlm["aesthetic"],
                        "keep_hint": int(vlm["keep_hint"]), "tags": json.dumps(vlm["tags"]),
                        "issues": json.dumps(vlm["issues"]), **d})
            done += 1
            tag = f"{d['verdict']:6s} {d['quality_stars']}* aes={vlm['aesthetic']} {vlm['subject'][:24]} ({rec['duration_s']}s)"
        except Exception as e:  # noqa: BLE001
            rec["duration_s"] = round(time.time() - t_call, 2)
            rec.update({"status": "error", "error_class": "model", "error_msg": _exc_text(e)[:500]})
            errs += 1
            tag = f"ERROR {_exc_text(e)[:70]}"
        cols = ", ".join(rec)
        conn.execute(f"INSERT OR REPLACE INTO analyses({cols}) VALUES({', '.join('?' * len(rec))})",
                     tuple(rec.values()))
        conn.commit()
        print(f"[{i}/{len(rows)}] {Path(path).name:24s} -> {tag}")
    fol = (" --folder " + " ".join(str(f) for f in args.folder)) if args.folder else ""
    print(f"\nDone: {done} ok / {errs} error in {_fmt_eta(time.time() - t0)}.  "
          f"Next: photo_cull.py compare --model '{args.model}'{fol}")


def cmd_embed(args):
    """Embed each `ok` image's caption/tags/etc (build_embed_text) into `embeddings`, for semantic
    search (see review/server.py's /api/semantic_search). Resumable: skips paths already embedded
    at the current EMBED_VERSION unless --force. Cheap/fast (~60-80ms/image, text-only) compared to
    the VLM pass -- fine to run inline right after `run`, e.g. from the ingest watcher."""
    if not args.db.exists():
        sys.exit(f"No database at {args.db}. Run `photo_cull.py run <folder>` first.")
    conn = connect(args.db)
    folders = [Path(f).resolve() for f in args.folder] if args.folder else None
    api_key = args.api_key or os.environ.get("VLM_API_KEY")

    done_paths = set()
    if not args.force:
        done_paths = {r["path"] for r in conn.execute(
            "SELECT path FROM embeddings WHERE embed_version=?", (EMBED_VERSION,))}

    rows = [dict(r) for r in conn.execute(
        "SELECT path, caption, subject, scene, activity, indoor_outdoor, time_of_day, "
        "animals, content_type, tags FROM images WHERE status='ok'")
        if r["path"] not in done_paths]
    if folders:
        rows = [r for r in rows if any(_is_under(Path(r["path"]), f) for f in folders)]
    if args.limit:
        rows = rows[: args.limit]
    if not rows:
        print(f"Nothing to embed (all ok images already at embed_version={EMBED_VERSION}).")
        return
    print(f"Embedding {len(rows)} image(s) with '{EMBED_MODEL}' via {args.base_url}  "
          f"(embed_version {EMBED_VERSION}) -> embeddings.")

    done = errs = skipped = 0
    t0 = time.time()
    for i, r in enumerate(rows, 1):
        path = r["path"]
        text = build_embed_text(r)
        if not text:
            skipped += 1
            continue  # nothing to embed (e.g. blank caption) -- leave unindexed, not an error
        try:
            vec = infer_embed(args.base_url, api_key, EMBED_MODEL, text)
            conn.execute(
                "INSERT OR REPLACE INTO embeddings(path, embed_version, model, dims, vector, created_at) "
                "VALUES(?,?,?,?,?,?)",
                (path, EMBED_VERSION, EMBED_MODEL, len(vec), pack_vector(vec),
                 datetime.now(timezone.utc).isoformat(timespec="seconds")))
            conn.commit()
            done += 1
        except Exception as e:  # noqa: BLE001
            errs += 1
            print(f"[{i}/{len(rows)}] {Path(path).name:24s} -> ERROR {_exc_text(e)[:70]}")
            continue
        if i % 200 == 0 or i == len(rows):
            elapsed = time.time() - t0
            eta = (elapsed / i) * (len(rows) - i)
            print(f"[{i}/{len(rows)}] embedded  ({elapsed/i*1000:.0f}ms/img, ETA {_fmt_eta(eta)})")
    print(f"\nDone: {done} ok / {skipped} skipped (no text) / {errs} error in {_fmt_eta(time.time() - t0)}.")
    if errs:   # non-zero, so the ingest watcher logs "embed FAILED" instead of carrying on silently
        sys.exit(1)


# ----------------------------------------------------------------------------
# Geotags: GPS from EXIF, and an offline place name from GeoNames
# ----------------------------------------------------------------------------
GEO_DIR_DEFAULT = "trial_out/geo"   # cities1000.txt, admin1CodesASCII.txt, countryInfo.txt
GEO_URL = "https://download.geonames.org/export/dump/"   # free, CC BY 4.0


def read_gps(paths: "list[str]") -> "dict[str, tuple | None]":
    """{path: (lat, lon), or None when the file has no GPS}. exiftool reads every format in the
    library (CR3 and HEIC included) and signs the coordinates. Four exiftool processes run at once
    on 500 files each: over the NAS each file costs about 0.1 s of waiting, not CPU."""
    from concurrent.futures import ThreadPoolExecutor

    def run(batch):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write("\n".join(batch) + "\n")
            argfile = fh.name
        try:
            return subprocess.run(["exiftool", "-n", "-T", "-fast2", "-FilePath", "-Composite:GPSLatitude",
                                   "-Composite:GPSLongitude", "-@", argfile],
                                  capture_output=True, text=True, timeout=900).stdout
        finally:
            os.unlink(argfile)

    out = {}
    with ThreadPoolExecutor(4) as pool:
        outputs = list(pool.map(run, [paths[i:i + 500] for i in range(0, len(paths), 500)]))
    for stdout in outputs:
        for line in stdout.splitlines():
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            try:
                lat, lon = float(parts[1]), float(parts[2])
            except ValueError:
                out[parts[0]] = None
                continue
            out[parts[0]] = None if (lat == 0 and lon == 0) else (lat, lon)
    return out


class Places:
    """Nearest GeoNames town (population 1000+) to a point, offline: 'Lanai City, Hawaii, United
    States'. A town, not an address -- out in the wilds it names the nearest one."""

    def __init__(self, geo_dir: Path):
        from scipy.spatial import cKDTree
        geo_dir = Path(geo_dir)
        if not (geo_dir / "cities1000.txt").exists():
            sys.exit(f"No GeoNames data in {geo_dir}. Download cities1000.zip (unzip it), "
                     f"admin1CodesASCII.txt and countryInfo.txt from {GEO_URL}")
        regions = {}
        for line in (geo_dir / "admin1CodesASCII.txt").read_text(encoding="utf-8").splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                regions[parts[0]] = parts[1]
        countries = {}
        for line in (geo_dir / "countryInfo.txt").read_text(encoding="utf-8").splitlines():
            parts = line.split("\t")
            if line and not line.startswith("#") and len(parts) > 4:
                countries[parts[0]] = parts[4]
        self.labels, pts = [], []
        for line in (geo_dir / "cities1000.txt").read_text(encoding="utf-8").splitlines():
            f = line.split("\t")
            lat, lon = float(f[4]), float(f[5])
            cc = f[8]
            region = regions.get(f"{cc}.{f[10]}", "")
            self.labels.append(", ".join(x for x in (f[1], region, countries.get(cc, cc)) if x))
            pts.append(self._xyz(lat, lon))
        self.tree = cKDTree(np.array(pts))

    @staticmethod
    def _xyz(lat, lon):
        la, lo = np.radians(lat), np.radians(lon)
        return (np.cos(la) * np.cos(lo), np.cos(la) * np.sin(lo), np.sin(la))

    def name(self, lat: float, lon: float) -> str:
        return self.labels[int(self.tree.query(self._xyz(lat, lon))[1])]


def cmd_geotag(args):
    """Read GPS from each ok image not yet checked (or all with --force) into gps_lat/gps_lon, and
    name the nearest town in `place`. Resumable; the ingest watcher runs it for each new shoot."""
    if not args.db.exists():
        sys.exit(f"No database at {args.db}. Run `photo_cull.py run <folder>` first.")
    conn = connect(args.db)
    places = Places(args.geo_dir)
    q = "SELECT path FROM images WHERE status='ok'" + ("" if args.force else " AND gps_checked IS NULL")
    paths = [r["path"] for r in conn.execute(q)]
    if args.folder:
        folders = [Path(f).resolve() for f in args.folder]
        paths = [p for p in paths if any(_is_under(Path(p), f) for f in folders)]
    if not paths:
        print("Nothing to geotag.")
        return
    t0, found = time.time(), 0
    for i in range(0, len(paths), 2000):
        chunk = paths[i:i + 2000]
        gps = read_gps(chunk)
        rows = []
        for p in chunk:
            g = gps.get(p)
            rows.append((g[0] if g else None, g[1] if g else None, places.name(*g) if g else None, p))
            found += bool(g)
        conn.executemany("UPDATE images SET gps_lat=?, gps_lon=?, place=?, gps_checked=1 WHERE path=?", rows)
        conn.commit()
        print(f"[{min(i + 2000, len(paths))}/{len(paths)}] {found} with GPS so far "
              f"({_fmt_eta(time.time() - t0)})", flush=True)
    print(f"Done: {found} of {len(paths)} image(s) have GPS.")


# ----------------------------------------------------------------------------
# Day summaries: two lines per shoot folder, from the annotations, by a local text model
# ----------------------------------------------------------------------------
DAYSUM_MODEL = "qwen3.5:9b"
DAYSUM_VERSION = "v1"          # bump when the prompt or the facts change, to regenerate every day
DAYSUM_MAX_LINES = 80          # photo lines per day; busier days are sampled evenly across the day
DAYSUM_PROMPT = """You write two-line summaries of a day of photos for a photographer's personal archive.
Below are facts about the day and short AI descriptions of its photos, one line per group of near-identical shots, in the order they were taken.

Return JSON with two fields:
- "day": what the day was, in under 14 words. Name a place only if it appears in "Places"; otherwise describe the setting (coast, forest, city streets). Never guess a country, region or city.
- "highlights": the notable subjects or moments, in under 20 words, roughly in the order they happened.

Plain and factual. Do not mention the date, weekday or number of photos. No emoji, no hype, no names of people.

{facts}"""
DAYSUM_SCHEMA = {"type": "object", "properties": {"day": {"type": "string"}, "highlights": {"type": "string"}},
                 "required": ["day", "highlights"]}
_WEEKDAY_LEAD = re.compile(r"^(?:on )?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b[,\s]*(?:in |at |of |featuring )?",
                           re.IGNORECASE)


def day_facts(rows: "list[dict]") -> str:
    """What the model sees for one shoot folder: when, where (GPS towns), the commonest subjects,
    then one line per burst (time, caption, first tags) in shot order. rows: the folder's ok
    images, in capture order."""
    from collections import Counter
    seen, lines = set(), []
    for r in rows:
        key = r.get("burst_id") or r["path"]
        if key in seen:
            continue
        seen.add(key)
        t = datetime.fromtimestamp(r["capture_ts"]).strftime("%H:%M") if r.get("capture_ts") else "--:--"
        try:
            tags = ", ".join(json.loads(r.get("tags") or "[]")[:4])
        except (ValueError, TypeError):
            tags = ""
        lines.append(f"{t} {(r.get('caption') or '').strip()}" + (f" [{tags}]" if tags else ""))
    if len(lines) > DAYSUM_MAX_LINES:
        lines = [lines[round(i * (len(lines) - 1) / (DAYSUM_MAX_LINES - 1))] for i in range(DAYSUM_MAX_LINES)]
    ts = [r["capture_ts"] for r in rows if r.get("capture_ts")]
    places = Counter(r["place"] for r in rows if r.get("place"))
    subjects = Counter((r.get("subject") or "").lower() for r in rows if r.get("subject"))
    when = (f"Shooting {datetime.fromtimestamp(min(ts)).strftime('%H:%M')} to "
            f"{datetime.fromtimestamp(max(ts)).strftime('%H:%M')}; " if ts else "")
    return "\n".join([
        f"{when}{len(rows)} photos in {len(seen)} groups.",
        "Places (from GPS): " + ("; ".join(f"{p} ({n} photos)" for p, n in places.most_common(4))
                                 if places else "none recorded") + ".",
        "Most common subjects: " + ", ".join(f"{s} ({n})" for s, n in subjects.most_common(8)) + ".",
        "Photos in order:",
    ] + lines)


def infer_daysum(base_url: str, model: str, facts: str, timeout: float = 300) -> str:
    """One call to Ollama's native /api/chat (it takes num_ctx and think, which the OpenAI endpoint
    doesn't). Returns the two lines joined by a newline."""
    import urllib.request
    body = {"model": model, "think": False, "stream": False, "format": DAYSUM_SCHEMA,
            "options": {"num_ctx": 8192, "temperature": 0.3},
            "messages": [{"role": "user", "content": DAYSUM_PROMPT.format(facts=facts)}]}
    req = urllib.request.Request(base_url.rstrip("/") + "/api/chat", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        out = json.loads(json.loads(resp.read().decode())["message"]["content"])
    day = _WEEKDAY_LEAD.sub("", out["day"].strip()).strip()
    day = day[:1].upper() + day[1:]
    return day.rstrip(".") + ".\n" + out["highlights"].strip().rstrip(".") + "."


def cmd_daysum(args):
    """Summarise each shoot folder in two lines from its annotations, newest first. Skips folders
    whose facts haven't changed since their summary (unless --force)."""
    if not args.db.exists():
        sys.exit(f"No database at {args.db}. Run `photo_cull.py run <folder>` first.")
    conn = connect(args.db)
    by_folder: "dict[str, list]" = {}
    for r in conn.execute("SELECT path, capture_ts, caption, subject, tags, place, burst_id FROM images "
                          "WHERE status='ok' ORDER BY capture_ts, filename"):
        r = dict(r)
        by_folder.setdefault(str(Path(r["path"]).parent), []).append(r)
    if args.folder:
        wanted = {str(Path(f).resolve()) for f in args.folder}
        by_folder = {k: v for k, v in by_folder.items() if k in wanted}
    known = {r["folder"]: r["input_hash"] for r in conn.execute("SELECT folder, input_hash FROM day_summaries")}
    todo = []
    for folder, rows in sorted(by_folder.items(), key=lambda kv: kv[0], reverse=True):
        facts = day_facts(rows)
        h = hashlib.sha1(f"{DAYSUM_VERSION}|{args.model}|{facts}".encode()).hexdigest()
        if args.force or known.get(folder) != h:
            todo.append((folder, rows, facts, h))
    if not todo:
        print("Every folder's summary is up to date.")
        return
    print(f"Summarising {len(todo)} folder(s) with {args.model} via {args.ollama} ...", flush=True)
    t0, errs = time.time(), 0
    for i, (folder, rows, facts, h) in enumerate(todo, 1):
        try:
            summary = infer_daysum(args.ollama, args.model, facts)
        except Exception as e:  # noqa: BLE001 -- one bad day never stops the rest
            errs += 1
            print(f"[{i}/{len(todo)}] {folder}: ERROR {_exc_text(e)[:100]}", flush=True)
            continue
        conn.execute("INSERT OR REPLACE INTO day_summaries(folder, summary, model, version, frames, input_hash, created_at) "
                     "VALUES (?,?,?,?,?,?,?)",
                     (folder, summary, args.model, DAYSUM_VERSION, len(rows), h,
                      datetime.now(timezone.utc).isoformat(timespec="seconds")))
        conn.commit()
        if i % 25 == 0 or i == len(todo):
            print(f"[{i}/{len(todo)}] {Path(folder).name}: {summary.splitlines()[0]}  ({_fmt_eta(time.time() - t0)})", flush=True)
    print(f"Done: {len(todo) - errs} summarised, {errs} error(s).")
    if errs:   # non-zero, so the ingest watcher logs "daysum FAILED"
        sys.exit(1)


def cmd_compare(args):
    """Compare a model in `analyses` against the images baseline — and, if you've culled in LR,
    against your own ratings (the objective 'which model matches my taste' read)."""
    if not args.db.exists():
        sys.exit(f"No database at {args.db}.")
    conn = connect(args.db)
    folders = [Path(f).resolve() for f in args.folder] if args.folder else None
    rows = [dict(r) for r in conn.execute(
        "SELECT i.path, i.model_used base_model, i.verdict qv, i.quality_stars qs, i.aesthetic qa, "
        "i.user_rating ur, a.verdict av, a.quality_stars as_, a.aesthetic aa "
        "FROM images i JOIN analyses a USING(path) "
        "WHERE i.status='ok' AND a.status='ok' AND a.model=? AND a.prompt_version=?",
        (args.model, VLM_PROMPT_VERSION))]
    if folders:
        rows = [r for r in rows if any(_is_under(Path(r["path"]), f) for f in folders)]
    n = len(rows)
    if not n:
        sys.exit(f"No overlapping analyses for '{args.model}'. Run `analyze --model {args.model}` first.")
    base = rows[0]["base_model"] or "baseline"
    print(f"Comparing {n} photo(s):  {base} (images)  vs  {args.model} (analyses)\n")

    agree = sum(1 for r in rows if r["qv"] == r["av"])
    print(f"Verdict agreement: {agree}/{n} ({100 * agree // n}%)")
    from collections import Counter
    for (qv, av), c in Counter((r["qv"], r["av"]) for r in rows if r["qv"] != r["av"]).most_common(6):
        print(f"    {base}={qv:6s} -> {args.model}={av:6s}: {c}")

    qa, aa = [r["qa"] or 0 for r in rows], [r["aa"] or 0 for r in rows]
    corr = _pearson(qa, aa)
    cstr = f"   (corr {corr:+.2f})" if corr is not None else ""
    print(f"\nAesthetic mean: {base} {sum(qa) / n:.1f}  vs  {args.model} {sum(aa) / n:.1f}{cstr}")

    rated = [r for r in rows if r["ur"] and r["ur"] >= 1]
    if rated:
        print(f"\nvs YOUR ratings (n={len(rated)} rated) — fewer false-rejects is better:")
        for label, vk, sk in ((base, "qv", "qs"), (args.model, "av", "as_")):
            fr = sum(1 for r in rated if r[vk] == "reject" and r["ur"] >= 4)
            ex = sum(1 for r in rated if (r[sk] or 0) == r["ur"])
            w1 = sum(1 for r in rated if abs((r[sk] or 0) - r["ur"]) <= 1)
            c = _pearson([r[sk] or 0 for r in rated], [r["ur"] for r in rated])
            print(f"    {label:18s} false-rejects={fr:<3d} stars_exact={ex}/{len(rated)} "
                  f"within1={w1}/{len(rated)} corr={'%+.2f' % c if c is not None else 'n/a'}")
    else:
        print("\n(no LR ratings yet — cull this shoot + run `feedback` to score each model vs your taste)")


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("run", help="Process one or more folders (resumable).")
    r.add_argument("folder", type=Path, nargs="+", help="One or more folders to scan recursively.")
    r.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    r.add_argument("--fast", action="store_true", help=f"Use {MODEL_FALLBACK} instead of {MODEL_PRIMARY}.")
    r.add_argument("--limit", type=int, help="Process at most N images this run.")
    r.add_argument("--ext", nargs="+", metavar="EXT",
                   help="Only queue these file extensions (e.g. --ext arw). Default: all supported types.")
    r.add_argument("--redrive", action="store_true", help="Also retry rows that previously errored.")
    r.add_argument("--force", action="store_true", help="Reprocess even images already marked ok.")
    r.add_argument("--reprocess", nargs="+", metavar="VERDICT", choices=["keep", "review", "reject"],
                   help="Reset already-done rows with these base verdicts back to pending and re-run them "
                        "(e.g. --reprocess reject after a prompt/threshold change).")
    r.add_argument("--no-recursive", action="store_true", help="Do not descend into subfolders.")
    r.add_argument("--pidfile", type=Path, default=None,
                   help="Write this process's PID here at start (default: <db>.pid) so you can stop it later.")
    r.set_defaults(func=cmd_run)

    s = sub.add_parser("status", help="Show counts and error breakdown.")
    s.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    s.add_argument("--errors", action="store_true", help="List every error row.")
    s.set_defaults(func=cmd_status)

    e = sub.add_parser("export", help="Cluster bursts, write CSV (+ optional XMP sidecars).")
    e.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    e.add_argument("--csv", type=Path, default=Path(CSV_DEFAULT))
    e.add_argument("--xmp", action="store_true", help="Also write .xmp sidecars next to each photo.")
    e.add_argument("--xmp-dir", type=Path, default=None,
                   help="Write .xmp sidecars into this local directory (mirroring the source tree) instead "
                        "of next to each RAW — e.g. when the RAWs live on a read-only network share.")
    e.add_argument("--no-merge", dest="merge", action="store_false",
                   help="Write fresh sidecars and skip any that already exist (unless --force-xmp). "
                        "Default MERGES: preserves your rating/label/description, adds only the AI "
                        "fields, and never duplicates keywords. Merge needs exiftool.")
    e.add_argument("--force-xmp", action="store_true",
                   help="With --no-merge, overwrite existing sidecars. (Ignored in the default merge "
                        "mode, which never clobbers your fields.)")
    e.add_argument("--folder", type=Path, nargs="+", metavar="DIR",
                   help="Only write sidecars for photos under these folders (e.g. just the new shoot). "
                        "Burst clustering + CSV still use the whole library.")
    e.add_argument("--plugin-data", type=Path, default=None, metavar="TSV",
                   help="Also write a TSV (filename, color label, keywords) for the Lightroom "
                        "AI-Cull plugin, which merges those into your catalog WITHOUT touching your "
                        "ratings/flags. Respects --folder.")
    e.add_argument("--plugin-data-append", action="store_true",
                   help="If --plugin-data's file already exists, merge new rows into it (keyed by "
                        "shoot folder + filename) instead of overwriting -- lets several runs pile "
                        "up into one TSV for a single Lightroom sync.")
    e.add_argument("--ai-rating", action="store_true",
                   help="Also write the AI's star suggestion to xmp:Rating (fills blanks only; merge "
                        "still preserves any rating you set). OFF by default so your star distribution "
                        "stays yours — the AI star always lands as a Stars|N keyword + Instructions note.")
    e.add_argument("--burst-gap", type=float, default=BURST_GAP_S, help="Seconds between frames to group as a burst.")
    e.set_defaults(func=cmd_export)

    rd = sub.add_parser("rederive",
                        help="Recompute verdict/stars/reason for ok rows from stored columns (no "
                             "model calls). Use after a derive()/threshold change.")
    rd.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    rd.set_defaults(func=cmd_rederive)

    fb = sub.add_parser("feedback",
                        help="Read your final LR ratings back from XMP and report AI-vs-you agreement.")
    fb.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    fb.add_argument("--folder", type=Path, nargs="+", metavar="DIR",
                    help="Only read/report photos under these folders.")
    fb.set_defaults(func=cmd_feedback)

    an = sub.add_parser("analyze", help="Run a model via an OpenAI-compatible endpoint into the "
                        "`analyses` table (for A/B model comparison).")
    an.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    an.add_argument("--model", required=True, help="Model id the server expects, e.g. glm-4.6v-flash.")
    an.add_argument("--base-url", default="http://localhost:11434/v1",
                    help="OpenAI-compatible base URL (default: local Ollama). vLLM/LM Studio: their /v1.")
    an.add_argument("--api-key", default=None, help="Bearer key if the endpoint needs one (else env VLM_API_KEY).")
    an.add_argument("--folder", type=Path, nargs="+", metavar="DIR", help="Limit to these folders.")
    an.add_argument("--limit", type=int, help="Analyze at most N images (handy for a quick trial).")
    an.add_argument("--force", action="store_true",
                    help="Reprocess paths already analyzed by this model+prompt_version too "
                         "(default: skip them, so a killed run resumes for free).")
    an.add_argument("--no-think", action="store_true",
                    help="Skip chain-of-thought on thinking-capable models (Ollama 'think:false' "
                         "extension) — much faster, e.g. qwen3.6:35b-a3b.")
    an.set_defaults(func=cmd_analyze)

    em = sub.add_parser("embed", help="Embed each ok image's caption/tags/etc into `embeddings`, "
                        "for semantic search (review/server.py's /api/semantic_search).")
    em.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    em.add_argument("--base-url", default="http://localhost:11434/v1",
                    help="OpenAI-compatible base URL for the embedding model (default: local Ollama).")
    em.add_argument("--api-key", default=None, help="Bearer key if the endpoint needs one (else env VLM_API_KEY).")
    em.add_argument("--folder", type=Path, nargs="+", metavar="DIR", help="Limit to these folders.")
    em.add_argument("--limit", type=int, help="Embed at most N images (handy for a quick trial).")
    em.add_argument("--force", action="store_true",
                    help="Re-embed paths already at the current EMBED_VERSION too (default: skip them).")
    em.set_defaults(func=cmd_embed)

    gt = sub.add_parser("geotag", help="Read GPS from EXIF and name the nearest town (offline, "
                        "GeoNames) into gps_lat/gps_lon/place, for Culling Bay's places.")
    gt.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    gt.add_argument("--folder", type=Path, nargs="+", metavar="DIR", help="Limit to these folders.")
    gt.add_argument("--geo-dir", type=Path, default=Path(GEO_DIR_DEFAULT),
                    help=f"GeoNames files (default: {GEO_DIR_DEFAULT}; from {GEO_URL}).")
    gt.add_argument("--force", action="store_true", help="Re-read images already checked.")
    gt.set_defaults(func=cmd_geotag)

    ds = sub.add_parser("daysum", help="Two-line summary of each shoot folder from its annotations, "
                        "by a local text model, for Culling Bay's day list.")
    ds.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    ds.add_argument("--folder", type=Path, nargs="+", metavar="DIR", help="Limit to these folders.")
    ds.add_argument("--model", default=DAYSUM_MODEL, help=f"Ollama text model (default {DAYSUM_MODEL}).")
    ds.add_argument("--ollama", default="http://localhost:11434", help="Ollama base URL (native API).")
    ds.add_argument("--force", action="store_true", help="Summarise again even if nothing changed.")
    ds.set_defaults(func=cmd_daysum)

    cp = sub.add_parser("compare", help="Compare a model in `analyses` vs the images baseline (and "
                        "vs your LR ratings).")
    cp.add_argument("--db", type=Path, default=Path(DB_DEFAULT))
    cp.add_argument("--model", required=True, help="The analyses model to compare against the baseline.")
    cp.add_argument("--folder", type=Path, nargs="+", metavar="DIR", help="Limit to these folders.")
    cp.set_defaults(func=cmd_compare)
    return p


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
