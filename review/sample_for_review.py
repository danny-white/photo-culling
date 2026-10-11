#!/usr/bin/env python3
"""Render N random processed frames as previews + dump qwen's calls, for adversarial review.

Usage:
    ./venv/bin/python review/sample_for_review.py [N] [OUTDIR] [DB]

Defaults: N=15, OUTDIR=/tmp/rev_sample, DB=trial_out/trial.db
Writes OUTDIR/NN.jpg previews (768px) + OUTDIR/meta.txt with qwen's outputs per frame.
"""
import os
import sys
import json
import sqlite3
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import photo_cull as pc  # noqa: E402

N = int(sys.argv[1]) if len(sys.argv) > 1 else 15
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("/tmp/rev_sample")
DB = Path(sys.argv[3]) if len(sys.argv) > 3 else Path("trial_out/trial.db")
OUT.mkdir(parents=True, exist_ok=True)
for f in OUT.glob("*.jpg"):
    f.unlink()

# Optional: restrict to frames (re)processed at/after REVIEW_SINCE (ISO ts). Lets an
# audit target only the *current* prompt's outputs instead of stale old-prompt rows.
SINCE = os.environ.get("REVIEW_SINCE", "").strip()
where, params = "status='ok'", []
if SINCE:
    where += " AND processed_at >= ?"
    params.append(SINCE)
params.append(N)

conn = sqlite3.connect(str(DB))
conn.row_factory = sqlite3.Row
conn.execute("PRAGMA query_only=1")
rows = conn.execute(
    f"""SELECT rowid AS id, path, filename, scene, subject, caption, tags, issues, aesthetic,
       quality_stars, base_verdict, people_count, eyes_closed, sharpness, exposure_flag, camera
       FROM images WHERE {where} ORDER BY RANDOM() LIMIT ?""", params).fetchall()
if SINCE:
    print(f"[sample_for_review] REVIEW_SINCE={SINCE} -> {len(rows)} of N={N} frames matched")


def jl(s):
    try:
        return ", ".join(json.loads(s)) if s else ""
    except Exception:
        return s or ""


lines, made = [], 0
for i, r in enumerate(rows, 1):
    ok = True
    try:
        pc.to_working(pc.load_source(Path(r["path"])), 768).save(OUT / f"{i:02d}.jpg", "JPEG", quality=88)
        made += 1
    except Exception:  # noqa: BLE001
        ok = False
    lines += [
        f"[{i:02d}] {r['filename']} ({r['camera'] or '?'}) preview={'ok' if ok else 'FAIL'}",
        f"     qwen: {r['base_verdict']} {r['quality_stars']}* aes={r['aesthetic']}/10 "
        f"scene={r['scene']} subject={r['subject']!r}",
        f"     caption: {r['caption']}",
        f"     tags: {jl(r['tags'])}",
        f"     people={r['people_count']} eyes_closed={r['eyes_closed']} | measured: "
        f"sharp={r['sharpness']} exp={r['exposure_flag']} | qwen issues=[{jl(r['issues'])}]",
        "",
    ]
txt = "\n".join(lines)
(OUT / "meta.txt").write_text(txt)
print(txt)
print(f"rendered {made}/{len(rows)} previews to {OUT}/  (meta.txt written)")
