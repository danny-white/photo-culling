"""Score graded caption runs (the "Metrics" section of RUBRIC.md).

    ./venv/bin/python eval/score.py [RUN ...]     # default: every directory under eval/grades/

Prints a table per split (dev, test) and writes eval/report.json. Two runs also get a paired
comparison. Intervals are 95% percentile bootstrap over photos, 2,000 resamples, seeded.

Each run's photos are those in eval/set.json with a valid grade file. Low-confidence photos
(the label says confidence "low") are left out of every metric, the primary one included, and
counted on their own line with their primary rate. Malformed grade files (missing or wrong-typed
fields, an unknown error type, an id not in the set, no label) are listed and left out, not fatal.

Primary: share of photos with at least one caption error of type hallucination, misidentification,
wrong_count or over_assertion. Lower is better, so a paired difference below zero means the
second run is better.

Audits in eval/audits/ are summarized per run. --drop-disputed excludes a photo from every
metric when its reference was ruled wrong or that run's grade was disputed. Paired comparisons
use the intersection of the remaining photos, so a dispute of either run excludes the pair.
"""
import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from evalcommon import EVAL, SPLITS, load_set, read_json, write_json  # noqa: E402

BOOT_N = 2000
BOOT_SEED = 1
PRIMARY_TYPES = ("hallucination", "misidentification", "wrong_count", "over_assertion")
ERROR_TYPES = PRIMARY_TYPES + ("wrong_setting", "missed_subject")
ACTIVITY = ("ok", "wrong", "missing", "n/a")
VISIBLE_TEXT = ("ok", "invented", "missed", "n/a")
BOOLS = ("people_count_ok", "indoor_outdoor_ok", "time_of_day_ok", "scene_ok", "animals_ok")


def _int(x) -> bool:
    return isinstance(x, int) and not isinstance(x, bool)


def validate_grade(g, entry_id: int) -> list:
    """Problems with one grade file's content against the rubric (empty list = fine)."""
    if not isinstance(g, dict):
        return ["not a JSON object"]
    p = []
    if g.get("id") != entry_id:
        p.append(f"id is {g.get('id')!r}, file is for {entry_id}")
    errs = g.get("caption_errors")
    if not isinstance(errs, list):
        p.append("caption_errors is not a list")
    else:
        for k, e in enumerate(errs):
            if not isinstance(e, dict) or e.get("type") not in ERROR_TYPES:
                p.append(f"caption_errors[{k}].type is {e.get('type') if isinstance(e, dict) else e!r}, "
                         f"want one of {', '.join(ERROR_TYPES)}")
    tt, tw = g.get("tags_total"), g.get("tags_wrong")
    if not _int(tt) or tt < 0:
        p.append("tags_total is not a non-negative integer")
    if not _int(tw) or tw < 0:
        p.append("tags_wrong is not a non-negative integer")
    if _int(tt) and _int(tw) and tw > tt:
        p.append(f"tags_wrong {tw} exceeds tags_total {tt}")
    for b in BOOLS:
        if not isinstance(g.get(b), bool):
            p.append(f"{b} is not true/false")
    if g.get("activity") not in ACTIVITY:
        p.append(f"activity is {g.get('activity')!r}, want one of {', '.join(ACTIVITY)}")
    if g.get("visible_text") not in VISIBLE_TEXT:
        p.append(f"visible_text is {g.get('visible_text')!r}, want one of {', '.join(VISIBLE_TEXT)}")
    mh, mt = g.get("must_mention_hit"), g.get("must_mention_total")
    if not _int(mh) or mh < 0:
        p.append("must_mention_hit is not a non-negative integer")
    if not _int(mt) or mt < 0:
        p.append("must_mention_total is not a non-negative integer")
    if _int(mh) and _int(mt) and mh > mt:
        p.append(f"must_mention_hit {mh} exceeds must_mention_total {mt}")
    return p


def photo_row(g: dict) -> dict:
    """One valid grade as (numerator, denominator) pairs; a metric is sum(num) / sum(den) over photos."""
    types = {e["type"] for e in g["caption_errors"]}
    row = {"primary": (float(bool(types & set(PRIMARY_TYPES))), 1.0)}
    for t in ERROR_TYPES:
        row[f"err:{t}"] = (float(t in types), 1.0)
    row["tag_precision"] = (float(g["tags_total"] - g["tags_wrong"]), float(g["tags_total"]))
    row["people_count_exact"] = (float(g["people_count_ok"]), 1.0)
    row["activity_ok"] = (float(g["activity"] == "ok"), float(g["activity"] != "n/a"))
    for b in BOOLS[1:]:
        row[b.replace("_ok", "") + "_acc"] = (float(g[b]), 1.0)
    row["visible_text_invented"] = (float(g["visible_text"] == "invented"), 1.0)
    row["visible_text_missed"] = (float(g["visible_text"] == "missed"), 1.0)
    row["must_mention_recall"] = (float(g["must_mention_hit"]), float(g["must_mention_total"]))
    return row


METRICS = [("primary", "ANY of halluc/misid/count/over-assert"),
           *[(f"err:{t}", f"  {t}") for t in ERROR_TYPES],
           ("tag_precision", "tag precision"), ("people_count_exact", "people_count exact"),
           ("activity_ok", "activity ok"), ("indoor_outdoor_acc", "indoor_outdoor"),
           ("time_of_day_acc", "time_of_day"), ("scene_acc", "scene"), ("animals_acc", "animals"),
           ("visible_text_invented", "visible text invented"), ("visible_text_missed", "visible text missed"),
           ("must_mention_recall", "must_mention recall")]


def bootstrap_idx(n: int, seed: int = BOOT_SEED, resamples: int = BOOT_N) -> np.ndarray:
    return np.random.default_rng(seed).integers(0, n, size=(resamples, n))


def ratio_ci(num: np.ndarray, den: np.ndarray, idx: np.ndarray) -> dict:
    """Value and 95% interval of sum(num)/sum(den). Undefined (None) if no photo has a denominator."""
    if den.sum() == 0:
        return {"value": None, "lo": None, "hi": None, "n": int((den > 0).sum())}
    n_s, d_s = num[idx].sum(axis=1), den[idx].sum(axis=1)
    ok = d_s > 0
    r = n_s[ok] / d_s[ok]
    return {"value": float(num.sum() / den.sum()), "lo": float(np.percentile(r, 2.5)),
            "hi": float(np.percentile(r, 97.5)), "n": int((den > 0).sum())}


def load_audits(entries: list, eval_dir: Path = EVAL) -> dict:
    """Read saved human judgements for this set; report unusable files without guessing."""
    audits = {}
    for e in entries:
        path = eval_dir / "audits" / f"{e['id']}.json"
        if not path.exists():
            continue
        try:
            audit = read_json(path)
            if (not isinstance(audit, dict) or audit.get("reference") not in ("right", "wrong", "unsure")
                    or not isinstance(audit.get("grades", {}), dict)
                    or any(v not in ("agree", "disagree") for v in audit.get("grades", {}).values())):
                raise ValueError("invalid reference or grade judgement")
        except (OSError, ValueError) as ex:
            print(f"MALFORMED AUDIT {path}: {ex}", file=sys.stderr)
            continue
        audits[e["id"]] = audit
    return audits


def load_grades(run: str, entries: list, eval_dir: Path = EVAL, *,
                audits=None, drop_disputed: bool = False) -> dict:
    """Split buckets of metric rows, low-confidence flags, malformed files and ungraded counts.

    Audit totals count valid graded photos before exclusions. Dropped photos remain graded.
    """
    by_id = {e["id"]: e for e in entries}
    out = {s: {"rows": {}, "low": {}, "malformed": [], "ungraded": 0, "set": 0} for s in SPLITS}
    out["unmatched"] = []
    if audits is None:
        audits = load_audits(entries, eval_dir)
    if audits:
        out["audit"] = {"audited": 0, "reference_wrong": 0, "grades_disputed": 0}
    if drop_disputed:
        for s in SPLITS:
            out[s]["excluded_disputed"] = 0
    for e in entries:
        out[e["split"]]["set"] += 1
    gdir = eval_dir / "grades" / run
    for f in sorted(gdir.glob("*.json")) if gdir.is_dir() else []:
        if not f.stem.isdigit() or int(f.stem) not in by_id:
            out["unmatched"].append({"file": str(f), "problems": ["id is not in set.json"]})
            continue
        i = int(f.stem)
        bucket = out[by_id[i]["split"]]
        try:
            g = read_json(f)
        except (OSError, ValueError) as ex:
            bucket["malformed"].append({"file": str(f), "problems": [f"unreadable JSON: {ex}"]})
            continue
        probs = validate_grade(g, i)
        label_p = eval_dir / "labels" / f"{i}.json"
        conf = None
        try:
            conf = read_json(label_p).get("confidence") if label_p.exists() else None
        except (OSError, ValueError, AttributeError):
            pass
        if conf is None:
            probs.append("no readable label (confidence unknown)")
        if probs:
            bucket["malformed"].append({"file": str(f), "problems": probs})
            continue
        audit = audits.get(i)
        if audit is not None:
            reference_wrong = audit["reference"] == "wrong"
            grade_disputed = audit.get("grades", {}).get(run) == "disagree"
            out["audit"]["audited"] += 1
            out["audit"]["reference_wrong"] += int(reference_wrong)
            out["audit"]["grades_disputed"] += int(grade_disputed)
            if drop_disputed and (reference_wrong or grade_disputed):
                bucket["excluded_disputed"] += 1
                continue
        row = photo_row(g)
        if conf == "low":
            bucket["low"][i] = row["primary"][0]
        else:
            bucket["rows"][i] = row
    for e in entries:
        if not (gdir / f"{e['id']}.json").exists():
            out[e["split"]]["ungraded"] += 1
    return out


def score_run(data: dict) -> dict:
    res = {}
    for s in SPLITS:
        d = data[s]
        ids = sorted(d["rows"])
        entry = {"set": d["set"], "graded": len(ids) + len(d["low"]), "scored": len(ids),
                 "low_confidence": {"n": len(d["low"]),
                                    "primary_rate": (sum(d["low"].values()) / len(d["low"])) if d["low"] else None},
                 "ungraded": d["ungraded"], "malformed": d["malformed"], "metrics": {}}
        if "excluded_disputed" in d:
            entry["excluded_disputed"] = d["excluded_disputed"]
            entry["graded"] += d["excluded_disputed"]
        if ids:
            idx = bootstrap_idx(len(ids))
            for key, _ in METRICS:
                num = np.array([d["rows"][i][key][0] for i in ids])
                den = np.array([d["rows"][i][key][1] for i in ids])
                entry["metrics"][key] = ratio_ci(num, den, idx)
        res[s] = entry
    res["unmatched"] = data["unmatched"]
    if "audit" in data:
        res["audit"] = data["audit"]
    return res


def compare(a: dict, b: dict) -> dict:
    """Paired primary-metric comparison of run b against run a, on photos scored in both."""
    out = {}
    for s in SPLITS:
        common = sorted(set(a[s]["rows"]) & set(b[s]["rows"]))
        if not common:
            out[s] = {"n": 0}
            continue
        ea = np.array([a[s]["rows"][i]["primary"][0] for i in common])
        eb = np.array([b[s]["rows"][i]["primary"][0] for i in common])
        diff = eb - ea
        idx = bootstrap_idx(len(common))
        boots = diff[idx].mean(axis=1)
        out[s] = {"n": len(common), "primary_a": float(ea.mean()), "primary_b": float(eb.mean()),
                  "diff_b_minus_a": float(diff.mean()),
                  "lo": float(np.percentile(boots, 2.5)), "hi": float(np.percentile(boots, 97.5)),
                  "fixed": int(((ea == 1) & (eb == 0)).sum()), "broken": int(((ea == 0) & (eb == 1)).sum()),
                  "both_error": int(((ea == 1) & (eb == 1)).sum()), "both_clean": int(((ea == 0) & (eb == 0)).sum()),
                  "fixed_ids": [i for i, x, y in zip(common, ea, eb) if x == 1 and y == 0],
                  "broken_ids": [i for i, x, y in zip(common, ea, eb) if x == 0 and y == 1]}
    return out


def _fmt(m) -> str:
    if not m or m["value"] is None:
        return "-"
    return f"{100 * m['value']:5.1f}% [{100 * m['lo']:4.1f}, {100 * m['hi']:5.1f}]"


def render(results: dict, comparison) -> str:
    runs = list(results)
    lines = []
    w = max(len(r) for r in runs) + 2
    col = max(24, w)
    for r in runs:
        if "audit" in results[r]:
            audit = results[r]["audit"]
            lines.append(f"audit [{r}]: audited {audit['audited']}, reference ruled wrong "
                         f"{audit['reference_wrong']}, grades disputed {audit['grades_disputed']}")
    for s in SPLITS:
        lines += [f"== {s} " + "=" * 60]
        lines.append(f"{'':40s}" + "".join(f"{r:>{col}s}" for r in runs))
        for label, key in (("photos in set", "set"), ("graded", "graded"), ("scored (not low-confidence)", "scored"),
                           ("not yet graded", "ungraded")):
            lines.append(f"{label:40s}" + "".join(f"{results[r][s][key]:>{col}d}" for r in runs))
        if any("excluded_disputed" in results[r][s] for r in runs):
            lines.append(f"{'excluded by audit, n':40s}" + "".join(
                f"{results[r][s].get('excluded_disputed', 0):>{col}d}" for r in runs))
        low = [results[r][s]["low_confidence"] for r in runs]
        lines.append(f"{'low-confidence (excluded), n':40s}" + "".join(f"{x['n']:>{col}d}" for x in low))
        lines.append(f"{'  their primary error rate':40s}" + "".join(
            f"{('-' if x['primary_rate'] is None else format(100 * x['primary_rate'], '.1f') + '%'):>{col}s}" for x in low))
        lines.append(f"{'malformed grade files':40s}" + "".join(f"{len(results[r][s]['malformed']):>{col}d}" for r in runs))
        lines.append("")
        for key, label in METRICS:
            lines.append(f"{label:40s}" + "".join(f"{_fmt(results[r][s]['metrics'].get(key)):>{col}s}" for r in runs))
        lines.append("")
        for r in runs:
            for m in results[r][s]["malformed"]:
                lines.append(f"MALFORMED [{r}] {m['file']}: " + "; ".join(m["problems"]))
        if comparison:
            c = comparison[s]
            a, b = runs[0], runs[1]
            if c["n"]:
                lines.append(f"paired {b} vs {a} on {c['n']} photos scored in both: primary "
                             f"{100 * c['primary_a']:.1f}% -> {100 * c['primary_b']:.1f}%, "
                             f"difference {100 * c['diff_b_minus_a']:+.1f} pts "
                             f"[{100 * c['lo']:+.1f}, {100 * c['hi']:+.1f}] (negative = {b} better)")
                lines.append(f"  fixed {c['fixed']}, broken {c['broken']}, both wrong {c['both_error']}, "
                             f"both clean {c['both_clean']}")
            else:
                lines.append(f"paired {b} vs {a}: no photos scored in both")
            lines.append("")
    for r in runs:
        for m in results[r]["unmatched"]:
            lines.append(f"MALFORMED [{r}] {m['file']}: " + "; ".join(m["problems"]))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="*", metavar="RUN")
    ap.add_argument("--drop-disputed", action="store_true",
                    help="Exclude wrong references and disputed grades from every metric.")
    a = ap.parse_args(argv)
    entries = load_set(EVAL)
    runs = a.runs or sorted(p.name for p in (EVAL / "grades").glob("*") if p.is_dir())
    if not runs:
        sys.exit("no runs given and eval/grades/ is empty")
    audits = load_audits(entries, EVAL)
    data = {r: load_grades(r, entries, EVAL, audits=audits, drop_disputed=a.drop_disputed) for r in runs}
    results = {r: score_run(data[r]) for r in runs}
    comparison = compare(data[runs[0]], data[runs[1]]) if len(runs) == 2 else None
    print(render(results, comparison))
    write_json(EVAL / "report.json", {"runs": results, "paired": (
        {"a": runs[0], "b": runs[1], **comparison} if comparison else None),
        "bootstrap": {"resamples": BOOT_N, "seed": BOOT_SEED, "interval": "95% percentile"}})
    print(f"wrote {EVAL / 'report.json'}")


if __name__ == "__main__":
    main()
