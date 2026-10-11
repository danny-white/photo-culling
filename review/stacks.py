"""How a day becomes stacks for Culling Bay Mobile.

Pure functions over rows from trial.db (no Flask, no DB handle), so they are unit-tested in
review/tests/test_stacks.py. The rules follow the design doc ("How a day becomes stacks"):

  1. pairs    a JPEG with the same stem as a RAW in the folder rides along with the RAW
  2. bursts   where the camera numbers its frames (Sony's SequenceNumber, read by photo_cull.py
              shotinfo), exactly one shutter press; otherwise consecutive frames from one camera
              within BURST_GAP_S, grouped after pairing
  3. kinds    'single', 'burst', 'bracket' (an exposure bracket: from the camera's drive mode where
              it says so, else dark, normal and bright frames in one burst) or 'pano' (frames that
              slide one way; confirmed from pixels)
  4. lead     the sharpest frame; in a bracket, the base exposure (the camera's first frame where
              it tags the bracket), else the sharpest normally exposed frame
  5. badges   measured only: Softer (than the sharpest frame of its burst), Blown, Dark -- never the AI's verdicts

Brackets and panoramas both suggest "Keep all": an HDR or panorama merge needs every frame.
"""
from __future__ import annotations

import math
import os

import numpy as np

BURST_GAP_S = 2.0            # photo_cull.BURST_GAP_S
PRESS_GAP_S = 60.0           # frames of one press further apart than this are a counter oddity, not one press
RAW_EXTENSIONS = {".arw", ".cr2", ".cr3", ".nef", ".dng", ".raf", ".orf", ".rw2", ".pef", ".srw"}

BRACKET_MIN_FRAMES = 3
BRACKET_LUM_SPREAD = 60.0    # mean luminance (0-255) between darkest and brightest frame
SOFT_RELATIVE = 0.35         # soft = under 35% of the sharpest normally exposed frame in its burst
BLOWN_PCT = 15.0             # photo_cull.BLOWN_PCT_SEVERE: share of pure-white pixels
DARK_LUM = 35.0              # photo_cull.MEAN_LUM_LOW: overall very dark
KEEP_PER_HOUR = 15          # pass 1's soft budget: stacks to keep per hour of shooting
SHOOTING_GAP_CAP_S = 600     # a pause longer than 10 minutes counts as 10: lunch is not shooting
KEEP_FLOOR = 5               # even a five-minute shoot may keep five
PANO_MIN_FRAMES = 3
PANO_PHASH_BITS = 20         # adjacent frames differ by at least this many of 64 phash bits
PANO_MIN_SHIFT = 0.08        # and slide at least this fraction of the frame, all the same way


def _stem(filename: str) -> str:
    return os.path.splitext(filename)[0].lower()


def _is_raw(filename: str) -> bool:
    return os.path.splitext(filename)[1].lower() in RAW_EXTENSIONS


def pair_frames(rows: list[dict]) -> list[dict]:
    """Collapse RAW+JPEG pairs. Returns frames in shot order; each frame is its primary row
    (the RAW when there is one) plus 'partners': the rows that ride along with it."""
    by_stem: dict[str, list[dict]] = {}
    for r in rows:
        by_stem.setdefault(_stem(r["filename"]), []).append(r)
    frames = []
    for group in by_stem.values():
        raws = [r for r in group if _is_raw(r["filename"])]
        if len(raws) == 1:
            others = [r for r in group if r is not raws[0]]
            frames.append(dict(raws[0], partners=others))
        else:  # no RAW, or several RAWs sharing a stem: no pairing, each stands alone
            frames.extend(dict(r, partners=[]) for r in group)
    frames.sort(key=lambda f: (f["capture_ts"] is None, f["capture_ts"] or 0, f["filename"]))
    return frames


def same_press(prev: dict, f: dict) -> bool | None:
    """Whether f continues prev's stack by the camera's own tags, or None when they can't say.
    Sony numbers the frames of each press from 1: a frame numbered 1 is a new press, however close
    in time (on 1 Oct the gap rule put a separate press into the next burst), and a press stays
    whole through a buffer stall longer than the gap. Only the 1 is reliable: a 5-frame bracket on
    1 Oct read 1, 2, 3, 3, 5. Single shots read 0. A bracket never runs into other frames."""
    if prev.get("drive") is None or f.get("drive") is None or prev.get("camera") != f.get("camera"):
        return None
    if prev.get("seq") is not None and f.get("seq") is not None:
        dt = (f["capture_ts"] - prev["capture_ts"]) if f["capture_ts"] is not None and prev["capture_ts"] is not None else None
        return f["seq"] > 1 and f["drive"] == prev["drive"] and dt is not None and 0 <= dt <= PRESS_GAP_S
    if (f["drive"] == "bracket") != (prev["drive"] == "bracket"):
        return False
    return None


def group_bursts(frames: list[dict], gap: float = BURST_GAP_S) -> list[list[dict]]:
    """One shutter press where the camera's tags say (same_press); otherwise consecutive frames
    from one camera within `gap` seconds. Frames without a capture time or camera (unreadable
    EXIF) stay single, as in photo_cull.cluster_bursts."""
    groups: list[list[dict]] = []
    prev = None
    for f in frames:
        same = None if prev is None else same_press(prev, f)
        if same is None:
            same = (prev is not None and f["capture_ts"] is not None and prev["capture_ts"] is not None
                    and f.get("camera") and prev.get("camera") == f.get("camera")
                    and f["capture_ts"] - prev["capture_ts"] <= gap)
        if same:
            groups[-1].append(f)
        else:
            groups.append([f])
        prev = f
    return groups


def is_bracket(group: list[dict]) -> bool:
    if len(group) >= 2 and all(f.get("drive") == "bracket" for f in group):
        return True                        # the camera says so
    if len(group) < BRACKET_MIN_FRAMES:
        return False
    lums = [f["mean_lum"] for f in group if f.get("mean_lum") is not None]
    flags = {f.get("exposure_flag") for f in group}
    return (len(lums) == len(group) and max(lums) - min(lums) >= BRACKET_LUM_SPREAD
            and "under" in flags and "over" in flags)


def _sharp(f: dict) -> float:
    return f["sharpness"] if f.get("sharpness") is not None else -1.0


def lead_of(group: list[dict], bracket: bool) -> dict:
    """The sharpest frame; ties go to the earlier one. In a bracket, the sharpest normally
    exposed frame, or failing that the one nearest the bracket's middle brightness."""
    if bracket and all(f.get("drive") == "bracket" for f in group):
        return group[0]   # the camera shoots the base exposure first (Sony; Canon's default AEB order)
    if bracket:
        normal = [f for f in group if f.get("exposure_flag") == "ok"]
        if normal:
            group = normal
        else:
            mid = sorted(f["mean_lum"] for f in group)[len(group) // 2]
            return min(group, key=lambda f: abs(f["mean_lum"] - mid))
    best = group[0]
    for f in group[1:]:
        if _sharp(f) > _sharp(best):
            best = f
    return best


def badges_of(f: dict, group: list[dict], bracket: bool) -> list[str]:
    """Measured hints, at the pipeline's severe thresholds (its broader over/under flag trips on
    bright skies and silhouettes). Soft only on normally exposed frames: a dark frame measures
    soft because it is dark. Nothing inside a bracket, where dark and bright frames are the point."""
    if bracket:
        return []
    if (f.get("blown_pct") or 0) > BLOWN_PCT:
        return ["Blown"]
    if f.get("mean_lum") is not None and f["mean_lum"] < DARK_LUM:
        return ["Dark"]
    if f.get("exposure_flag") != "ok":
        return []
    # Soft only by comparison within a burst. An absolute floor was tried and dropped: frames
    # under photo_cull's SHARP_FLOOR are mostly smooth, not soft -- clear sky, bokeh behind a
    # sharp portrait, night sky (checked on a contact sheet of the library, 2026-10-10).
    s = f.get("sharpness")
    if s is None or len(group) < 2:
        return []
    top = max((_sharp(g) for g in group if g.get("exposure_flag") == "ok"), default=-1.0)
    if top > 0 and s < SOFT_RELATIVE * top:
        return ["Softer"]
    return []


def phash_bits(a: str | None, b: str | None) -> int | None:
    if not a or not b:
        return None
    try:
        return bin(int(a, 16) ^ int(b, 16)).count("1")
    except ValueError:
        return None


def pano_candidate(group: list[dict]) -> bool:
    """Cheap first test from stored phashes: every adjacent pair differs a lot. Ordinary bursts
    differ by a few bits; frames of a sweep look like different pictures."""
    if len(group) < PANO_MIN_FRAMES or is_bracket(group):
        return False
    dists = [phash_bits(a.get("phash"), b.get("phash")) for a, b in zip(group, group[1:])]
    return all(d is not None and d >= PANO_PHASH_BITS for d in dists)


def phase_shift(a: np.ndarray, b: np.ndarray) -> tuple[float, float]:
    """(dy, dx) by which b's content moved relative to a, from phase correlation. Both are 2-D
    float arrays of the same shape (greyscale)."""
    h, w = a.shape
    win = np.outer(np.hanning(h), np.hanning(w))
    fa, fb = np.fft.fft2(a * win), np.fft.fft2(b * win)
    r = fa * np.conj(fb)
    r /= np.abs(r) + 1e-9
    corr = np.abs(np.fft.ifft2(r))
    py, px = np.unravel_index(int(np.argmax(corr)), corr.shape)
    dy = py if py <= h // 2 else py - h
    dx = px if px <= w // 2 else px - w
    return float(-dy), float(-dx)


def pano_confirmed(greys: list[np.ndarray]) -> bool:
    """Every adjacent shift goes the same way along one axis, by at least PANO_MIN_SHIFT of the
    frame, and dominates the other axis."""
    if len(greys) < PANO_MIN_FRAMES:
        return False
    shifts = [phase_shift(a, b) for a, b in zip(greys, greys[1:])]
    h, w = greys[0].shape
    for axis, size in ((1, w), (0, h)):
        along = [s[axis] for s in shifts]
        across = [s[1 - axis] for s in shifts]
        if (all(abs(v) >= PANO_MIN_SHIFT * size for v in along)
                and (all(v > 0 for v in along) or all(v < 0 for v in along))
                and all(abs(v) > abs(c) for v, c in zip(along, across))):
            return True
    return False


def shooting_hours(rows: list[dict]) -> float:
    """Time spent shooting: the gaps between consecutive frames, each capped at
    SHOOTING_GAP_CAP_S. First-to-last wall-clock time was tried and dropped: idle hours gave half
    the days no squeeze at all, and folders with broken timestamps spanned thousands of hours."""
    ts = sorted(r["capture_ts"] for r in rows if r.get("capture_ts") is not None)
    return sum(min(b - a, SHOOTING_GAP_CAP_S) for a, b in zip(ts, ts[1:])) / 3600


def keep_budget(rows: list[dict]) -> int:
    """Pass 1's soft limit: KEEP_PER_HOUR stacks per hour of shooting, at least KEEP_FLOOR."""
    return max(KEEP_FLOOR, math.ceil(KEEP_PER_HOUR * shooting_hours(rows)))


def build_stacks(rows: list[dict]) -> list[dict]:
    """A day's rows (any order) -> stacks in shot order. Panorama confirmation needs pixels, so
    candidates come back as kind 'burst' with pano_candidate=True for the caller to confirm."""
    stacks = []
    for group in group_bursts(pair_frames(rows)):
        bracket = is_bracket(group)
        lead = lead_of(group, bracket)
        kind = "single" if len(group) == 1 else ("bracket" if bracket else "burst")
        stacks.append({
            "kind": kind,
            "lead": lead["rowid"],
            "pano_candidate": kind == "burst" and pano_candidate(group),
            "frames": [{
                "id": f["rowid"],
                "file": f["filename"],
                "partners": [p["filename"] for p in f["partners"]],
                "partner_ids": [p["rowid"] for p in f["partners"]],
                "path": f["path"],
                "sharpness": f.get("sharpness"),
                "af": [f["af_u"], f["af_v"]] if f.get("af_u") is not None else None,   # AF point, upright fractions
                "badges": badges_of(f, group, bracket),
            } for f in group],
        })
    return stacks
