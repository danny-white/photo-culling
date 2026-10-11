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
    (tmp / "inbox" / "applied").mkdir(parents=True, exist_ok=True)
    # what the plugin would report from a Lightroom sync: two stacks you already picked by hand
    (tmp / "inbox" / "applied" / "19990101-000000-catalog.tsv").write_text(
        "#cull-catalog v1\n2026-10-01\tDSC05062.ARW\t1\t0\tyou\t\n2026-10-01\tDSC05066.ARW\t1\t3\tyou\tyou\n"
        "2026-10-01\tDSC05063.ARW\t0\t4\t\tyou\n")   # ...and one you only rated
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
        static_dir=ROOT / "review" / "static" / "m", state_dir=tmp / "state",
        inbox=tmp / "inbox", check_mount=False))
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
        wd.wait("document.querySelectorAll('.year').length > 10")
        years = wd.js("return [...document.querySelectorAll('.year b')].map(e => e.textContent)")
        open_days = wd.js("return document.querySelectorAll('.day').length")
        check(years[0] == "2026" and years == sorted(years, reverse=True) and 0 < open_days < 100,
              f"days grouped by year, newest open: {years[:4]}..., {open_days} days showing")
        shot("1-days")
        wd.click('.yearbar [data-year="2015"]')
        wd.wait("document.querySelector('.day[data-day^=\"2015/\"]')")
        months = wd.js("return [...document.querySelectorAll('#days-list .sec')].map(e => e.textContent)")
        check(any(m.startswith("June") for m in months), f"jumping to 2015 opens it by month: {months[-3:]}")
        summ = wd.js("return (document.querySelector('.day[data-day=\"%s\"] .dsum') || {}).textContent || ''" % DAY)
        word = next((w.strip('.,').lower() for w in summ.split() if len(w.strip('.,')) > 6), None)
        check(bool(summ) and word, "the day row shows its two-line summary: " + summ[:70])
        answered = "document.querySelector('#days-list .rnote') && ![...document.querySelectorAll('#days-list .rnote')].some(e => e.textContent.includes('Searching'))"
        def search(q):
            wd.js("const i=document.querySelector('#day-search'); i.value=arguments[0]; i.dispatchEvent(new Event('input', {bubbles:true}));", q)
            time.sleep(0.4)
            wd.wait(answered, timeout=30)
            return wd.js("return [...document.querySelectorAll('#days-list .day')].map(e => e.dataset.day)")
        if word:
            hits = search(word)
            check(DAY in hits, f"search matches summary text ({word!r}): {len(hits)} day(s)")
        found = search("2026-10-01")
        check(found == [DAY], f"search finds the day by date: {found}")
        hits = search("chick on a red cliff")
        why = wd.js("return (document.querySelector('#days-list .day .why') || {}).textContent || ''")
        check(len(hits) > 0 and "photo" in why, f"search by meaning: {len(hits)} day(s), first: {hits[:1]} {why[:60]!r}")
        wd.click('#search-x')
        wd.wait("document.querySelectorAll('.year').length > 3")
        wd.click('[data-act="day-view"][data-v="place"]')
        wd.wait("document.querySelector('#days-list .note')")
        check("without a location" in wd.text("#days-list"), "place view: " + wd.text("#days-list .note")[:70])
        wd.click('[data-act="day-view"][data-v="date"]')
        wd.wait("document.querySelector('.yearbar')")

        wd.click(f'.day[data-day="{DAY}"]')
        wd.wait("document.querySelector('.card')")
        # one pass: the 3 stacks already kept in Lightroom are skipped, and count toward the budget.
        # Stacks follow the camera's own tags: each Sony shutter press is one stack (16 on this day).
        day_json = json.loads(urllib.request.urlopen(app + "api/day/" + DAY, timeout=300).read())
        af_of = {f["file"]: f["af"] for st in day_json["stacks"] for f in st["frames"]}
        check(len(day_json["stacks"]) == 16 and wd.text("#budget") == "Kept 3 of 5" and "13 stacks to go" in wd.text(".top .t"),
              f"one pass; Lightroom stacks skipped and counted: {len(day_json['stacks'])} stacks, {wd.text('#budget')} / {wd.text('.top .t small')}")

        def keep_any():   # Keep on a single, Keep all on a burst or bracket
            wd.click('.bar [data-act="keep"]') if wd.js("return !!document.querySelector('.bar [data-act=\"keep\"]')") else wd.click('[data-act="keep-all"]')

        # first card: a single frame, with the AF box and the 1:1 band under it
        loaded(".card img")
        h = wd.js("return document.querySelector('.card').getBoundingClientRect().height")
        check(h > 150 and wd.js("return !!document.querySelector('.card .af')"), f"card is laid out: {h:.0f} px tall, with its AF box")
        fit = wd.js("const p=document.querySelector('.card .photo'), i=p.querySelector('img'), r=p.getBoundingClientRect(); return [r.width/r.height, i.naturalWidth/i.naturalHeight];")
        check(abs(fit[0] - fit[1]) < 0.02, f"the photo box has the photo's own shape: {fit[0]:.3f} vs {fit[1]:.3f}")
        shot("3-card")
        # double-tap: a 1:1 crop from the RAW at the camera's AF point, then back
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
        af = af_of["DSC05036.ARW"]
        check(crop[0] > 400 and abs(float(q["x"]) - af[0]) < 0.001 and abs(float(q["y"]) - af[1]) < 0.001,
              f"focus crop {crop[0]}x{crop[1]} at the AF point in {time.time() - t0:.1f}s: " + crop[2].split("?")[1])
        shot("3b-focus")
        wd.click('[data-act="close-focus"]')
        wd.wait("document.querySelector('.card')")
        wd.click('.bar [data-act="keep"]')
        wd.wait("document.querySelector('#toast').textContent.startsWith('Kept DSC05036')")

        # a burst: Choose opens it on its first frame; keep the sharpest from the picker
        wd.wait("document.querySelector('.card') && !document.querySelector('.card').style.transform")
        check("Sharpest" in wd.text(".badges") and wd.text('.bar [data-act="choose"]') == "Choose",
              "burst card shows Sharpest, and Choose: " + wd.text(".badges"))
        wd.click('.bar [data-act="choose"]')
        wd.wait("document.querySelector('.pk-strip')")
        check(wd.text(".pk-id").endswith("1/3"), "Choose opens the burst on its first frame: " + wd.text(".pk-id"))
        shot("5-picker")
        wd.click('[data-act="view"][data-i="2"]'); wd.click('[data-act="tick"]'); wd.click('[data-act="pk-keep"]')
        wd.wait("document.querySelector('#toast').textContent.includes('rejected with a note')")
        check("Kept DSC05039 · 2 rejected with a note" in wd.text("#toast"), "keep frame: " + wd.text("#toast"))
        wd.click('#toast [data-act="undo"]')                              # undo puts the burst back
        wd.wait("document.querySelector('#toast').textContent.includes('Undone')")
        wd.wait("document.querySelector('.card') && !document.querySelector('.card').style.transform")
        check(wd.text("#budget") == "Kept 4 of 5" and "Sharpest" in wd.text(".badges"), "undo puts the burst back: " + wd.text("#budget"))
        wd.click('.bar [data-act="choose"]'); wd.wait("document.querySelector('.pk-strip')")
        wd.click('[data-act="view"][data-i="2"]'); wd.click('[data-act="tick"]'); wd.click('[data-act="pk-keep"]')
        wd.wait("document.querySelector('#toast').textContent.startsWith('Kept DSC05039')")   # not the "Undone: Kept…" toast

        # the bracket (from the camera's tags) suggests Keep all; the sixth keep is one over
        wd.wait("document.querySelector('.card') && !document.querySelector('.card').style.transform")
        check(wd.js("return !!document.querySelector('.pb-all.sugg')") and "bracket" in wd.text(".badges"),
              "bracket card suggests Keep all: " + wd.text(".badges"))
        wd.click('[data-act="keep-all"]')
        wd.wait("document.querySelector('#toast').textContent.includes('Kept all')")
        check("bracket" in wd.text("#toast") and wd.text("#budget") == "Kept 6 · 1 over 5"
              and wd.js("return document.querySelector('#budget').classList.contains('over')") and "1 over this shoot" in wd.text("#toast"),
              "keep all; the sixth keep is one over: " + wd.text("#toast") + " / " + wd.text("#budget"))
        shot("2-over")

        # a swipe up on a bracket opens it rather than keeping a frame unseen
        wd.wait("document.querySelector('.card') && !document.querySelector('.card').style.transform")
        wd.drag(".card", -150)
        wd.wait("document.querySelector('.pk-strip')")
        check(wd.text(".pk-id").endswith("1/3"), "swipe up opens the bracket: " + wd.text(".pk-id"))
        wd.click('[data-act="close-picker"]'); wd.wait("document.querySelector('.card')")
        wd.click('.bar [data-act="reject"]')
        wd.wait("document.querySelector('#toast').textContent.includes('Rejected all 3')")

        # the details sheet
        wd.wait("document.querySelector('.card') && !document.querySelector('.card').style.transform")
        wd.click('[data-act="info"]')
        wd.wait("!document.querySelector('#sheet').hidden")
        loaded(".card img")
        sheet = wd.text("#sheet")
        check("verdicts stay off the phone" in sheet and "AI: " not in sheet and "More like this" in sheet, "details sheet: " + sheet[:80])
        shot("4-sheet")
        wd.click('[data-act="close-sheet"]')

        # the rest of the day: one bracket through the picker, one outright reject, the rest kept
        for _ in range(40):
            if wd.js("return !!document.querySelector('[data-act=\"send\"]')"):
                break
            wd.wait("document.querySelector('.card') && !document.querySelector('.card').style.transform")
            if wd.js("return !!document.querySelector('.chip[data-act=\"picker\"]')") and not wd.js("return window.__picked"):
                wd.click('.chip[data-act="picker"]')
                wd.wait("document.querySelector('.pk-strip')")
                wd.click('[data-act="tick"]'); wd.click('[data-act="pk-keep"]')
                wd.js("window.__picked = true")
                wd.wait("document.querySelector('.card') || document.querySelector('[data-act=\"send\"]')")
                continue
            if "DSC05061" in wd.text(".fname"):                            # one outright reject
                wd.click('.bar [data-act="reject"]')
            else:
                keep_any()
            time.sleep(0.3)
        check(wd.js("return !!document.querySelector('[data-act=\"send\"]')"), "reached the rejects review")
        secs = wd.js("return [...document.querySelectorAll('.sec')].map(e => e.textContent)")
        kept_sec = next((x for x in secs if x.startswith("Kept · ")), None)
        check(kept_sec == "Kept · 14 of 5" and "From bursts · similar frame kept" in secs and "Rejected outright" in secs,
              "review lists the kept stacks to trim: %s" % secs)
        shot("6-summary")
        wd.click(".sm-th.kept")                                           # trim: drop one kept stack
        wd.wait("document.querySelector('#toast').textContent.includes('Dropped')")
        secs = wd.js("return [...document.querySelectorAll('.sec')].map(e => e.textContent)")
        check("Kept · 13 of 5" in secs, "trimming drops a stack: " + wd.text("#toast"))
        n = wd.js("return document.querySelectorAll('.sm-th[data-act=\"rescue\"]').length")
        wd.click('.sm-th[data-act="rescue"]')
        wd.wait(f"document.querySelectorAll('.sm-th[data-act=\"rescue\"]').length === {n - 1}")
        check(True, f"rescue: {n} -> {n - 1} rejects")
        # the day grid: a toggle from the review, every photo with its final state
        wd.click('.top [data-act="grid"]')
        wd.wait("document.querySelector('.gv-grid')")
        tiles = wd.js("return document.querySelectorAll('.gv-t').length")
        marks = wd.js("return ['m-pick','m-hero','m-reject','m-none'].map(c => document.querySelectorAll('.gv-t.' + c).length)")
        sub = wd.text(".top .t small")
        check(tiles == 32 and marks[0] + marks[1] + marks[2] + marks[3] == 32 and f"{marks[0] + marks[1]} picked · {marks[2]} rejected" in sub,
              f"grid shows all 32 photos: {sub}")
        gray = wd.js("return getComputedStyle(document.querySelector('.gv-t.m-reject img')).filter")
        check("grayscale" in gray, "rejects are greyed: " + gray)
        shot("9-grid")
        wd.click('[data-act="grid-filter"][data-f="picks"]')
        only = wd.js("return [...document.querySelectorAll('.gv-t')].every(t => t.classList.contains('m-pick') || t.classList.contains('m-hero'))")
        check(only and wd.js("return document.querySelectorAll('.gv-t').length") == marks[0] + marks[1], "Picks filter shows only picks")
        wd.click('[data-act="grid-filter"][data-f="all"]')
        wd.click('.gv-t')
        wd.wait("document.querySelector('.card')")
        # going back to a decided stack shows the decision on the photo (the dropped burst)
        line = wd.text(".stline")
        check(wd.js("return document.querySelector('.card').classList.contains('st-reject') && !!document.querySelector('.pb-rej.on')")
              and line.startswith("Rejected"), "a decided stack shows its decision: " + line)
        wd.click('.top [data-act="grid"]')                                # the same button on a card
        wd.wait("document.querySelector('.gv-grid')")
        wd.click('.top [data-act="grid"]')                                # ...and back
        wd.wait("document.querySelector('.card')")
        check(True, "grid toggles from a card and back")
        wd.click('[data-act="days"]')
        wd.wait("document.querySelector('#day-search')")
        wd.click(f'.day[data-day="{DAY}"]')
        wd.wait("document.querySelector('[data-act=\"send\"]')")

        wd.wait("JSON.parse(localStorage.getItem('cbm-queue') || '[]').length === 0", timeout=10)
        wd.click('[data-act="send"]')
        wd.wait("document.querySelector('#toast').textContent.includes('Queued')")
        sent = (tmp / "inbox" / "cull-decisions.tsv").read_text().splitlines()
        check(sent[0] == "#cull-decisions v1" and len(sent) > 20, f"send wrote {len(sent) - 1} rows: " + wd.text("#toast"))
        check(wd.js("return document.querySelector('[data-act=\"send\"]').disabled") and "waiting" in wd.text('.scroll'),
              "after send: " + wd.text('[data-act="send"]'))
        for asset, kind in (("manifest.webmanifest", "manifest+json"), ("sw.js", "javascript"), ("apple-touch-icon.png", "image/png")):
            with urllib.request.urlopen(app + asset) as resp:
                check(kind in resp.headers.get("Content-Type", ""), f"{asset} served as {resp.headers.get('Content-Type')}")

        # Lightroom reports back: you had picked DSC05049 by hand, so the phone's reject lost
        (tmp / "inbox" / "applied" / "20000101-000000-receipt.tsv").write_text(
            "#cull-receipt v1\n2026-10-01\tDSC05049.ARW\tyour_flag_kept\tyou picked it\n")
        (tmp / "inbox" / "applied" / "20000101-000001-catalog.tsv").write_text(
            "#cull-catalog v1\n2026-10-01\tDSC05049.ARW\t1\t0\tyou\t\n")
        wd.go(app + "#/")
        wd.wait("document.querySelector('.day[data-day=\"%s\"]')" % DAY)
        wd.click(f'.day[data-day="{DAY}"]')
        wd.wait("document.querySelector('[data-act=\"send\"]')")
        secs = wd.js("return [...document.querySelectorAll('.sec')].map(e => e.textContent)")
        won = wd.js("return [...document.querySelectorAll('.sm-th.won')].map(e => e.textContent)")
        check("Your Lightroom flag won" in secs and won == ["Picked in LR"], f"conflict shown apart: {secs} {won}")
        check("3 stacks were already flagged or rated in Lightroom and skipped" in wd.text(".scroll"), "summary counts the skipped stacks")
        shot("7-summary-lr")

        # start over: refused for a day with a decision already in Lightroom...
        wd.click('.link[data-act="reset-ask"]')
        wd.wait("!document.querySelector('#sheet').hidden")
        check("Already in Lightroom" in wd.text("#sheet") and not wd.js("return !!document.querySelector('[data-act=\"reset-do\"]')"),
              "start over refused once a decision is in Lightroom")
        wd.click('#sheet [data-act="close-sheet"]')
        # ...and allowed for a day that is only culled on the phone
        DAY2 = "2026/2026-09-29"
        wd.go(app + "#/")
        wd.wait("document.querySelector('#day-search')")
        wd.js("const i=document.querySelector('#day-search'); i.value=''; i.dispatchEvent(new Event('input', {bubbles:true}));")
        wd.wait("document.querySelector('.day[data-day=\"%s\"]')" % DAY2)
        wd.click(f'.day[data-day="{DAY2}"]')
        wd.wait("document.querySelector('.card')")
        fresh = wd.text(".top .t small")
        wd.click('.bar [data-act="reject"]')
        wd.wait("document.querySelector('#toast').textContent.includes('Rejected')")
        wd.wait("document.querySelector('.card') && !document.querySelector('.card').style.transform")
        keep_any()
        wd.wait("document.querySelector('#toast').textContent.includes('Kept')")
        wd.wait("JSON.parse(localStorage.getItem('cbm-queue') || '[]').length === 0", timeout=10)
        con = sqlite3.connect(tmp / "annotations.db")
        before = con.execute("SELECT COUNT(*) FROM cull_decisions WHERE day=?", (DAY2,)).fetchone()[0]
        con.close()
        wd.click('[data-act="reset-ask"]')
        wd.wait("document.querySelector('[data-act=\"reset-do\"]')")
        shot("8-reset")
        wd.click('[data-act="reset-do"]')
        wd.wait("document.querySelector('#toast').textContent.includes('Started over')")
        time.sleep(1.0)   # a stale position save would land in this window
        con = sqlite3.connect(tmp / "annotations.db")
        after = con.execute("SELECT COUNT(*) FROM cull_decisions WHERE day=?", (DAY2,)).fetchone()[0]
        prog = con.execute("SELECT COUNT(*) FROM cull_days WHERE day=?", (DAY2,)).fetchone()[0]
        con.close()
        again = wd.text(".top .t small")
        check(before >= 2 and after == 0 and prog == 0 and again == fresh,
              f"start over: {before} -> {after} decisions, progress rows {prog}, back to '{again}' (" + wd.text("#toast") + ")")
        wd.go(app + f"#/day/{DAY}")

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
