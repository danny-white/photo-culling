"""Browser tests for the Culling Bay web app (review/static/m), in headless Chromium through Playwright.

Run from the repo root:

    ./venv/bin/python -m unittest discover -s review/tests/web

This folder has no __init__.py, so the main suite (`discover -s review/tests -t .`) leaves it out.
It needs `playwright` (requirements-dev.txt) and its Chromium (`./venv/bin/python -m playwright
install chromium`); without them every test skips. The tests start their own server on
127.0.0.1:8813 over the real trial_out/trial.db (read-only) with a throwaway annotations.db, inbox
and state folder, and clear those before each test. Pictures are stubbed in the browser with a
small grey JPEG, so no RAW is read or decoded (a test sets `real_pictures` to see the real ones).
Nothing here talks to the live server, and search never reaches Ollama. CB_WEB_STATIC serves
another copy of static/m (say an older commit's, from `git archive`) to see a test fail there.
"""
import atexit
import io
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
import warnings
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
TRIAL_DB = ROOT / "trial_out" / "trial.db"
PORT = int(os.environ.get("CB_WEB_PORT", "8813"))
BASE = f"http://127.0.0.1:{PORT}"
DAY = "2026/2026-10-01"          # 16 stacks: singles, 3-frame bursts and a bracket (Sony)

try:
    from playwright.sync_api import sync_playwright, Error as PlaywrightError
except ImportError:              # the suite skips
    sync_playwright = None
    PlaywrightError = Exception


# ---------------------------------------------------------------- the server
class Server:
    """The /m blueprint on 127.0.0.1:PORT over the real trial.db, with throwaway state."""

    def __init__(self):
        from flask import Flask
        from werkzeug.serving import make_server
        import logging
        import mobile
        import photo_cull as pc
        self.tmp = Path(tempfile.mkdtemp(prefix="cbweb-"))
        self.inbox = self.tmp / "inbox"
        self.applied = self.inbox / "applied"
        self.applied.mkdir(parents=True)
        self.state = self.tmp / "state"
        self.state.mkdir()
        self.anno_path = self.tmp / "annotations.db"
        self.cache = ROOT / "review" / "cache"     # pictures made from the RAWs (gitignored), when not stubbed
        self.cache.mkdir(exist_ok=True)
        self.write_practice()

        def db_ro():
            con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            return con

        def anno():
            con = sqlite3.connect(self.anno_path, timeout=5)
            con.row_factory = sqlite3.Row
            return con

        logging.getLogger("werkzeug").setLevel(logging.ERROR)
        app = Flask(__name__)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=db_ro, anno=anno, pc=pc, cache_dir=self.cache,
            static_dir=Path(os.environ.get("CB_WEB_STATIC", ROOT / "review" / "static" / "m")), state_dir=self.state,
            inbox=self.inbox, check_mount=False, ingest_log=self.tmp / "ingest.log",
            ollama_url="http://127.0.0.1:9"))   # nothing listens there: search never reaches Ollama
        self.log = []                         # (method, path, status) of every request, newest last

        @app.after_request
        def note(resp):
            from flask import request
            self.log.append((request.method, request.path, resp.status_code))
            return resp
        self.srv = make_server("127.0.0.1", PORT, app, threaded=True)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def stop(self):
        self.srv.shutdown()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_practice(self):
        """Three challenges on one photo of DAY: a phone one, a Needs Desktop one and its companion."""
        with sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True) as con:
            path = con.execute("SELECT path FROM images WHERE filename='DSC05036.ARW' AND path LIKE ? LIMIT 1",
                               (f"%/{DAY}/%",)).fetchone()[0]
        base = {"path": path, "mode": "phone", "minutes": 10, "aim": "Keep the light warm.",
                "why": "One clear light source.", "hints": ["Start with the light."], "level": "easy",
                "picked_by": "Browser test", "added": "2026-11-21"}
        (self.state / "practice.json").write_text(json.dumps({"challenges": [
            dict(base, id="web-lantern", title="Web challenge", tools=["Crop", "Color › Mix"]),
            dict(base, id="web-aurora", title="Web desktop", mode="mac", needs_desktop=True,
                 desktop_reason="Uses Enhance › Denoise, which Lightroom on the phone doesn't have.",
                 tools=["Enhance › Denoise", "Light"]),
            dict(base, id="web-aurora-phone", title="Web desktop", companion_of="web-aurora",
                 tools=["White balance", "Light"]),
        ]}), encoding="utf-8")

    def reset(self):
        """Forget every decision, position, send, receipt and Lightroom state."""
        self.log.clear()
        for p in list(self.inbox.iterdir()) + list(self.applied.iterdir()):
            if p.is_file():
                p.unlink()
        if self.anno_path.exists():
            with sqlite3.connect(self.anno_path, timeout=5) as con:
                for t in ("cull_decisions", "cull_actions", "cull_days", "cull_receipts", "lr_state",
                          "practice_state"):
                    try:
                        con.execute(f"DELETE FROM {t}")
                    except sqlite3.OperationalError:   # not made yet
                        pass

    # ------------------------------------------------ fixtures through the API
    def get(self, path):
        with urllib.request.urlopen(BASE + path, timeout=300) as r:
            return json.loads(r.read())

    def write(self, method, path, body):
        req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", "X-Culling-Bay": "1"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def decide(self, day, changes, action_id=None):
        action_id = action_id or "fixture-" + str(time.monotonic_ns())
        status, body = self.write("POST", "/m/api/decide", {"action_id": action_id, "day": day, "changes": changes})
        assert status == 200, body
        return action_id

    def reject_all(self, day, stacks=None, finish=True):
        """Reject every frame of the day (or of the first `stacks` stacks), as one action each."""
        d = self.get("/m/api/day/" + day)
        for s in d["stacks"][:stacks]:
            self.decide(day, [{"id": f["id"], "flag": "reject", "via": "card"} for f in s["frames"]])
        if finish:
            status, body = self.write("PUT", f"/m/api/day/{day}/progress",
                                      {"pass": 2, "cursor": d["stacks"][-1]["id"], "finished": True})
            assert status == 200, body
        return d

    def lightroom(self, *lines, name="19990101-000000-catalog.tsv"):
        """What the plug-in would report from a sync: `day\\tfile\\tpick\\trating\\tflag_by\\tstars_by`."""
        (self.applied / name).write_text("#cull-catalog v1\n" + "".join(l + "\n" for l in lines))

    def receipt(self, *lines, name="20000101-000000-receipt.tsv"):
        """A plug-in receipt: `day\\tfile\\toutcome\\tdetail` (landed, your_flag_kept, not_found)."""
        (self.applied / name).write_text("#cull-receipt v1\n" + "".join(l + "\n" for l in lines))

    def sql(self, query, *args):
        with sqlite3.connect(self.anno_path, timeout=5) as con:
            return con.execute(query, args).fetchall()


_server = None
_pw = None
_browser = None
_no_images = None
_why_not = None


def _shutdown():
    global _browser, _pw, _server
    for close in (lambda: _no_images and _no_images.close(), lambda: _browser and _browser.close(), lambda: _pw and _pw.stop(),
                  lambda: _server and _server.stop()):
        try:
            close()
        except Exception:   # noqa: BLE001 - best effort at exit
            pass


atexit.register(_shutdown)


def server():
    global _server
    if _server is None:
        _server = Server()
    return _server


def browser():
    """One headless Chromium for the whole run; raises SkipTest when there is none."""
    global _pw, _browser, _why_not
    if _browser is not None:
        return _browser
    if _why_not:
        raise unittest.SkipTest(_why_not)
    if sync_playwright is None:
        _why_not = "Playwright is not installed (pip install -r requirements-dev.txt)"
        raise unittest.SkipTest(_why_not)
    if not TRIAL_DB.exists():
        _why_not = "needs trial_out/trial.db"
        raise unittest.SkipTest(_why_not)
    try:
        _pw = sync_playwright().start()
        _browser = _pw.chromium.launch()
    except PlaywrightError as e:
        _why_not = "Chromium for Playwright is missing (python -m playwright install chromium): " + str(e).splitlines()[0]
        if _pw:
            _pw.stop()
            _pw = None
        raise unittest.SkipTest(_why_not)
    return _browser


def browser_without_images():
    """A second Chromium that loads no pictures at all. Playwright turns the HTTP cache off in a
    context with routes, so a test of revalidation (ETag, 304) can't stub the pictures."""
    global _no_images
    browser()
    if _no_images is None:
        _no_images = _pw.chromium.launch(args=["--blink-settings=imagesEnabled=false"])
    return _no_images


def stub_jpeg(w=600, h=400):
    from PIL import Image, ImageDraw
    im = Image.new("RGB", (w, h), (92, 96, 102))
    ImageDraw.Draw(im).rectangle((w // 4, h // 4, 3 * w // 4, 3 * h // 4), fill=(140, 146, 152))
    out = io.BytesIO()
    im.save(out, "JPEG", quality=70)
    return out.getvalue()


STUB = None
PICTURES = re.compile(r"/m/api/(img|crop|export)/")


# ---------------------------------------------------------------- the test case
class BrowserCase(unittest.TestCase):
    """A fresh browser context per test (its own localStorage), a page, and helpers. Console
    errors and uncaught exceptions fail the test unless it expects them."""

    viewport = {"width": 1280, "height": 900}
    device = None             # a Playwright device name, e.g. "iPhone 15"
    real_pictures = False
    no_pictures = False       # no pictures and no routes: the browser's HTTP cache works

    @classmethod
    def setUpClass(cls):
        browser()
        cls.server = server()
        # The server's own sqlite handles, closed by the garbage collector: not this suite's business.
        warnings.filterwarnings("ignore", category=ResourceWarning)

    def setUp(self):
        global STUB
        self.server.reset()
        self.problems = []
        self.expected = []        # regexes for console errors this test expects (refused requests)
        opts = dict(_pw.devices[self.device]) if self.device else {"viewport": self.viewport}
        self.context = (browser_without_images() if self.no_pictures else browser()).new_context(**opts)
        if not self.real_pictures and not self.no_pictures:
            if STUB is None:
                STUB = stub_jpeg()
            self.context.route(PICTURES, lambda route: route.fulfill(
                status=200, body=STUB, headers={"Content-Type": "image/jpeg", "Cache-Control": "max-age=60"}))
        self.page = self.new_page()

    def tearDown(self):
        try:
            self.context.close()
        except PlaywrightError:
            pass
        real = [p for p in self.problems if not any(re.search(x, p) for x in self.expected)]
        self.assertEqual(real, [], "console errors or uncaught exceptions")

    def new_page(self):
        page = self.context.new_page()
        page.set_default_timeout(15000)
        page.on("console", lambda m: m.type == "error" and self.problems.append("console: " + m.text))
        page.on("pageerror", lambda e: self.problems.append("pageerror: " + str(e)))
        return page

    def expect_errors(self, *patterns):
        """Console lines a test causes on purpose, e.g. a request it answers with 409."""
        self.expected += patterns or [r"Failed to load resource|net::ERR_"]

    # ------------------------------------------------ driving the page
    def open(self, path="/m/", page=None):
        page = page or self.page
        page.goto(BASE + path)
        return page

    def open_day(self, day=DAY, page=None):
        page = page or self.page
        self.open("/m/#/day/" + day, page)
        page.wait_for_function("['cull', 'summary'].includes(document.querySelector('#view').dataset.screen)")
        return page

    def screen(self, page=None):
        return (page or self.page).evaluate("document.querySelector('#view').dataset.screen")

    def wait_screen(self, name, page=None, timeout=15000):
        (page or self.page).wait_for_function(
            "s => document.querySelector('#view').dataset.screen === s", arg=name, timeout=timeout)

    def key(self, k, page=None):
        (page or self.page).keyboard.press(k)

    def text(self, css, page=None):
        el = (page or self.page).query_selector(css)
        return el.text_content() if el else ""

    def toast(self, page=None):
        return self.text("#toast span", page)

    def wait_toast(self, part, page=None):
        (page or self.page).wait_for_function(
            "t => (document.querySelector('#toast span') || {}).textContent?.includes(t)", arg=part)

    def queued(self, page=None):
        return (page or self.page).evaluate("JSON.parse(localStorage.getItem('cbm-queue') || '[]')")

    def drain(self, page=None, timeout=15000):
        """Wait until the page's write queue is empty: everything reached the server."""
        (page or self.page).wait_for_function(
            "JSON.parse(localStorage.getItem('cbm-queue') || '[]').length === 0", timeout=timeout)

    def cursor(self, page=None):
        """The stack on the card: the index shown in the day filmstrip."""
        return (page or self.page).evaluate("+(document.querySelector('.film-thumb.cur') || {dataset: {}}).dataset.stack")

    def flags(self, day=DAY):
        """The server's decisions for the day, per stack: [[flag or None per frame], ...]."""
        d = self.server.get("/m/api/day/" + day)
        return [[(f["decision"] or {}).get("flag") for f in s["frames"]] for s in d["stacks"]]
