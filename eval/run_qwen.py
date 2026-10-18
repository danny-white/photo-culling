"""Caption the eval photos exactly as production does, optionally with a different prompt.

    ./venv/bin/python eval/run_qwen.py --name baseline [--split dev|test|all] [--limit N]
                                       [--prompt-file F] [--model qwen3.5:9b]

For each photo in eval/set.json: load the ORIGINAL file (RAW preview or decode, as `photo_cull.py
run` does), make the MAX_EDGE working image, and call photo_cull.analyze_vlm (same schema, think
off, temperature 0, num_ctx and OOM ladder). Only the prompt text can differ; the default is
photo_cull.VLM_PROMPT. A --prompt-file loses one trailing newline, so a file saved by an editor
matches the string it was written from.

Writes eval/runs/NAME/<id>.json and eval/runs/NAME/meta.json. Resumable: ids already done are
skipped. A name can't be reused with a different prompt or model; pick a new name.
Sequential, and it waits while another `photo_cull.py run/analyze` (the ingest watcher) is using
the GPU. There is no inference lock file in this repo to honour.
"""
import argparse
import os
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from evalcommon import EVAL, ROOT, load_set, prompt_sha12, read_json, write_json  # noqa: E402

sys.path.insert(0, str(ROOT))
import photo_cull as pc  # noqa: E402


class Recorder:
    """Wraps the ollama client to keep the raw text of the last response (analyze_vlm returns only
    the coerced fields). Nothing about the request changes."""

    def __init__(self, client):
        self._client = client
        self.raw = ""

    def chat(self, **kw):
        resp = self._client.chat(**kw)
        self.raw = resp["message"]["content"]
        return resp


def gpu_busy_with_other_cull() -> bool:
    """True while another process is running `photo_cull.py run` or `analyze` (the ingest watcher)."""
    for p in Path("/proc").glob("[0-9]*/cmdline"):
        try:
            argv = p.read_bytes().split(b"\0")
        except OSError:
            continue
        if (len(argv) > 2 and Path(argv[0].decode(errors="replace")).name.startswith("python")
                and argv[1].endswith(b"photo_cull.py") and argv[2] in (b"run", b"analyze")
                and int(p.parent.name) != os.getpid()):
            return True
    return False


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def caption_one(client, entry: dict, prompt: str, model: str) -> dict:
    """One photo, as process_one does it (load_source, to_working, analyze_vlm). Raises on failure."""
    t0 = time.time()
    source = pc.load_source(Path(entry["path"]))
    work = pc.to_working(source, pc.MAX_EDGE)
    rec = Recorder(client)
    vlm, model_used = pc.analyze_vlm(rec, work, False, prompt=prompt, model=model)
    return {"id": entry["id"], **vlm, "raw": rec.raw, "model_used": model_used,
            "seconds": round(time.time() - t0, 2), "prompt_sha12": prompt_sha12(prompt)}


def write_meta(run_dir: Path, meta: dict, failures: dict) -> None:
    secs = []
    for p in run_dir.glob("[0-9]*.json"):
        try:
            secs.append(read_json(p)["seconds"])
        except (OSError, ValueError, KeyError):
            pass
    meta["done"] = len(secs)
    meta["median_seconds"] = round(statistics.median(secs), 2) if secs else None
    meta["failures"] = [{"id": i, "error": e} for i, e in sorted(failures.items())]
    write_json(run_dir / "meta.json", meta)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", required=True)
    ap.add_argument("--prompt-file", type=Path)
    ap.add_argument("--model", default=pc.MODEL_PRIMARY)
    ap.add_argument("--split", choices=["dev", "test", "all"], default="all")
    ap.add_argument("--limit", type=int, default=0, help="stop after this many new photos")
    ap.add_argument("--no-wait", action="store_true", help="don't wait for another photo_cull run to finish")
    a = ap.parse_args()

    prompt = pc.VLM_PROMPT
    if a.prompt_file:
        prompt = a.prompt_file.read_text(encoding="utf-8")
        if prompt.endswith("\n"):
            prompt = prompt[:-1]
    sha = prompt_sha12(prompt)
    entries = [e for e in load_set() if a.split in ("all", e["split"])]
    run_dir = EVAL / "runs" / a.name
    run_dir.mkdir(parents=True, exist_ok=True)
    meta_p = run_dir / "meta.json"
    meta = read_json(meta_p) if meta_p.exists() else {}
    if meta and (meta.get("prompt_sha12") != sha or meta.get("model") != a.model):
        sys.exit(f"run '{a.name}' was made with prompt {meta.get('prompt_sha12')} / model {meta.get('model')}; "
                 f"this is {sha} / {a.model}. Use a new --name.")
    meta.update({"name": a.name, "model": a.model, "prompt": prompt, "prompt_sha12": sha,
                 "production_prompt": prompt == pc.VLM_PROMPT, "started": meta.get("started") or now(),
                 "resumed": now()})
    pending = [e for e in entries if not (run_dir / f"{e['id']}.json").exists()]
    todo = pending[:a.limit] if a.limit else pending
    print(f"run {a.name}: model {a.model}, prompt {sha}{' (production)' if prompt == pc.VLM_PROMPT else ''}; "
          f"split '{a.split}' has {len(entries)} photos, {len(entries) - len(pending)} already done, "
          f"{len(todo)} to do now", flush=True)

    import ollama
    client = ollama.Client(timeout=pc.CALL_TIMEOUT)
    failures = {}
    try:
        for i, e in enumerate(todo, 1):
            waited = False
            while not a.no_wait and gpu_busy_with_other_cull():
                if not waited:
                    print("another photo_cull run is using the GPU; waiting", flush=True)
                    waited = True
                time.sleep(30)
            try:
                out = caption_one(client, e, prompt, a.model)
            except Exception as ex:  # noqa: BLE001 - one bad photo must not end the run
                failures[e["id"]] = f"{type(ex).__name__}: {pc._exc_text(ex)[:300]}"
                print(f"[{i}/{len(todo)}] id {e['id']}  FAILED {failures[e['id']]}", flush=True)
                continue
            write_json(run_dir / f"{e['id']}.json", out)
            print(f"[{i}/{len(todo)}] id {e['id']} {e['split']:4s} {out['seconds']:5.1f}s  {out['model_used']}  "
                  f"{out['subject'][:40]}", flush=True)
    except KeyboardInterrupt:
        print("\ninterrupted; progress saved, run again to resume", flush=True)
    finally:
        meta["finished"] = now()
        write_meta(run_dir, meta, failures)
    print(f"done: median {meta['median_seconds']}s/photo over {meta['done']} photos, "
          f"{len(failures)} failure(s) this run", flush=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
