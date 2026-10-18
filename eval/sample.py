"""Draw the caption-eval photos from trial_out/trial.db: eval/set.json and eval/images/<id>.jpg.

    ./venv/bin/python eval/sample.py [--seed 1] [--per-split 100] [--force]

Rules: one photo per burst; a RAW and a same-name JPEG count once; a shoot day (the photo's parent
folder) goes wholly to dev or wholly to test, by a hash of the folder name, so re-runs agree.
Each split is then filled to --per-split, stratified by camera era (each at least 8, the rest in
proportion to the library), about 45% with people, spread over scenes, at most 3 photos a day (more only for an era shot on too few days to reach its minimum).
Same seed and same database give the same set. trial.db is opened read-only.

The image is the 1616 px phone preview from review/cache (rendered from the original if missing).
set.json refuses to be overwritten without --force, since labels and grades are keyed by its ids.
Ids are trial.db rowids; the path is the stable key if the table is ever vacuumed.
"""
import argparse
import hashlib
import json
import math
import random
import shutil
import sqlite3
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from evalcommon import EVAL, ROOT, SET_JSON, write_json  # noqa: E402

VIEW_EDGE = 1616
DAY_CAP = 3
MIN_ERA = 8
PEOPLE_TARGET = 0.45
MIN_SCENE_SHARE = 0.005   # scenes rarer than this in the library are balanced as "other"
ERAS = ("Sony A7R III/IIIA", "Canon T5i", "Nikon D40/D60", "Canon R6", "iPhone/other")
RAW_EXT = {".arw", ".cr2", ".cr3", ".nef", ".raf", ".rw2", ".dng", ".orf", ".pef", ".srw"}
PROD_FIELDS = ("caption", "subject", "scene", "people_count", "tags", "activity", "indoor_outdoor",
               "time_of_day", "animals", "content_type", "visible_text", "prompt_version", "model_used")
SQL = ("SELECT rowid AS id, path, camera, burst_id, " + ", ".join(PROD_FIELDS) +
       " FROM images WHERE status='ok' AND (content_type='photo' OR content_type IS NULL) "
       "AND caption IS NOT NULL AND TRIM(caption) != '' ORDER BY rowid")


def era_of(camera) -> str:
    c = (camera or "").upper()
    if "ILCE-7RM3" in c:
        return ERAS[0]
    if "T5I" in c:
        return ERAS[1]
    if "NIKON" in c and ("D40" in c or "D60" in c):
        return ERAS[2]
    if "EOS R6" in c:
        return ERAS[3]
    return ERAS[4]


def day_of(path: str) -> str:
    return Path(path).parent.name


def split_of(day: str) -> str:
    """Stable for a folder name, whatever the seed or the database."""
    return "dev" if hashlib.sha1(day.encode()).digest()[0] % 2 == 0 else "test"


def load_rows(db: Path) -> list:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in con.execute(SQL)]
    finally:
        con.close()


def dedupe_pairs(rows: list) -> list:
    """Keep one of a RAW and its same-name JPEG (same folder, same stem): the non-RAW if there is one."""
    best = {}
    for r in rows:
        p = Path(r["path"])
        key = (str(p.parent), p.stem.lower())
        rank = (p.suffix.lower() in RAW_EXT, r["path"])
        if key not in best or rank < best[key][0]:
            best[key] = (rank, r)
    return sorted((v[1] for v in best.values()), key=lambda r: r["id"])


def one_per_burst(rows: list, seed: int) -> list:
    """A burst's representative is the member with the smallest seeded hash; no burst_id is its own burst."""
    best = {}
    for r in rows:
        key = ("b", r["burst_id"]) if r.get("burst_id") is not None else ("p", r["id"])
        h = hashlib.sha1(f"{seed}:{r['path']}".encode()).hexdigest()
        if key not in best or h < best[key][0]:
            best[key] = (h, r)
    return sorted((v[1] for v in best.values()), key=lambda r: r["id"])


def allocate(weights: dict, n: int, min_each: int = MIN_ERA) -> dict:
    """Split n across the keys of weights in proportion, none below min_each (largest remainder)."""
    quota, free = {}, set(weights)
    while True:
        left = n - sum(quota.values())
        total = sum(weights[k] for k in free) or 1
        low = [k for k in free if left * weights[k] / total < min_each]
        if not low:
            break
        for k in low:
            quota[k] = min_each
            free.discard(k)
    left = n - sum(quota.values())
    total = sum(weights[k] for k in free) or 1
    exact = {k: left * weights[k] / total for k in free}
    for k in free:
        quota[k] = int(exact[k])
    short = n - sum(quota.values())
    for k in sorted(free, key=lambda k: (exact[k] - int(exact[k]), weights[k]), reverse=True)[:max(short, 0)]:
        quota[k] += 1
    return quota


def select(rows: list, split: str, seed: int, n: int, weights: dict, scene_bucket,
           accept=lambda r: True, people_target: float = PEOPLE_TARGET, day_cap: int = DAY_CAP,
           min_era: int = MIN_ERA) -> list:
    """Choose up to n of `rows` (already one per burst, all from this split's days)."""
    rng = random.Random(f"{seed}:{split}")
    pools = {e: [] for e in weights}
    for r in sorted(rows, key=lambda r: r["id"]):
        pools[era_of(r["camera"])].append(r)
    for p in pools.values():
        rng.shuffle(p)
    scene_pool = Counter(scene_bucket(r["scene"]) for r in rows)
    quota = allocate(weights, n, min_era)
    # An era shot on too few days to reach its minimum under the day cap gets a higher cap (Canon R6 is 3 days).
    caps = {e: day_cap if day_cap * len({day_of(r["path"]) for r in pools[e]}) >= quota[e] else quota[e]
            for e in weights}
    picked = Counter()
    active = [e for e in weights if pools[e]]
    for e in weights:
        if e not in active and quota[e]:     # an era with no photos in this split: its share moves on
            _redistribute(quota, quota[e], active, weights)
            quota[e] = 0
    chosen, day_n, scene_n, people_n = [], Counter(), Counter(), 0
    while len(chosen) < n and active:
        era = max((e for e in active if quota[e] - picked[e] > 0),
                  key=lambda e: (quota[e] - picked[e], weights[e]), default=None)
        if era is None:
            break
        want_people = people_n < people_target * (len(chosen) + 1)
        pool = [r for r in pools[era] if day_n[day_of(r["path"])] < caps[era]]
        side = [r for r in pool if (r["people_count"] or 0) > 0] if want_people else \
               [r for r in pool if not (r["people_count"] or 0) > 0]
        pool = side or pool
        if not pool:
            active.remove(era)
            _redistribute(quota, quota[era] - picked[era], active, weights)
            quota[era] = picked[era]
            continue
        best = min(pool, key=lambda r: (scene_n[scene_bucket(r["scene"])] / math.sqrt(scene_pool[scene_bucket(r["scene"])]),
                                        day_n[day_of(r["path"])]))
        pools[era].remove(best)
        if not accept(best):
            continue
        chosen.append(best)
        picked[era] += 1
        day_n[day_of(best["path"])] += 1
        scene_n[scene_bucket(best["scene"])] += 1
        people_n += (best["people_count"] or 0) > 0
    return chosen


def _redistribute(quota: dict, extra: int, active: list, weights: dict) -> None:
    if extra <= 0 or not active:
        return
    add = allocate({e: weights[e] for e in active}, extra, 0)
    for e, v in add.items():
        quota[e] += v


def make_scene_bucket(rows: list):
    counts = Counter((r["scene"] or "").strip().lower() for r in rows)
    keep = {s for s, c in counts.items() if s and c / max(len(rows), 1) >= MIN_SCENE_SHARE}
    return lambda s: (s or "").strip().lower() if (s or "").strip().lower() in keep else "other"


def _json_list(v):
    try:
        x = json.loads(v) if isinstance(v, str) else v
    except json.JSONDecodeError:
        return []
    return x if isinstance(x, list) else []


def set_entry(r: dict, split: str) -> dict:
    prod = {k: r[k] for k in PROD_FIELDS}
    prod["tags"] = _json_list(r["tags"])
    prod["animals"] = _json_list(r["animals"])
    return {"id": r["id"], "split": split, "path": r["path"], "day": day_of(r["path"]),
            "camera": r["camera"], "scene": r["scene"], "people_count": r["people_count"], "prod": prod}


def prepare_image(path: str, dest: Path, cache_dir: Path) -> bool:
    """Put the 1616 px preview of `path` at dest: copy the cached one, else render it from the original."""
    if dest.exists() and dest.stat().st_size:
        return True
    sys.path.insert(0, str(ROOT / "review"))
    sys.path.insert(0, str(ROOT))
    import previews
    src = previews.preview_path(cache_dir, path, VIEW_EDGE)
    if not src.exists():
        try:
            previews.make(path, cache_dir, edges=(VIEW_EDGE,))
        except Exception as e:  # noqa: BLE001
            print(f"  skip {path}: {e}", file=sys.stderr)
            return False
    if not src.exists():
        print(f"  skip {path}: no preview could be made", file=sys.stderr)
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".tmp")
    shutil.copyfile(src, tmp)
    tmp.replace(dest)
    return True


def composition(entries: list) -> dict:
    out = {}
    for s in ("dev", "test"):
        es = [e for e in entries if e["split"] == s]
        out[s] = {"n": len(es), "days": len({e["day"] for e in es}),
                  "people>0": sum((e["people_count"] or 0) > 0 for e in es),
                  "by_era": dict(Counter(era_of(e["camera"]) for e in es)),
                  "by_scene": dict(Counter(e["scene"] for e in es).most_common())}
    return out


def build(rows: list, seed: int, per_split: int, accept) -> list:
    """The whole draw, from the raw query rows. accept(split, row) -> bool vets a pick (the image exists)."""
    rows = one_per_burst(dedupe_pairs(rows), seed)
    era_n = Counter(era_of(r["camera"]) for r in rows)
    weights = {e: era_n[e] / len(rows) or 1e-9 for e in ERAS}
    bucket = make_scene_bucket(rows)
    entries = []
    for split in ("dev", "test"):
        mine = [r for r in rows if split_of(day_of(r["path"])) == split]
        got = select(mine, split, seed, per_split, weights, bucket, accept=lambda r, s=split: accept(s, r))
        entries += [set_entry(r, split) for r in sorted(got, key=lambda r: r["id"])]
    return entries


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", type=Path, default=ROOT / "trial_out" / "trial.db")
    ap.add_argument("--cache", type=Path, default=ROOT / "review" / "cache")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--per-split", type=int, default=100)
    ap.add_argument("--force", action="store_true", help="overwrite an existing set.json")
    a = ap.parse_args()
    if SET_JSON.exists() and not a.force:
        sys.exit(f"{SET_JSON} exists; labels and grades are keyed by its ids. Use --force to redraw.")
    rows = load_rows(a.db)
    print(f"{len(rows)} eligible rows in {a.db}", flush=True)
    img_dir = EVAL / "images"
    entries = build(rows, a.seed, a.per_split,
                    lambda split, r: prepare_image(r["path"], img_dir / f"{r['id']}.jpg", a.cache))
    write_json(SET_JSON, entries)
    stray = sorted(p.name for p in img_dir.glob("*.jpg") if int(p.stem) not in {e["id"] for e in entries}) \
        if img_dir.exists() else []
    if stray:
        print(f"note: {len(stray)} images in {img_dir} are not in the new set (left alone)")
    comp = composition(entries)
    for s, c in comp.items():
        print(f"\n{s}: {c['n']} photos on {c['days']} days, {c['people>0']} with people")
        print("  era  ", c["by_era"])
        print("  scene", c["by_scene"])
    print(f"\nwrote {SET_JSON} ({len(entries)} photos)")


if __name__ == "__main__":
    main()
