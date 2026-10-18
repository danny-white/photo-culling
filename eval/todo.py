"""What still needs labelling or grading, in batches an orchestrator can hand to subagents.

    ./venv/bin/python eval/todo.py labels [--batch 20] [--split dev|test|all]
    ./venv/bin/python eval/todo.py grades RUN [--batch 20] [--split dev|test|all]
    ./venv/bin/python eval/todo.py packet grades RUN ID

labels / grades print one JSON line per batch: {"kind", "run", "batch", "batches", "ids": [...]}.
A photo needs a label if eval/labels/<id>.json is missing. It needs a grade if
eval/grades/RUN/<id>.json is missing AND its label and eval/runs/RUN/<id>.json both exist (ids
waiting on one of those are counted on stderr, not listed). The image of an id is
eval/images/<id>.jpg.

packet prints, for one photo, what the grader reads: the image path, the reference label, and the
run's factual fields (not the judgement fields, raw text or timings), as one JSON object.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from evalcommon import EVAL, load_set, read_json  # noqa: E402

FACTUAL = ("caption", "subject", "scene", "people_count", "tags", "activity", "indoor_outdoor",
           "time_of_day", "animals", "content_type", "visible_text")


def pending_labels(entries: list, eval_dir: Path = EVAL) -> list:
    return [e["id"] for e in entries if not (eval_dir / "labels" / f"{e['id']}.json").exists()]


def pending_grades(entries: list, run: str, eval_dir: Path = EVAL) -> tuple:
    """(ids ready to grade, ids still waiting on a label or the run's output)."""
    ready, waiting = [], []
    for e in entries:
        i = e["id"]
        if (eval_dir / "grades" / run / f"{i}.json").exists():
            continue
        if (eval_dir / "labels" / f"{i}.json").exists() and (eval_dir / "runs" / run / f"{i}.json").exists():
            ready.append(i)
        else:
            waiting.append(i)
    return ready, waiting


def batches(ids: list, size: int) -> list:
    size = max(1, size)
    return [ids[i:i + size] for i in range(0, len(ids), size)]


def packet(entry_id: int, run: str, eval_dir: Path = EVAL) -> dict:
    label_p = eval_dir / "labels" / f"{entry_id}.json"
    out_p = eval_dir / "runs" / run / f"{entry_id}.json"
    for p in (label_p, out_p):
        if not p.exists():
            raise SystemExit(f"missing {p}")
    out = read_json(out_p)
    return {"id": entry_id, "run": run, "image": str(eval_dir / "images" / f"{entry_id}.jpg"),
            "label": read_json(label_p), "output": {k: out.get(k) for k in FACTUAL},
            "write_grade_to": str(eval_dir / "grades" / run / f"{entry_id}.json")}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=["labels", "grades", "packet"])
    ap.add_argument("rest", nargs="*", help="grades: RUN. packet: grades RUN ID")
    ap.add_argument("--batch", type=int, default=20)
    ap.add_argument("--split", choices=["dev", "test", "all"], default="all")
    a = ap.parse_args(argv)

    if a.what == "packet":
        if len(a.rest) != 3 or a.rest[0] != "grades" or not a.rest[2].isdigit():
            ap.error("usage: todo.py packet grades RUN ID")
        print(json.dumps(packet(int(a.rest[2]), a.rest[1]), indent=2, ensure_ascii=False))
        return
    entries = [e for e in load_set() if a.split in ("all", e["split"])]
    if a.what == "labels":
        run, ids, waiting = None, pending_labels(entries), []
    else:
        if len(a.rest) != 1:
            ap.error("usage: todo.py grades RUN")
        run = a.rest[0]
        ids, waiting = pending_grades(entries, run)
    bs = batches(ids, a.batch)
    for n, b in enumerate(bs, 1):
        print(json.dumps({"kind": a.what, "run": run, "batch": n, "batches": len(bs), "ids": b}))
    msg = f"{len(ids)} {a.what} to do in {len(bs)} batch(es)"
    if waiting:
        msg += f"; {len(waiting)} more waiting on a label or the run's output"
    print(msg, file=sys.stderr)


if __name__ == "__main__":
    main()
