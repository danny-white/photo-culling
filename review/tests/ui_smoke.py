"""Click-through smoke test of the phone app in real headless Firefox, driven over WebDriver.

Not part of `unittest discover` (it needs Firefox and geckodriver, both snaps here). It starts
its own server on 127.0.0.1 with the real trial.db (read-only) and a THROWAWAY annotations.db,
so your real decisions are never touched. Run from the repo root:

    ./venv/bin/python review/tests/ui_smoke.py [--shots DIR]

Snap Firefox and geckodriver can't use /tmp or hidden folders, so the browser profile lives in
~/cbm-ui-smoke for the length of the run and is deleted afterwards.
"""
import argparse
import base64
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
DAY = "2026/2026-10-01"
APP_PORT, WD_PORT = 8765, 4444


def start_app(tmp: Path):
    from flask import Flask
    from werkzeug.serving import make_server
    import mobile
    import photo_cull as pc

    def db_ro():
        con = sqlite3.connect(f"file:{ROOT / 'trial_out' / 'trial.db'}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
        return con

    def anno():
        con = sqlite3.connect(tmp / "annotations.db", timeout=5)
        con.row_factory = sqlite3.Row
        return con

    import logging
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    app = Flask(__name__)
    app.register_blueprint(mobile.make_blueprint(
        db_ro=db_ro, anno=anno, pc=pc, cache_dir=ROOT / "review" / "cache",
        static_dir=ROOT / "review" / "static" / "m", state_dir=tmp / "state"))
    srv = make_server("127.0.0.1", APP_PORT, app, threaded=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class WD:
    """Just enough of the W3C WebDriver protocol."""
    def __init__(self):
        self.base = f"http://127.0.0.1:{WD_PORT}"
        caps = {"capabilities": {"alwaysMatch": {"browserName": "firefox", "moz:firefoxOptions": {
            "args": ["-headless", "--width=414", "--height=860"]}}}}
        self.sid = self.call("POST", "/session", caps)["sessionId"]

    def call(self, method, path, body=None):
        req = urllib.request.Request(self.base + path, method=method,
                                     data=json.dumps(body or {}).encode() if method == "POST" else None,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())["value"]

    def s(self, method, path, body=None):
        return self.call(method, f"/session/{self.sid}{path}", body)

    def go(self, url): self.s("POST", "/url", {"url": url})
    def js(self, script, *args): return self.s("POST", "/execute/sync", {"script": script, "args": list(args)})

    def wait(self, cond_js, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            if self.js("return !!(" + cond_js + ")"):
                return True
            time.sleep(0.15)
        raise AssertionError("timed out waiting for: " + cond_js)

    def click(self, css):
        ok = self.js("const e=document.querySelector(arguments[0]); if(!e) return false; e.click(); return true;", css)
        if not ok:
            raise AssertionError("no element: " + css)

    def text(self, css): return self.js("const e=document.querySelector(arguments[0]); return e ? e.textContent : '';", css)

    def drag(self, css, dy):
        r = self.js("const b=document.querySelector(arguments[0]).getBoundingClientRect(); return [b.x+b.width/2, b.y+b.height/2];", css)
        x, y = int(r[0]), int(r[1])
        steps = [{"type": "pointerMove", "duration": 30, "x": x, "y": y + dy * k // 6} for k in range(1, 7)]
        self.s("POST", "/actions", {"actions": [{"type": "pointer", "id": "finger", "parameters": {"pointerType": "mouse"},
            "actions": [{"type": "pointerMove", "duration": 0, "x": x, "y": y}, {"type": "pointerDown", "button": 0}]
            + steps + [{"type": "pointerUp", "button": 0}]}]})

    def shot(self, path):
        Path(path).write_bytes(base64.b64decode(self.s("GET", "/screenshot")))

    def quit(self):
        try:
            self.call("DELETE", f"/session/{self.sid}")
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", type=Path, default=None, help="save screenshots here")
    a = ap.parse_args()
    tmp = Path(tempfile.mkdtemp(prefix="cbm-ui-"))
    prof = Path.home() / "cbm-ui-smoke"
    prof.mkdir(exist_ok=True)
    srv = start_app(tmp)
    gd = subprocess.Popen(["geckodriver", "--port", str(WD_PORT), "--profile-root", str(prof)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          env=dict(os.environ, TMPDIR=str(prof)))
    for _ in range(50):   # wait for geckodriver to listen
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{WD_PORT}/status", timeout=1)
            break
        except OSError:
            time.sleep(0.2)
    results, wd = [], None

    def check(cond, msg):
        results.append(("PASS " if cond else "FAIL ") + msg)

    def loaded(css):
        wd.wait("[...document.querySelectorAll(%s)].every(i => i.complete && i.naturalWidth > 0)" % json.dumps(css), timeout=30)
        time.sleep(0.4)   # let the enter animation finish

    def shot(name):
        if a.shots:
            a.shots.mkdir(parents=True, exist_ok=True)
            wd.shot(a.shots / f"{name}.png")

    try:
        wd = WD()
        app = f"http://127.0.0.1:{APP_PORT}/m/"
        wd.go(app)
        wd.wait("document.querySelectorAll('.day').length > 300")
        check(True, "days list: %d days" % wd.js("return document.querySelectorAll('.day').length"))
        shot("1-days")

        wd.click(f'.day[data-day="{DAY}"]')
        wd.wait("document.querySelector('.sw-grid')")
        loaded(".sw-t img")
        tiles = wd.js("return document.querySelectorAll('.sw-t').length")
        check(tiles > 5, f"sweep grid: {tiles} tiles")
        wd.click('.sw-t[data-i="1"]'); wd.click('.sw-t[data-i="7"]')
        check(wd.text('[data-act="sweep-done"]') == "Reject 2, start pass 2", "sweep footer: " + wd.text('[data-act="sweep-done"]'))
        shot("2-sweep")
        wd.click('[data-act="sweep-done"]')
        wd.wait("document.querySelector('.card')")
        check("Pass 2" in wd.text(".top .t"), "pass 2 card: " + wd.text(".top .t"))
        wd.click('#toast [data-act="undo"]')
        wd.wait("document.querySelector('.sw-grid')")
        check(wd.js("return document.querySelectorAll('.sw-t.on').length") == 2, "undo returns to the sweep with both marks")
        wd.click('[data-act="sweep-done"]')
        wd.wait("document.querySelector('.card')")

        # first card: the 4-frame burst led by its sharpest frame
        check("Sharpest" in wd.text(".badges"), "burst card shows Sharpest: " + wd.text(".badges"))
        loaded(".card img")
        h = wd.js("return document.querySelector('.card').getBoundingClientRect().height")
        check(h > 150, f"card is laid out: {h:.0f} px tall")
        shot("3-card")
        # double-tap: a 1:1 crop from the RAW, then back
        r = wd.js("const b=document.querySelector('.card img').getBoundingClientRect(); return [b.x+b.width*0.3, b.y+b.height*0.6];")
        tapx, tapy = int(r[0]), int(r[1])
        tapping = [{"type": "pointerMove", "duration": 0, "x": tapx, "y": tapy}, {"type": "pointerDown", "button": 0},
                   {"type": "pointerUp", "button": 0}, {"type": "pause", "duration": 80},
                   {"type": "pointerDown", "button": 0}, {"type": "pointerUp", "button": 0}]
        wd.s("POST", "/actions", {"actions": [{"type": "pointer", "id": "tapper", "parameters": {"pointerType": "mouse"}, "actions": tapping}]})
        wd.wait("document.querySelector('#fz')")
        t0 = time.time()
        loaded("#fz img")
        crop = wd.js("const i=document.querySelector('#fz img'); return [i.naturalWidth, i.naturalHeight, decodeURIComponent(i.src)];")
        q = dict(kv.split("=") for kv in crop[2].split("?")[1].split("&"))
        check(crop[0] > 400 and abs(float(q["x"]) - 0.3) < 0.02 and abs(float(q["y"]) - 0.6) < 0.02,
              f"focus crop {crop[0]}x{crop[1]} at the tapped spot in {time.time() - t0:.1f}s: " + crop[2].split("?")[1])
        shot("3b-focus")
        wd.click('[data-act="close-focus"]')
        wd.wait("document.querySelector('.card')")

        wd.click('[data-act="keep"]')
        wd.wait("document.querySelector('#toast').textContent.includes('Kept')")
        check("3 rejected with a note" in wd.text("#toast"), "keep frame: " + wd.text("#toast"))

        # the bracket suggests Keep all
        wd.wait("document.querySelector('.card')")
        check(wd.js("return !!document.querySelector('.pb-all.sugg')") and "bracket" in wd.text(".badges"),
              "bracket card suggests Keep all: " + wd.text(".badges"))
        wd.click('[data-act="keep-all"]')
        wd.wait("document.querySelector('#toast').textContent.includes('Kept all')")
        check("bracket" in wd.text("#toast"), "keep all: " + wd.text("#toast"))

        # a swipe up keeps
        wd.wait("document.querySelector('.card') && !document.querySelector('.card').style.transform")
        before = wd.text(".fname")
        wd.drag(".card", -220)
        wd.wait("document.querySelector('#toast').textContent.includes('Kept') && document.querySelector('.fname') && document.querySelector('.fname').textContent !== arguments[0]".replace("arguments[0]", json.dumps(before)))
        check(True, "swipe up kept " + before.split(" ")[0])

        # the details sheet
        wd.click('[data-act="info"]')
        wd.wait("!document.querySelector('#sheet').hidden")
        loaded(".card img")
        sheet = wd.text("#sheet")
        check("verdicts stay off the phone" in sheet and "AI: " not in sheet, "details sheet: " + sheet[:80])
        shot("4-sheet")
        wd.click('[data-act="close-sheet"]')

        # a burst through the picker, if one is left; then finish the day
        for _ in range(40):
            if wd.js("return !!document.querySelector('[data-act=\"send\"]')"):
                break
            if wd.js("return !!document.querySelector('.chip[data-act=\"picker\"]')") and not wd.js("return window.__picked"):
                wd.click('.chip[data-act="picker"]')
                wd.wait("document.querySelector('.pk-strip') || document.querySelector('.du')")
                if wd.js("return !!document.querySelector('.pk-strip')"):
                    shot("5-picker")
                    wd.click('[data-act="pk-keep"]') if wd.js("return !document.querySelector('[data-act=\"pk-keep\"]').disabled") else (wd.click('[data-act="tick"]'), wd.click('[data-act="pk-keep"]'))
                else:
                    wd.click('[data-act="duel-done"]')
                wd.js("window.__picked = true")
                wd.wait("document.querySelector('.card') || document.querySelector('[data-act=\"send\"]')")
                continue
            wd.click('[data-act="keep"]')
            time.sleep(0.25)
        check(wd.js("return !!document.querySelector('[data-act=\"send\"]')"), "reached the rejects review")
        secs = wd.js("return [...document.querySelectorAll('.sec')].map(e => e.textContent)")
        check("From bursts · similar frame kept" in secs and "Rejected outright" in secs, "summary sections: %s" % secs)
        shot("6-summary")
        n = wd.js("return document.querySelectorAll('.sm-th').length")
        wd.click(".sm-th")
        wd.wait(f"document.querySelectorAll('.sm-th').length === {n - 1}")
        check(True, f"rescue: {n} -> {n - 1} rejects")
        for asset, kind in (("manifest.webmanifest", "manifest+json"), ("sw.js", "javascript"), ("apple-touch-icon.png", "image/png")):
            with urllib.request.urlopen(app + asset) as resp:
                check(kind in resp.headers.get("Content-Type", ""), f"{asset} served as {resp.headers.get('Content-Type')}")

        # everything reached the server: reload and compare
        wd.wait("JSON.parse(localStorage.getItem('cbm-queue') || '[]').length === 0", timeout=10)
        wd.go(app + f"#/day/{DAY}")
        wd.wait("document.querySelector('[data-act=\"send\"]') || document.querySelector('.card')")
        check(wd.js("return !!document.querySelector('[data-act=\"send\"]')"), "reload resumes at the rejects review")
        con = sqlite3.connect(tmp / "annotations.db")
        flags = dict(con.execute("SELECT flag, COUNT(*) FROM cull_decisions GROUP BY flag").fetchall())
        undone = con.execute("SELECT COUNT(*) FROM cull_actions WHERE undone=1").fetchone()[0]
        check(flags.get("pick", 0) > 0 and flags.get("reject", 0) > 0 and undone == 1,
              f"server has the decisions: {flags}, {undone} undone action")
    except Exception as e:
        results.append(f"ERROR {type(e).__name__}: {e}")
        if wd:
            shot("error")
    finally:
        if wd:
            wd.quit()
        gd.terminate()
        srv.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(prof, ignore_errors=True)
    print("\n".join(results))
    sys.exit(0 if results and all(r.startswith("PASS") for r in results) else 1)


if __name__ == "__main__":
    main()
