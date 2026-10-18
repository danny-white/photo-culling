"""Shared paths and small helpers for the caption-eval scripts."""
import hashlib
import json
from pathlib import Path

EVAL = Path(__file__).resolve().parent
ROOT = EVAL.parent
SET_JSON = EVAL / "set.json"
SPLITS = ("dev", "test")


def read_json(path: Path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, obj) -> None:
    """Write through a temporary name, so an interrupted run never leaves half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(path)


def load_set(eval_dir: Path = EVAL) -> list:
    p = eval_dir / "set.json"
    if not p.exists():
        raise SystemExit(f"{p} not found; run eval/sample.py first")
    return read_json(p)


def prompt_sha12(text: str) -> str:
    """Same identity photo_cull.VLM_PROMPT_VERSION uses."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]
