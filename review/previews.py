"""Phone previews made ahead of time, so the gallery and cull grids never wait on the NAS.

The phone routes (/m/api/img/<id>?s=thumb|view) serve two JPEGs per photo from review/cache/
on the PC's own disk (never the NAS, which is only read from):
a 320 px thumbnail and a 1616 px view, both from the RAW's embedded preview (or the original for
JPEG/HEIC). Made on demand, a new thumbnail costs about 100 ms, mostly reading the file from the
NAS. This module names those files (the server uses the same names) and makes both sizes from
one read of the file.

    ./venv/bin/python review/previews.py                      # every photo, newest days first
    ./venv/bin/python review/previews.py --folder /mnt/passport/Pictures/2026/2026-10-18
    ./venv/bin/python review/previews.py --limit 200 --workers 4

Existing files are skipped, so a run can be stopped and started again. The ingest watcher runs it
for each new shoot (ops/watch_ingest.sh). Exits 1 if any file couldn't be read from the NAS, so
the watcher's log shows it; a file that reads but won't decode is counted, not fatal.
"""
import argparse
import hashlib
import os
import sqlite3
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = Path(__file__).resolve().parent / "cache"
SIZES = {"thumb": 320, "view": 1616}   # the same edges as mobile.IMG_EDGE


def preview_path(cache_dir: Path, path: str, edge: int) -> Path:
    """Where the phone preview of `path` at `edge` px lives (the server's naming)."""
    return cache_dir / f"m-{hashlib.md5(f'm:{path}:{edge}'.encode()).hexdigest()}.jpg"


def write_atomic(im, dest: Path, quality: int = 85) -> None:
    """Write through a temporary name unique to this process, so the server and a backfill
    making the same file at once can't leave a broken one."""
    tmp = dest.with_name(f"{dest.name}.{os.getpid()}.tmp")
    im.save(tmp, "JPEG", quality=quality)
    tmp.replace(dest)


def make(path: str, cache_dir: Path = CACHE, edges=tuple(SIZES.values())) -> str:
    """Make whichever of the sizes are missing for one photo. Returns made, had, unreadable
    (the NAS read failed) or undecodable."""
    sys.path.insert(0, str(ROOT))
    import photo_cull as pc
    missing = [e for e in edges if not preview_path(cache_dir, path, e).exists()]
    if not missing:
        return "had"
    try:
        src = pc.load_source(Path(path))
    except pc.LoadError as e:
        return "unreadable" if any(w in str(e) for w in ("No such file", "Input/output", "Permission", "timed out")) else "undecodable"
    except OSError:
        return "unreadable"
    for edge in sorted(missing, reverse=True):   # the bigger one first, then shrink from the source
        write_atomic(pc.to_working(src, edge), preview_path(cache_dir, path, edge))
    return "made"


def _quiet():
    os.nice(10)   # the live server and the phone come first


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", type=Path, default=ROOT / "trial_out" / "trial.db")
    ap.add_argument("--cache", type=Path, default=CACHE)
    ap.add_argument("--folder", help="only photos under this folder (a shoot the watcher just ingested)")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--limit", type=int, default=0, help="stop after this many photos (for a trial run)")
    a = ap.parse_args()
    con = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
    if a.folder:
        prefix = a.folder.rstrip("/") + "/"
        paths = [r[0] for r in con.execute("SELECT path FROM images WHERE status='ok' AND path >= ? AND path < ? "
                                           "ORDER BY path DESC", (prefix, prefix + "￿"))]
    else:
        paths = [r[0] for r in con.execute("SELECT path FROM images WHERE status='ok' ORDER BY path DESC")]
    con.close()
    todo = [p for p in paths if not all(preview_path(a.cache, p, e).exists() for e in SIZES.values())]
    done_before = len(paths) - len(todo)
    if a.limit:
        todo = todo[:a.limit]
    print(f"{len(paths)} photos, {done_before} already have both previews, making {len(todo)} "
          f"with {a.workers} workers into {a.cache}", flush=True)
    a.cache.mkdir(parents=True, exist_ok=True)
    counts = {"made": 0, "had": 0, "unreadable": 0, "undecodable": 0}
    t0 = time.monotonic()
    with ProcessPoolExecutor(max_workers=a.workers, initializer=_quiet) as ex:
        for i, result in enumerate(ex.map(make, todo, [a.cache] * len(todo), chunksize=8), 1):
            counts[result] += 1
            if i % 500 == 0 or i == len(todo):
                rate = i / max(time.monotonic() - t0, 1e-6)
                left = (len(todo) - i) / rate if rate else 0
                print(f"{i}/{len(todo)}  {rate:.1f}/s  about {left / 60:.0f} min left  {counts}", flush=True)
    print(f"done in {(time.monotonic() - t0) / 60:.1f} min: {counts}", flush=True)
    sys.exit(1 if counts["unreadable"] else 0)


if __name__ == "__main__":
    main()
