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
KEEP_PER_HOUR = 10          # the soft budget: stacks to keep per hour of shooting. Your median was
                             # 12.6, so 10 pushes on about half your days (15 rarely did; round two D15)
SHOOTING_GAP_CAP_S = 600     # a pause longer than 10 minutes counts as 10: lunch is not shooting
KEEP_FLOOR = 5               # even a five-minute shoot may keep five
PANO_MIN_FRAMES = 3
PANO_PHASH_BITS = 20         # adjacent frames differ by at least this many of 64 phash bits
PANO_MIN_SHIFT = 0.08        # and slide at least this fraction of the frame, all the same way
# A panorama shot press by press (each frame its own press, which Sony numbers from 1, so
# group_bursts keeps them apart). Calibrated on the whole library on 25 Nov 2026: these found all
# 22 real sweeps and let through 4 camera pans that look the same (an airshow, a gondola ride).
PANO_PRESS_GAP_S = 3.0       # the presses of a hand-held sweep come at most this far apart
PANO_STEP_MIN_PEAK = 0.035   # neighbours overlap: their phase-correlation peak reaches this (~0.02 unrelated)
PANO_STEP_MAX_CV = 0.35      # and the camera turns about as far each time (spread of the steps over their mean)


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


def phase_step(a: np.ndarray, b: np.ndarray) -> tuple[float, float, float]:
    """(dy, dx, peak): how far b's content moved from a's, as fractions of the frame's height and
    width, and how strongly the two overlap (the phase-correlation peak: about 0.02 for unrelated
    pictures, 0.04 to 0.5 for neighbouring frames of a sweep). Same-shape greyscale arrays."""
    h, w = a.shape
    win = np.outer(np.hanning(h), np.hanning(w))
    fa, fb = np.fft.fft2(a * win), np.fft.fft2(b * win)
    r = fa * np.conj(fb)
    r /= np.abs(r) + 1e-9
    corr = np.abs(np.fft.ifft2(r))
    py, px = np.unravel_index(int(np.argmax(corr)), corr.shape)
    dy = py if py <= h // 2 else py - h
    dx = px if px <= w // 2 else px - w
    return -dy / h, -dx / w, float(corr[py, px])


def _sweep_direction(step) -> tuple[str, bool, float] | None:
    """(axis, positive, along) when a step looks like one turn of a sweep, else None."""
    if step is None:
        return None
    dy, dx, peak = step
    if peak < PANO_STEP_MIN_PEAK:
        return None
    for axis, along, across in (("x", dx, dy), ("y", dy, dx)):
        if abs(along) >= PANO_MIN_SHIFT and abs(along) > abs(across):
            return axis, along > 0, abs(along)
    return None


def sweep_segments(steps: list) -> list[tuple[int, int]]:
    """Which frames of a run sweep, as (first, last) frame indices, inclusive. steps[i] is
    phase_step from frame i to frame i + 1, or None when it can't be measured. A sweep is at least
    PANO_MIN_FRAMES frames whose every step slides at least PANO_MIN_SHIFT of the frame along one
    axis, more than across it, the same way each time, with a peak of PANO_STEP_MIN_PEAK, and with
    steps of about the same size. A step that breaks the pattern ends one sweep and may start the
    next."""
    segs: list[tuple[int, int]] = []
    start, way, alongs = None, None, []

    def close(last: int) -> None:
        if start is not None and last - start + 1 >= PANO_MIN_FRAMES:
            mean = sum(alongs) / len(alongs)
            spread = (sum((a - mean) ** 2 for a in alongs) / len(alongs)) ** 0.5
            if mean > 0 and spread / mean <= PANO_STEP_MAX_CV:
                segs.append((start, last))

    for i, step in enumerate(steps):
        d = _sweep_direction(step)
        if d is not None and way is not None and d[:2] == way:
            alongs.append(d[2])
            continue
        close(i)
        start, way, alongs = (i, d[:2], [d[2]]) if d is not None else (None, None, [])
    close(len(steps))
    return segs


def _press_runs(groups: list[list[dict]]) -> list[list[int]]:
    """Runs of PANO_MIN_FRAMES or more consecutive one-frame groups from one camera, each taken
    within PANO_PRESS_GAP_S of the one before: the shape of a panorama shot press by press."""
    runs, cur, prev = [], [], None
    for i, group in enumerate(groups):
        f = group[0] if len(group) == 1 else None
        if f is None:
            if len(cur) >= PANO_MIN_FRAMES:
                runs.append(cur)
            cur, prev = [], None
            continue
        near = (prev is not None and f.get("capture_ts") is not None and prev.get("capture_ts") is not None
                and 0 <= f["capture_ts"] - prev["capture_ts"] <= PANO_PRESS_GAP_S
                and f.get("camera") and f.get("camera") == prev.get("camera"))
        if near:
            cur.append(i)
        else:
            if len(cur) >= PANO_MIN_FRAMES:
                runs.append(cur)
            cur = [i]
        prev = f
    if len(cur) >= PANO_MIN_FRAMES:
        runs.append(cur)
    return runs


def merge_press_sweeps(groups: list[list[dict]], measure) -> tuple[list[list[dict]], set[int]]:
    """Join the one-press groups that sweep into one group each. measure(a, b) gives phase_step for
    two frames (or None when it can't). Returns the new groups and the indices (in the new list) of
    the joined ones, which are panoramas."""
    joins: dict[int, int] = {}                 # first group index -> last group index, inclusive
    for run in _press_runs(groups):
        frames = [groups[i][0] for i in run]
        steps = [measure(a, b) for a, b in zip(frames, frames[1:])]
        for first, last in sweep_segments(steps):
            joins[run[first]] = run[last]
    out, panos, i = [], set(), 0
    while i < len(groups):
        if i in joins:
            last = joins[i]
            panos.add(len(out))
            out.append([f for g in groups[i:last + 1] for f in g])
            i = last + 1
        else:
            out.append(groups[i])
            i += 1
    return out, panos


def shooting_hours(rows: list[dict]) -> float:
    """Time spent shooting: the gaps between consecutive frames, each capped at
    SHOOTING_GAP_CAP_S. First-to-last wall-clock time was tried and dropped: idle hours gave half
    the days no squeeze at all, and folders with broken timestamps spanned thousands of hours."""
    ts = sorted(r["capture_ts"] for r in rows if r.get("capture_ts") is not None)
    return sum(min(b - a, SHOOTING_GAP_CAP_S) for a, b in zip(ts, ts[1:])) / 3600


def keep_budget(rows: list[dict], stack_count: int | None = None) -> int:
    """The soft limit: KEEP_PER_HOUR stacks per hour of shooting, at least KEEP_FLOOR, and never more
    than the day has stacks (a one-photo day asks for one, not five), so at least 1 for any day
    with photos. stack_count: the day's stacks, when the caller has built them already."""
    if stack_count is None:
        stack_count = len(build_stacks(rows))
    return min(stack_count, max(KEEP_FLOOR, math.ceil(KEEP_PER_HOUR * shooting_hours(rows))))


def build_stacks(rows: list[dict], measure=None) -> list[dict]:
    """A day's rows (any order) -> stacks in shot order. Panorama confirmation needs pixels, so
    burst candidates come back as kind 'burst' with pano_candidate=True for the caller to confirm.
    With measure(a, b) (phase_step for two frames, or None), runs of separate presses that sweep
    are joined into one stack of kind 'pano' (merge_press_sweeps)."""
    stacks = []
    groups = group_bursts(pair_frames(rows))
    panos: set[int] = set()
    if measure is not None:
        groups, panos = merge_press_sweeps(groups, measure)
    for gi, group in enumerate(groups):
        swept = gi in panos
        bracket = not swept and is_bracket(group)
        lead = lead_of(group, bracket)
        kind = "pano" if swept else "single" if len(group) == 1 else ("bracket" if bracket else "burst")
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
