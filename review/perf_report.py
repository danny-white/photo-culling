"""Summarise the review server's timing log (trial_out/perf.jsonl, written by review/perf.py).

    ./venv/bin/python review/perf_report.py              # the last 24 hours
    ./venv/bin/python review/perf_report.py --hours 168  # the last week
    ./venv/bin/python review/perf_report.py --route img  # routes containing "img"

Three tables:
  server  per route: requests, median / 95th percentile / slowest handler time, median time
          until the body was sent, cache hits, and the median of each timed stage
  phone   per measurement the phone pages sent: fetches grouped by kind, and the moments you
          feel (card_photo, viewer_photo, day_open, ...); for fetches, the median time waiting
          in the browser's queue, to the first byte (server plus round trip), and downloading,
          and how many the browser answered from its own cache
  slowest the ten slowest server requests, with their stages
"""
import argparse
import json
import re
import statistics
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

DEFAULT_LOG = Path(__file__).resolve().parent.parent / "trial_out" / "perf.jsonl"


def pct(values, q):
    if not values:
        return None
    v = sorted(values)
    return v[min(len(v) - 1, int(round(q * (len(v) - 1))))]


def fmt(ms):
    if ms is None:
        return "-"
    return f"{ms / 1000:.2f}s" if ms >= 1000 else f"{ms:.0f}ms"


def load(paths, since):
    for p in paths:
        if not p.exists():
            continue
        for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                line = json.loads(raw)
                if datetime.fromisoformat(line["ts"]) >= since:
                    yield line
            except (ValueError, KeyError):
                continue


def fetch_kind(name):
    """/m/api/img/123?s=thumb -> img thumb; /m/api/day/2026/2026-10-01 -> day"""
    m = re.match(r"/m/api/([a-z-]+)(?:/([a-z-]+))?", name or "")
    if not m:
        return name or "?"
    kind = m[1] + ("/" + m[2] if m[2] and m[1] in ("gallery",) else "")
    s = re.search(r"[?&]s=([a-z]+)", name)
    return kind + (" " + s[1] if s else "")


def table(rows, header):
    widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
    out = ["  ".join(str(h).ljust(w) for h, w in zip(header, widths))]
    out += ["  ".join(str(c).ljust(w) for c, w in zip(r, widths)) for r in rows]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", type=Path, default=DEFAULT_LOG)
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--route", default="", help="only server routes / phone kinds containing this text")
    a = ap.parse_args()
    since = datetime.now() - timedelta(hours=a.hours)
    paths = [a.log.with_name(a.log.name + f".{i}") for i in (3, 2, 1)] + [a.log]
    lines = list(load(paths, since))
    server = [x for x in lines if x.get("kind") == "server" and a.route in (x.get("route") or "")]
    client = [x for x in lines if x.get("kind") == "client"]
    print(f"{len(server)} server requests and {len(client)} phone measurements since {since:%Y-%m-%d %H:%M}\n")

    by_route = defaultdict(list)
    for x in server:
        by_route[f'{x["method"]} {x["route"]}'].append(x)
    rows = []
    for route, xs in sorted(by_route.items(), key=lambda kv: -sum(x["ms"] for x in kv[1])):
        ms = [x["ms"] for x in xs]
        sent = [x["send_ms"] for x in xs if x.get("send_ms") is not None]
        caches = [x["attrs"].get("cache") or x["attrs"].get("decode_cache") for x in xs]
        caches = [c for c in caches if c]
        stages = defaultdict(list)
        for x in xs:
            for k, v in x.get("stages", {}).items():
                stages[k].append(v)
        st = " ".join(f"{k}={fmt(statistics.median(v))}×{len(v)}" for k, v in
                      sorted(stages.items(), key=lambda kv: -sum(kv[1]))[:4])
        errors = sum(1 for x in xs if x["status"] >= 500)
        rows.append([route, len(xs), fmt(pct(ms, .5)), fmt(pct(ms, .95)), fmt(max(ms)), fmt(pct(sent, .5)),
                     f"{100 * caches.count('hit') / len(caches):.0f}%" if caches else "-", errors or "", st])
    if rows:
        print("SERVER (sorted by total time spent)")
        print(table(rows, ["route", "n", "p50", "p95", "max", "sent p50", "cache hit", "5xx", "stages (median × count)"]))
        print()

    groups = defaultdict(list)
    for x in client:
        key = "fetch " + fetch_kind(x.get("name")) if x["type"] == "fetch" else x["type"]
        if a.route in key:
            groups[key].append(x)
    rows = []
    for key, xs in sorted(groups.items(), key=lambda kv: (not kv[0].startswith("fetch"), kv[0])):
        ms = [x["ms"] for x in xs]
        live = [x for x in xs if x.get("detail") == "network"]
        split = lambda k: fmt(pct([x[k] for x in live if k in x], .5)) if any(k in x for x in live) else "-"
        srv = fmt(pct([x["server_ms"] for x in live if "server_ms" in x], .5)) if any("server_ms" in x for x in live) else "-"
        cached = sum(1 for x in xs if x.get("detail") == "browser-cache")
        waited = sum(1 for x in xs if x.get("detail") == "waited")
        note = (f"{cached} from browser cache" if key.startswith("fetch") and cached else
                f"{waited} waited, {len(xs) - waited} prefetched" if key == "card_photo" else "")
        rows.append([key, len(xs), fmt(pct(ms, .5)), fmt(pct(ms, .95)), fmt(max(ms)),
                     split("wait_ms"), split("ttfb_ms"), split("dl_ms"), srv, note])
    if rows:
        print("PHONE (as measured on the device; the last four columns are medians for fetches)")
        print(table(rows, ["measurement", "n", "p50", "p95", "max", "waiting", "first byte", "download", "server", ""]))
        print()

    slow = sorted(server, key=lambda x: -x["ms"])[:10]
    if slow:
        print("SLOWEST SERVER REQUESTS")
        print(table([[x["ts"][5:19].replace("T", " "), fmt(x["ms"]), x["status"], x["path"][:60],
                      " ".join(f"{k}={fmt(v)}" for k, v in x.get("stages", {}).items()),
                      " ".join(f"{k}={v}" for k, v in x.get("attrs", {}).items())] for x in slow],
                    ["when", "ms", "status", "path", "stages", "facts"]))


if __name__ == "__main__":
    main()
