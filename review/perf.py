"""Request timing for the review server: one JSON line per request, and a Server-Timing header.

Each line in the log (trial_out/perf.jsonl by default, rotated at 20 MB, three kept) records:
  ts       when the request started (ISO, local time)
  route    the Flask rule, e.g. /m/api/img/<int:rowid>, so requests group by endpoint
  path     the actual path and query
  status   HTTP status; error is the exception class when a handler raised
  ms       time in the handler, until the response was ready
  send_ms  time until the last byte was handed to the socket: ms plus sending the body, so
           a big picture over Tailscale shows up here rather than in ms
  bytes    response size, when known
  client   the caller's address (100.91.65.36 is the phone on the tailnet)
  stages   {name: ms} for the parts a handler timed with stage(), e.g. decode or encode
  attrs    facts about the request set with note(), e.g. cache=hit or miss

The phone pages send their own measurements to /m/api/perf, which logs them through
client_lines() with kind "client". review/perf_report.py summarises the file.

stage() and note() do nothing outside a request, so modules like search.py can call them
from tests and scripts as well.
"""
import json
import logging
import logging.handlers
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

from flask import g, has_request_context, request
from werkzeug.wsgi import ClosingIterator

LOG = logging.getLogger("perf")
LOG.propagate = False
SKIP_PREFIXES = ("/m/api/perf",)   # the phone's own reports; logged as client lines instead


def install(app, path: Path, max_bytes: int = 20 * 1024 * 1024, keep: int = 3) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not any(isinstance(h, logging.handlers.RotatingFileHandler) and Path(h.baseFilename) == path.resolve()
               for h in LOG.handlers):
        handler = logging.handlers.RotatingFileHandler(path, maxBytes=max_bytes, backupCount=keep, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(message)s"))
        LOG.addHandler(handler)
    LOG.setLevel(logging.INFO)

    @app.before_request
    def _start():
        g.perf = {"t0": time.perf_counter(), "wall": time.time(), "stages": {}, "attrs": {}, "logged": False}

    @app.after_request
    def _finish(resp):
        p = g.get("perf")
        if p is None or request.path.startswith(SKIP_PREFIXES):
            return resp
        ms = (time.perf_counter() - p["t0"]) * 1000
        parts = [f"total;dur={ms:.1f}"]
        parts += [f"{name};dur={v:.1f}" for name, v in p["stages"].items()]
        parts += [f'{k};desc="{v}"' for k, v in p["attrs"].items() if isinstance(v, str) and '"' not in v]
        resp.headers["Server-Timing"] = ", ".join(parts)
        line = _line(p, resp.status_code, ms, resp.content_length)
        p["logged"] = True

        def sent():   # after the body went out; teardown has run by now, so a handler's error is known
            out = dict(line, send_ms=round((time.perf_counter() - p["t0"]) * 1000, 1))
            if p.get("error"):
                out["error"] = p["error"]
            _write(out)
        if resp.direct_passthrough:
            # send_file responses skip werkzeug's close hooks, so wrap the body to know when it went out
            resp.response = ClosingIterator(resp.response, sent)
        else:
            resp.call_on_close(sent)
        return resp

    @app.teardown_request
    def _failed(exc):
        p = g.get("perf")
        if exc is None or p is None:
            return
        p["error"] = type(exc).__name__
        if not p["logged"]:   # no response went through after_request at all
            ms = (time.perf_counter() - p["t0"]) * 1000
            _write(dict(_line(p, 500, ms, None), error=p["error"]))


def _line(p, status, ms, size) -> dict:
    rule = request.url_rule.rule if request.url_rule else None
    qs = request.query_string.decode("latin-1")
    return {"ts": datetime.fromtimestamp(p["wall"]).isoformat(timespec="milliseconds"),
            "kind": "server", "method": request.method, "route": rule,
            "path": request.path + ("?" + qs if qs else ""), "status": status,
            "ms": round(ms, 1), "bytes": size, "client": request.remote_addr,
            "stages": {k: round(v, 1) for k, v in p["stages"].items()}, "attrs": p["attrs"]}


def _write(line: dict) -> None:
    try:
        LOG.info(json.dumps(line, separators=(",", ":")))
    except Exception:  # noqa: BLE001 - timing must never break a request
        pass


@contextmanager
def stage(name: str):
    """Time a block as one stage of this request. Repeated names add up (two decodes = one total)."""
    if not has_request_context() or g.get("perf") is None:
        yield
        return
    t = time.perf_counter()
    try:
        yield
    finally:
        st = g.perf["stages"]
        st[name] = st.get(name, 0.0) + (time.perf_counter() - t) * 1000


def note(**attrs) -> None:
    """Record facts about this request, such as cache="hit"."""
    if has_request_context() and g.get("perf") is not None:
        g.perf["attrs"].update(attrs)


CLIENT_FIELDS = {"type": str, "name": str, "ms": (int, float), "bytes": (int, float), "server_ms": (int, float),
                 "wait_ms": (int, float), "ttfb_ms": (int, float), "dl_ms": (int, float),
                 "screen": str, "detail": str, "n": int}


def client_lines(items: list, client: str, agent: str) -> int:
    """Log measurements the phone pages sent. Only known fields of the right type are kept, so
    a page can't write arbitrary text into the log. Returns how many were logged."""
    n = 0
    now = datetime.now().isoformat(timespec="milliseconds")
    device = "iphone" if "iPhone" in agent else "ipad" if "iPad" in agent else "android" if "Android" in agent else "desktop"
    for it in items[:500]:
        if not isinstance(it, dict):
            continue
        line = {"ts": now, "kind": "client", "client": client, "device": device}
        for k, typ in CLIENT_FIELDS.items():
            v = it.get(k)
            if isinstance(v, typ) and not isinstance(v, bool):
                line[k] = v[:300] if isinstance(v, str) else int(v) if k in ("bytes", "n") else round(float(v), 1)
        if "type" in line and "ms" in line:
            _write(line)
            n += 1
    return n
