"""Integration tests for the /m routes, against the real trial.db (read-only) with a throwaway
annotations.db, cache and state dir. Skipped when trial.db is missing. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import io
import json
import os
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
import uuid
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
TRIAL_DB = ROOT / "trial_out" / "trial.db"
DAY = "2026/2026-10-01"
from review.tests.helpers import FakePC, anno_connection, require_nas  # noqa: E402


@unittest.skipUnless(TRIAL_DB.exists(), "needs trial_out/trial.db")
class MobileApi(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from flask import Flask
        import mobile
        import photo_cull as pc
        cls.tmp = tempfile.TemporaryDirectory()
        tmp = Path(cls.tmp.name)

        def db_ro():
            con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            return con

        def anno():
            return anno_connection(tmp / "annotations.db")

        (tmp / "static").mkdir()
        (tmp / "inbox").mkdir()          # Send writes cull-decisions.tsv here
        (tmp / "static" / "index.html").write_text("<!doctype html><title>Culling Bay</title>")
        app = Flask(__name__)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=db_ro, anno=anno, pc=pc, cache_dir=tmp, static_dir=tmp / "static", state_dir=tmp / "state",
            inbox=tmp / "inbox", check_mount=False, ingest_log=tmp / "ingest.log",
            ollama_url="http://127.0.0.1:9"))   # nothing listens there: Ollama "not answering"
        cls.log = tmp / "ingest.log"
        cls.inbox = tmp / "inbox"
        cls.anno_path = tmp / "annotations.db"
        cls.db_ro = staticmethod(db_ro)
        cls.anno = staticmethod(anno)
        cls.client = app.test_client()
        cls.state_dir = tmp / "state"

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_app_shell(self):
        r = self.client.get("/m/")
        self.assertEqual(r.status_code, 200)
        self.assertIn(b"Culling Bay", r.data)
        r.close()

    def test_days_newest_first(self):
        days = self.client.get("/m/api/days").get_json()["days"]
        self.assertGreater(len(days), 300)
        dated = [d["date"] for d in days if d["date"]]
        self.assertEqual(dated, sorted(dated, reverse=True))
        d = next(d for d in days if d["day"] == DAY)
        self.assertEqual(d["frames"], 32)
        self.assertEqual(d["decided"], 0)
        self.assertEqual(len(d["thumbs"]), 3)
        self.assertIn("place", d)          # filled once photo_cull.py geotag has run
        self.assertIn("lr_done", d)
        self.assertIn("summary", d)        # filled once photo_cull.py daysum has run

    def test_day_stacks(self):
        body = self.client.get(f"/m/api/day/{DAY}").get_json()
        st = body["stacks"]
        self.assertEqual(sum(len(s["frames"]) for s in st), 32)
        by_file = {f["file"]: s for s in st for f in s["frames"]}
        bracket = by_file["DSC05040.ARW"]
        self.assertEqual(bracket["kind"], "bracket")
        lead = next(f for f in bracket["frames"] if f["id"] == bracket["lead"])
        self.assertEqual(lead["file"], "DSC05040.ARW")          # the normal exposure, not the brightest
        # DSC05036 was its own press: the camera's sequence numbers split it from the burst after it,
        # which the 2-second gap rule had joined
        self.assertEqual(by_file["DSC05036.ARW"]["kind"], "single")
        burst = by_file["DSC05037.ARW"]
        self.assertEqual(burst["kind"], "burst")
        self.assertEqual(len(burst["frames"]), 3)
        lead = next(f for f in burst["frames"] if f["id"] == burst["lead"])
        self.assertEqual(lead["file"], "DSC05039.ARW")          # sharpness 445, the burst's highest
        five = by_file["DSC05051.ARW"]                          # numbered 1, 2, 3, 2, 5 by the camera
        self.assertEqual((five["kind"], len(five["frames"])), ("bracket", 5))
        self.assertEqual(len(st), 16)
        self.assertTrue(all(f["af"] and 0 <= f["af"][0] <= 1 for s in st for f in s["frames"]))
        self.assertIsNone(body["progress"])
        self.assertEqual(body["budget"], {"stacks": 5, "per_hour": 10, "hours": 0.19})   # an 11-minute shoot
        self.assertTrue(all(f["decision"] is None for s in st for f in s["frames"]))
        self.assertNotIn("path", st[0]["frames"][0])            # library paths stay on the server

    def test_a_small_day_never_asks_to_keep_more_stacks_than_it_has(self):
        small = [d for d in self.client.get("/m/api/days").get_json()["days"] if 0 < d["stacks"] < 5]
        if not small:
            self.skipTest("no day with fewer than five stacks in this library")
        for d in small[:6]:
            with self.subTest(d["day"]):
                body = self.client.get(f"/m/api/day/{d['day']}").get_json()
                self.assertEqual(len(body["stacks"]), d["stacks"])
                self.assertEqual(body["budget"]["stacks"], d["stacks"])   # not the floor of 5

    H = {"X-Culling-Bay": "1"}

    def need_nas(self, *rowids):
        """Skip the running test unless the NAS holds these photos (a real RAW decode or file read)."""
        con = self.db_ro()
        try:
            paths = [con.execute("SELECT path FROM images WHERE rowid=?", (i,)).fetchone()[0] for i in rowids]
        finally:
            con.close()
        require_nas(self, *paths)

    def frames(self):
        body = self.client.get(f"/m/api/day/{DAY}").get_json()
        return {f["file"]: f for s in body["stacks"] for f in s["frames"]}, body

    @property
    def practice_file(self):
        return self.state_dir / "practice.json"

    def practice_challenge(self, cid="test-light", path=None):
        if path is None:
            con = self.db_ro()
            try:
                path = con.execute("SELECT path FROM images WHERE filename='DSC05040.ARW' AND path LIKE ?",
                                   (f"%/{DAY}/%",)).fetchone()[0]
            finally:
                con.close()
        return {"id": cid, "path": path, "title": "Test lantern", "mode": "phone", "minutes": 10,
                "tools": ["Color › Mix", "Crop"], "aim": "Keep the light warm.", "why": "One clear light source.",
                "hints": ["Start with the light."], "level": "easy", "picked_by": "Claude", "added": "2026-11-21"}

    def write_practice(self, challenges):
        self.practice_file.write_text(json.dumps({"challenges": challenges}), encoding="utf-8")

    def clear_practice(self):
        self.practice_file.unlink(missing_ok=True)

    def test_writes_need_the_header(self):
        r = self.client.post("/m/api/decide", json={"action_id": "x", "day": DAY, "changes": []})
        self.assertEqual(r.status_code, 403)
        r = self.client.post("/m/api/decide", data="{}", headers=self.H)   # not JSON
        self.assertEqual(r.status_code, 403)

    def test_decide_replay_and_undo(self):
        fr, _ = self.frames()
        a, b = fr["DSC05049.ARW"]["id"], fr["DSC05050.ARW"]["id"]
        note = "Burst reject \u00b7 kept DSC05050"
        body = {"action_id": "t-keep", "day": DAY, "label": "Kept DSC05050",
                "changes": [{"id": b, "flag": "pick", "via": "card"},
                            {"id": a, "flag": "reject", "note": note, "via": "card"}]}
        self.assertTrue(self.client.post("/m/api/decide", json=body, headers=self.H).get_json()["ok"])
        self.assertTrue(self.client.post("/m/api/decide", json=body, headers=self.H).get_json()["replay"])
        fr, _ = self.frames()
        self.assertEqual(fr["DSC05049.ARW"]["decision"]["flag"], "reject")
        self.assertEqual(fr["DSC05049.ARW"]["decision"]["note"], note)
        self.assertEqual(fr["DSC05050.ARW"]["decision"]["state"], "draft")
        # a second action over the first, then undo it: back to the first action's rows exactly
        body2 = {"action_id": "t-rescue", "day": DAY, "label": "Rescued",
                 "changes": [{"id": a, "flag": "pick", "via": "rescue"}]}
        self.client.post("/m/api/decide", json=body2, headers=self.H)
        self.assertEqual(self.frames()[0]["DSC05049.ARW"]["decision"]["flag"], "pick")
        self.client.post("/m/api/undo", json={"action_id": "t-rescue"}, headers=self.H)
        self.assertEqual(self.frames()[0]["DSC05049.ARW"]["decision"]["note"], note)
        self.client.post("/m/api/undo", json={"action_id": "t-keep"}, headers=self.H)
        fr, _ = self.frames()
        self.assertIsNone(fr["DSC05049.ARW"]["decision"])
        self.assertIsNone(fr["DSC05050.ARW"]["decision"])

    def test_decide_rejects_bad_input(self):
        fr, _ = self.frames()
        x = fr["DSC05061.ARW"]["id"]
        bad = [{"id": x, "flag": "maybe", "via": "card"}, {"id": x, "flag": "pick", "via": "nope"},
               {"id": 10 ** 9, "flag": "pick", "via": "card"}]
        for c in bad:
            r = self.client.post("/m/api/decide", json={"action_id": "bad", "day": DAY, "changes": [c]}, headers=self.H)
            self.assertEqual(r.status_code, 400, c)
        r = self.client.post("/m/api/decide", json={"action_id": "bad2", "day": "2026/other", "changes": [
            {"id": x, "flag": "pick", "via": "card"}]}, headers=self.H)
        self.assertEqual(r.status_code, 400)

    def test_progress_with_odd_numbers_today(self):
        """Documents what the route does now, not what it should do (server.md "Input validation", card
        D3, not chosen): a float, NaN or non-integer is a clean 400, but an integer past SQLite's range
        is a 500 with an HTML body. If the range check is added, these three become 400s."""
        url = f"/m/api/day/{DAY}/progress"
        for cursor in (float("nan"), 1.5, "7", True):
            with self.subTest(cursor=cursor):
                r = self.client.put(url, json={"pass": 1, "cursor": cursor}, headers=self.H)
                self.assertEqual(r.status_code, 400)
                self.assertIn("error", r.get_json())
        logger = self.client.application.logger.name
        for body in ({"pass": 1, "cursor": 2 ** 70}, {"pass": 1, "cursor": 0, "lead": 2 ** 70},
                     {"pass": 1, "cursor": -2 ** 63 - 1}):
            with self.subTest(body=body), self.assertLogs(logger, "ERROR"):
                r = self.client.put(url, json=body, headers=self.H)
                self.assertEqual(r.status_code, 500)
                self.assertIsNone(r.get_json(silent=True), "an HTML error page, not the {error} JSON the app expects")

    def test_progress(self):
        r = self.client.put(f"/m/api/day/{DAY}/progress", json={"pass": 2, "cursor": 5}, headers=self.H)
        self.assertTrue(r.get_json()["ok"])
        self.assertEqual(self.frames()[1]["progress"], {"pass": 2, "cursor": 5})
        self.assertEqual(self.client.put(f"/m/api/day/{DAY}/progress", json={"pass": 3, "cursor": 0},
                                         headers=self.H).status_code, 400)

    def test_details_for_the_sheet(self):
        f = self.frames()[0]["DSC05036.ARW"]
        self.assertTrue(f["caption"])
        self.assertIn("lens", f)

    def test_crop(self):
        import rawpy
        from PIL import Image
        fid = self.frames()[0]["DSC05036.ARW"]["id"]
        self.need_nas(fid)
        with patch("rawpy.imread", wraps=rawpy.imread) as imread:      # counts real decodes
            r = self.client.get(f"/m/api/crop/{fid}?x=0.5&y=0.5&w=800&h=600")
            self.assertEqual(r.status_code, 200)
            self.assertEqual(Image.open(io.BytesIO(r.data)).size, (800, 600))
            self.assertTrue(r.headers["X-Crop-Box"].endswith("of 7968x5320"))
            r.close()
            r = self.client.get(f"/m/api/crop/{fid}?x=1&y=0&w=5000&h=400")   # clamped to the corner
            self.assertTrue(r.headers["X-Crop-Box"].startswith("5568,0,2400,400"), r.headers["X-Crop-Box"])
            r.close()
            # a count, not a stopwatch: the second crop must come from the first one's decode
            self.assertEqual(imread.call_count, 1, "the second crop should reuse the decode")
        self.assertEqual(self.client.get(f"/m/api/crop/{fid}").status_code, 400)

    def test_gps_health(self):
        g = self.client.get("/m/api/gps-health").get_json()
        self.assertIn(g["status"], ("ok", "warn", "bad", "pending"))
        self.assertLessEqual(len(g["recent"]), 5)
        self.assertEqual(g["recent"], sorted(g["recent"], key=lambda d: d["last_ts"], reverse=True))
        self.assertIn("Location Information Link", g["advice"])

    def test_unknown_day(self):
        self.assertEqual(self.client.get("/m/api/day/2026/nope").status_code, 404)

    def test_image(self):
        from PIL import Image
        body = self.client.get(f"/m/api/day/{DAY}").get_json()
        rowid = body["stacks"][0]["lead"]
        self.need_nas(rowid)
        r = self.client.get(f"/m/api/img/{rowid}?s=thumb")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.mimetype, "image/jpeg")
        self.assertEqual(max(Image.open(io.BytesIO(r.data)).size), 320)
        r.close()

    def test_gallery_day_one_per_stack_in_time_order(self):
        body = self.client.get(f"/m/api/gallery/day/{DAY}").get_json()
        photos = body["photos"]
        self.assertEqual(len(photos), 16)                       # one per stack
        ts = [p["ts"] for p in photos]
        self.assertEqual(ts, sorted(ts))
        self.assertTrue(all(p["raw"] and p["date"] == "2026-10-01" for p in photos))
        self.assertNotIn("path", photos[0])
        every = self.client.get(f"/m/api/gallery/day/{DAY}?bursts=0").get_json()["photos"]
        self.assertEqual(len(every), 32)
        self.assertEqual(self.client.get("/m/api/gallery/day/1999/nope").status_code, 404)

    def test_gallery_search_by_file_name(self):
        body = self.client.get("/m/api/gallery/search?q=DSC05040").get_json()
        # camera file numbers wrap, so the same name turns up on other days too
        self.assertEqual({p["file"] for p in body["photos"]}, {"DSC05040.ARW"})
        self.assertIn("2026-10-01", [p["date"] for p in body["photos"]])
        self.assertEqual(body["signals"], ["words"])
        self.assertEqual(self.client.get("/m/api/gallery/search").status_code, 400)

    def test_gallery_best_needs_a_pick_or_three_stars(self):
        lead = self.client.get(f"/m/api/gallery/day/{DAY}").get_json()["photos"][0]
        self.assertFalse(lead["picked"])
        none = self.client.get(f"/m/api/gallery/day/{DAY}?best=1").get_json()["photos"]
        self.assertNotIn(lead["id"], [p["id"] for p in none])

    def test_export_carries_the_capture_time(self):
        from PIL import Image
        lead = self.client.get(f"/m/api/gallery/day/{DAY}").get_json()["photos"][0]
        self.need_nas(lead["id"])
        r = self.client.get(f"/m/api/export/{lead['id']}?s=large&dl=1")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.mimetype, "image/jpeg")
        self.assertTrue(r.headers["Content-Disposition"].startswith("attachment;"))
        self.assertIn(Path(lead["file"]).stem + ".jpg", r.headers["Content-Disposition"])
        im = Image.open(io.BytesIO(r.data))
        self.assertEqual(max(im.size), 3000)
        self.assertTrue(im.getexif().get_ifd(0x8769)[36867].startswith("2026:10:01 "))
        r.close()
        self.assertEqual(self.client.get("/m/api/export/999999999").status_code, 404)

    def test_export_of_a_jpeg_is_the_original_file(self):
        con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
        try:
            rowid, path = con.execute("SELECT rowid, path FROM images WHERE status='ok' AND lower(path) LIKE '%.jpg' "
                                      "LIMIT 1").fetchone()
        finally:
            con.close()
        require_nas(self, path)
        r = self.client.get(f"/m/api/export/{rowid}")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data, Path(path).read_bytes())
        r.close()

    def test_export_original_raw_is_a_download_of_the_file(self):
        lead = self.client.get(f"/m/api/gallery/day/{DAY}").get_json()["photos"][0]
        self.need_nas(lead["id"])
        self.assertTrue(lead["raw"])
        self.assertGreater(lead["bytes"], 1_000_000)
        r = self.client.get(f"/m/api/export/{lead['id']}?s=original")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.headers["Content-Disposition"].startswith("attachment;"))
        self.assertIn(lead["file"], r.headers["Content-Disposition"])
        self.assertEqual(len(r.data), lead["bytes"])
        r.close()

    def test_phone_timing_reports(self):
        r = self.client.post("/m/api/perf", json={"items": [{"type": "viewer_photo", "ms": 300}]}, headers=self.H)
        self.assertEqual(r.get_json(), {"logged": 1})
        self.assertEqual(self.client.post("/m/api/perf", json={"items": "x"}, headers=self.H).status_code, 400)
        self.assertEqual(self.client.post("/m/api/perf", json={"items": []}).status_code, 403)

    # --------------------------------------------------------------- Practice
    def test_practice_list_without_file(self):
        self.clear_practice()
        body = self.client.get("/m/api/practice").get_json()
        self.assertEqual(body, {"challenges": [], "missing": 0})

    def test_practice_malformed_file_is_safe(self):
        self.practice_file.write_text('{"challenges": ["/private/path', encoding="utf-8")
        body = self.client.get("/m/api/practice").get_json()
        self.assertEqual(body["challenges"], [])
        self.assertNotIn("missing", body)
        self.assertEqual(body["error"], "practice.json is malformed")
        self.assertNotIn("/private/path", str(body))

    def test_practice_missing_path_and_order(self):
        a = self.practice_challenge("third", path=None)
        b = self.practice_challenge("missing", path="/path/not/in/the/library.ARW")
        c = self.practice_challenge("first", path=a["path"])
        self.write_practice([a, b, c])
        body = self.client.get("/m/api/practice").get_json()
        self.assertEqual(body["missing"], 1)
        self.assertEqual([x["id"] for x in body["challenges"]], ["third", "first"])
        self.assertNotIn("path", body["challenges"][0])
        self.assertEqual(body["challenges"][0]["photo"]["file"], "DSC05040.ARW")

    def desktop_pair(self, parent_path=None, companion_path=None):
        parent = self.practice_challenge("aurora", path=parent_path)
        parent.update(mode="mac", needs_desktop=True, desktop_reason="Uses Enhance › Denoise.")
        companion = self.practice_challenge("aurora-phone", path=companion_path or parent["path"])
        companion["companion_of"] = "aurora"
        return parent, companion

    def test_practice_desktop_fields_default_when_absent(self):
        self.write_practice([self.practice_challenge()])
        self.addCleanup(self.clear_practice)
        c = self.client.get("/m/api/practice").get_json()["challenges"][0]
        self.assertIs(c["needs_desktop"], False)
        self.assertIsNone(c["desktop_reason"])
        self.assertIsNone(c["companion_of"])
        self.assertEqual(c["companions"], [])

    def test_practice_desktop_pair(self):
        parent, companion = self.desktop_pair()
        self.write_practice([parent, companion, self.practice_challenge("plain", path=parent["path"])])
        self.addCleanup(self.clear_practice)
        body = self.client.get("/m/api/practice").get_json()
        got = {c["id"]: c for c in body["challenges"]}
        self.assertEqual([c["id"] for c in body["challenges"]], ["aurora", "aurora-phone", "plain"])
        self.assertIs(got["aurora"]["needs_desktop"], True)
        self.assertEqual(got["aurora"]["desktop_reason"], "Uses Enhance › Denoise.")
        self.assertIsNone(got["aurora"]["companion_of"])
        self.assertEqual(got["aurora"]["companions"], ["aurora-phone"])
        self.assertIs(got["aurora-phone"]["needs_desktop"], False)
        self.assertIsNone(got["aurora-phone"]["desktop_reason"])
        self.assertEqual(got["aurora-phone"]["companion_of"], "aurora")
        self.assertEqual(got["aurora-phone"]["companions"], [])
        self.assertEqual(got["plain"]["companions"], [])
        # each member keeps its own status and note
        url = "/m/api/practice/aurora-phone"
        self.client.post(url, json={"status": "done", "note": "Phone pass."}, headers=self.H)
        got = {c["id"]: c for c in self.client.get("/m/api/practice").get_json()["challenges"]}
        self.assertEqual((got["aurora-phone"]["status"], got["aurora-phone"]["note"]), ("done", "Phone pass."))
        self.assertEqual((got["aurora"]["status"], got["aurora"]["note"]), ("todo", ""))

    def test_practice_companion_link_nulled_when_a_photo_is_missing(self):
        gone = "/path/not/in/the/library.ARW"
        # the parent's photo is missing: the companion stands alone
        parent, companion = self.desktop_pair(parent_path=gone, companion_path=self.practice_challenge()["path"])
        self.write_practice([parent, companion])
        self.addCleanup(self.clear_practice)
        body = self.client.get("/m/api/practice").get_json()
        self.assertEqual(body["missing"], 1)
        self.assertEqual([c["id"] for c in body["challenges"]], ["aurora-phone"])
        self.assertIsNone(body["challenges"][0]["companion_of"])
        self.assertEqual(body["challenges"][0]["companions"], [])
        # the companion's photo is missing: the parent lists no companions
        parent, companion = self.desktop_pair(companion_path=gone)
        companion["title"] = "Second file, a different size"   # practice.json is re-read when its mtime or size changes
        self.write_practice([parent, companion])
        body = self.client.get("/m/api/practice").get_json()
        self.assertEqual(body["missing"], 1)
        self.assertEqual([c["id"] for c in body["challenges"]], ["aurora"])
        self.assertEqual(body["challenges"][0]["companions"], [])
        self.assertIs(body["challenges"][0]["needs_desktop"], True)

    def test_practice_desktop_file_rules(self):
        self.addCleanup(self.clear_practice)

        def case(name, mutate):
            parent, companion = self.desktop_pair()
            others = mutate(parent, companion)
            self.write_practice([parent, companion] + (others if isinstance(others, list) else []))
            body = self.client.get("/m/api/practice").get_json()
            with self.subTest(name):
                self.assertEqual(body["challenges"], [])
                self.assertEqual(body["error"], "practice.json is malformed")
                self.assertNotIn("missing", body)

        case("needs_desktop not a bool", lambda p, c: p.update(needs_desktop="yes"))
        case("needs_desktop null", lambda p, c: p.update(needs_desktop=None))
        case("desktop_reason not a string", lambda p, c: p.update(desktop_reason=5))
        case("companion_of not a string", lambda p, c: c.update(companion_of=["aurora"]))
        case("companion_of unknown id", lambda p, c: c.update(companion_of="nope"))
        case("companion_of itself", lambda p, c: c.update(companion_of="aurora-phone"))
        case("parent not needs_desktop", lambda p, c: p.update(needs_desktop=False))
        case("parent without needs_desktop", lambda p, c: p.pop("needs_desktop"))
        case("parent is itself a companion", lambda p, c: p.update(companion_of="aurora-phone"))
        case("companion needs desktop", lambda p, c: c.update(needs_desktop=True))
        case("companion of a companion",
             lambda p, c: [dict(self.practice_challenge("second", path=p["path"]), companion_of="aurora-phone")])

    def test_practice_lightroom_passes_through_and_is_optional(self):
        self.addCleanup(self.clear_practice)
        lr = {"albums": ["Sun Peaks", "3+", "Picked"], "find_in": "Sun Peaks", "captured": "2025-01-18T13:13:02",
              "edited": True, "checked": "2026-11-25"}
        synced = dict(self.practice_challenge("synced"), lightroom=lr)
        local = dict(self.practice_challenge("local"),
                     lightroom={"albums": [], "find_in": None, "captured": None, "edited": False, "checked": "2026-11-25"})
        unknown = self.practice_challenge("unknown")
        self.write_practice([synced, local, unknown])
        body = self.client.get("/m/api/practice").get_json()
        by_id = {c["id"]: c for c in body["challenges"]}
        self.assertEqual(by_id["synced"]["lightroom"], lr)
        self.assertEqual(by_id["local"]["lightroom"]["albums"], [])
        self.assertNotIn("lightroom", by_id["unknown"])          # nobody checked: the app offers the download
        self.assertNotIn("path", by_id["synced"])

    def test_practice_lightroom_file_rules(self):
        self.addCleanup(self.clear_practice)
        good = {"albums": ["Picked"], "find_in": "Picked", "captured": None, "edited": False, "checked": "2026-11-25"}

        def case(name, lr):
            self.write_practice([dict(self.practice_challenge(), lightroom=lr)])
            body = self.client.get("/m/api/practice").get_json()
            with self.subTest(name):
                self.assertEqual(body["challenges"], [])
                self.assertEqual(body["error"], "practice.json is malformed")

        case("not an object", ["Picked"])
        case("albums not a list", dict(good, albums="Picked"))
        case("album not a string", dict(good, albums=["Picked", 3]))
        case("find_in not one of the albums", dict(good, find_in="Edited"))
        case("edited missing", {k: v for k, v in good.items() if k != "edited"})
        case("edited not a bool", dict(good, edited="yes"))
        case("checked missing", {k: v for k, v in good.items() if k != "checked"})
        case("captured not a string", dict(good, captured=20250118))

    def test_practice_table_created_in_fresh_annotations_db(self):
        import mobile
        import photo_cull as pc
        from flask import Flask

        fresh_db = self.state_dir / "fresh-annotations.db"
        fresh_state = self.state_dir / "fresh-state"

        def fresh_anno():
            con = sqlite3.connect(fresh_db)
            con.row_factory = sqlite3.Row
            return con

        app = Flask(__name__)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=self.db_ro, anno=fresh_anno, pc=pc, cache_dir=self.state_dir / "fresh-cache",
            static_dir=self.state_dir / "static", state_dir=fresh_state,
            inbox=self.inbox, check_mount=False, ingest_log=self.state_dir / "fresh-ingest.log",
            ollama_url="http://127.0.0.1:9"))
        self.assertEqual(app.test_client().get("/m/api/practice").status_code, 200)
        with sqlite3.connect(fresh_db) as con:
            columns = {r[1] for r in con.execute("PRAGMA table_info(practice_state)")}
        self.assertEqual(columns, {"id", "status", "note", "updated_at", "downloaded_at", "done_at"})

    def test_practice_status_transitions_and_note(self):
        self.write_practice([self.practice_challenge(path="/not-in-library.ARW")])
        self.addCleanup(self.clear_practice)
        url = "/m/api/practice/test-light"

        downloaded = self.client.post(url, json={"status": "downloaded"}, headers=self.H).get_json()
        first_download = downloaded["downloaded_at"]
        self.assertEqual(downloaded["status"], "downloaded")
        self.assertIsNotNone(first_download)

        done = self.client.post(url, json={"status": "done", "note": "Warm light."}, headers=self.H).get_json()
        first_done = done["done_at"]
        self.assertEqual((done["status"], done["note"]), ("done", "Warm light."))
        self.assertIsNotNone(first_done)

        redownload = self.client.post(url, json={"status": "downloaded"}, headers=self.H).get_json()
        self.assertEqual(redownload["status"], "done")
        self.assertEqual(redownload["done_at"], first_done)
        self.assertEqual(redownload["downloaded_at"], first_download)

        noted = self.client.post(url, json={"note": "Less yellow next time."}, headers=self.H).get_json()
        self.assertEqual((noted["status"], noted["note"], noted["done_at"]),
                         ("done", "Less yellow next time.", first_done))
        skipped = self.client.post(url, json={"status": "skipped"}, headers=self.H).get_json()
        self.assertEqual(skipped["status"], "skipped")
        self.assertIsNone(skipped["done_at"])
        waiting = self.client.post(url, json={"status": "todo"}, headers=self.H).get_json()
        self.assertEqual(waiting["status"], "todo")
        self.assertIsNone(waiting["done_at"])
        self.assertEqual(waiting["downloaded_at"], first_download)

    def test_practice_write_validation_and_unknown_challenge(self):
        self.write_practice([self.practice_challenge(path="/not-in-library.ARW")])
        self.addCleanup(self.clear_practice)
        url = "/m/api/practice/test-light"
        self.assertEqual(self.client.post(url, json={}, headers=self.H).status_code, 400)
        self.assertEqual(self.client.post(url, json={"status": "finished"}, headers=self.H).status_code, 400)
        self.assertEqual(self.client.post(url, json={"status": ["done"]}, headers=self.H).status_code, 400)
        self.assertEqual(self.client.post(url, json={"note": 42}, headers=self.H).status_code, 400)
        self.assertEqual(self.client.post(url, json={"note": "x" * 2001}, headers=self.H).status_code, 400)
        self.assertEqual(self.client.post(url, json={"status": "todo", "extra": True}, headers=self.H).status_code, 400)
        self.assertEqual(self.client.post("/m/api/practice/no-such-id", json={"status": "done"},
                                          headers=self.H).status_code, 404)
        self.assertEqual(self.client.post(url, json={"status": "done"}).status_code, 403)

    # ------------------------------------------------ the contract the iPhone app relies on (review/API.md)
    def assert_shape(self, obj, shape, where):
        """shape: {field: type, a tuple of types, or (type, None) when the field can be null}"""
        for k, t in shape.items():
            self.assertIn(k, obj, f"{where}: missing {k}")
            nullable = isinstance(t, tuple) and t[-1] is None
            t = t[0] if nullable else t
            v = obj[k]
            if v is None:
                self.assertTrue(nullable, f"{where}.{k} is null but the contract says it can't be")
            else:
                types = t if isinstance(t, tuple) else (t,)
                ok = isinstance(v, types) and not (isinstance(v, bool) and bool not in types)
                self.assertTrue(ok, f"{where}.{k}: {type(v).__name__}, expected {t}")

    DAY = {"day": str, "folder": str, "date": (str, None), "frames": int, "stacks": int, "thumbs": list,
           "last_ts": (int, float), "place": (str, None), "places": list, "gps_frames": int,
           "summary": (str, None), "decided": int, "sent": int, "landed": int, "conflicts": int,
           "lr_done": int, "finished": bool, "sent_at": (str, None), "unsent": int}
    PHOTO = {"id": int, "day": str, "date": (str, None), "ts": ((int, float), None), "file": str,
             "bytes": (int, None), "camera": (str, None), "lens": (str, None), "caption": (str, None),
             "place": (str, None), "stars": int, "picked": bool, "rejected": bool, "raw": bool}

    def test_contract_days(self):
        days = self.client.get("/m/api/days").get_json()["days"]
        for d in days[:50]:
            self.assert_shape(d, self.DAY, "Day")

    def test_contract_gallery(self):
        day = self.client.get(f"/m/api/gallery/day/{DAY}").get_json()
        self.assert_shape(day, {"day": str, "date": (str, None), "summary": (str, None), "photos": list}, "GalleryDay")
        for p in day["photos"]:
            self.assert_shape(p, self.PHOTO, "Photo")
        found = self.client.get("/m/api/gallery/search?q=DSC05040").get_json()
        self.assert_shape(found, {"query": str, "total": int, "signals": list, "notes": list, "photos": list}, "Search")
        for p in found["photos"]:
            self.assert_shape(p, self.PHOTO, "Photo")
        like = self.client.get(f"/m/api/gallery/like/{day['photos'][0]['id']}").get_json()
        self.assert_shape(like, {"total": int, "signals": list, "notes": list, "photos": list}, "Like")

    def test_contract_practice(self):
        self.write_practice([self.practice_challenge()])
        self.addCleanup(self.clear_practice)
        body = self.client.get("/m/api/practice").get_json()
        self.assert_shape(body, {"challenges": list, "missing": int}, "Practice")
        challenge = body["challenges"][0]
        self.assert_shape(challenge, {"id": str, "title": str, "mode": str, "minutes": int, "tools": list,
                                     "aim": str, "why": str, "hints": list, "level": str, "picked_by": str,
                                     "added": str, "photo": dict, "status": str, "note": str,
                                     "updated_at": (str, None), "downloaded_at": (str, None), "done_at": (str, None),
                                     "needs_desktop": bool, "desktop_reason": (str, None),
                                     "companion_of": (str, None), "companions": list},
                          "PracticeChallenge")
        self.assert_shape(challenge["photo"], self.PHOTO, "PracticePhoto")
        self.assertNotIn("path", challenge)
        saved = self.client.post("/m/api/practice/test-light", json={"status": "downloaded"}, headers=self.H).get_json()
        self.assert_shape(saved, {"ok": bool, "id": str, "status": str, "note": str,
                                  "updated_at": str, "downloaded_at": str, "done_at": (str, None)},
                          "PracticeState")

    # ------------------------------------------------ the Cull half of the contract
    STACK = {"id": int, "kind": str, "lead": int, "frames": list}
    FRAME = {"id": int, "file": str, "partners": list, "partner_ids": list, "sharpness": ((int, float), None),
             "af": (list, None), "badges": list, "lr": (dict, None), "decision": (dict, None),
             "lens": (str, None), "caption": (str, None), "blown_pct": ((int, float), None),
             "mean_lum": ((int, float), None), "place": (str, None)}
    LR = {"pick": int, "rating": int, "by": str, "stars_by": str}
    DECISION = {"flag": str, "stars": (int, None), "note": str, "state": str, "outcome": (str, None)}
    BUDGET = {"stacks": int, "per_hour": int, "hours": (int, float)}
    PROGRESS = {"pass": int, "cursor": int}
    CULL_DAY = {"day": str, "folder": str, "date": (str, None), "summary": (str, None), "budget": dict,
                "stacks": list, "progress": (dict, None)}
    DAY_MATCH = {"day": str, "n": int, "ids": list, "match_ids": list, "why": str}
    KINDS = {"single", "burst", "bracket", "pano"}
    BADGES = {"Blown", "Dark", "Softer"}

    def wipe(self):
        """Back to a day with no phone state, whatever a test left behind (and out of the inbox)."""
        con = sqlite3.connect(self.anno_path)
        try:
            for t in ("cull_decisions", "cull_days", "cull_receipts", "lr_state"):
                try:
                    con.execute(f"DELETE FROM {t}")
                except sqlite3.OperationalError:    # the table appears with the first API call
                    pass
            con.commit()
        finally:
            con.close()
        (self.inbox / "cull-decisions.tsv").unlink(missing_ok=True)
        for f in (self.inbox / "applied").glob("*"):
            f.unlink()

    def test_contract_cull_day(self):
        self.addCleanup(self.wipe)
        trial = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
        try:
            path = trial.execute("SELECT path FROM images WHERE filename='DSC05040.ARW' AND path LIKE ?",
                                 (f"%/{DAY}/%",)).fetchone()[0]
        finally:
            trial.close()
        self.client.get(f"/m/api/day/{DAY}")                       # creates the cull_* tables
        con = sqlite3.connect(self.anno_path)
        con.execute("INSERT INTO lr_state(path, day, pick, rating, flag_by, stars_by, seen_at) "
                    "VALUES (?,?,?,?,?,?,?)", (path, DAY, -1, 2, "you", "phone", "2026-10-02T09:00:00"))
        con.commit()
        con.close()
        body = self.client.get(f"/m/api/day/{DAY}").get_json()
        self.assert_shape(body, self.CULL_DAY, "CullDay")
        self.assertEqual((body["day"], body["folder"], body["date"]), (DAY, "2026-10-01", "2026-10-01"))
        self.assert_shape(body["budget"], self.BUDGET, "Budget")
        if body["progress"] is not None:
            self.assert_shape(body["progress"], self.PROGRESS, "Progress")
        kinds, lrs = set(), []
        for i, s in enumerate(body["stacks"]):
            self.assert_shape(s, self.STACK, "Stack")
            self.assertEqual(s["id"], i)                           # a stack's id is its position
            self.assertIn(s["kind"], self.KINDS)
            kinds.add(s["kind"])
            self.assertIn(s["lead"], [f["id"] for f in s["frames"]])
            self.assertEqual(s["kind"] == "single", len(s["frames"]) == 1)
            for f in s["frames"]:
                self.assert_shape(f, self.FRAME, "Frame")
                self.assertTrue(set(f["badges"]) <= self.BADGES, f["badges"])
                self.assertLessEqual(len(f["badges"]), 1)
                self.assertEqual(len(f["partners"]), len(f["partner_ids"]))
                if f["af"] is not None:
                    self.assertEqual(len(f["af"]), 2)
                if f["lr"] is not None:
                    self.assert_shape(f["lr"], self.LR, "Lr")
                    lrs.append(f)
        self.assertEqual(kinds, {"single", "burst", "bracket"})
        self.assertEqual([f["file"] for f in lrs], ["DSC05040.ARW"])
        self.assertEqual(lrs[0]["lr"], {"pick": -1, "rating": 2, "by": "you", "stars_by": "phone"})

    def test_contract_cull_search(self):
        found = self.client.get("/m/api/search?q=DSC05040").get_json()
        self.assert_shape(found, {"query": str, "days": list, "photos": int, "signals": list, "notes": list}, "DaySearch")
        self.assertEqual(found["query"], "DSC05040")
        self.assertEqual(found["signals"], ["words"])
        for d in found["days"]:
            self.assert_shape(d, self.DAY_MATCH, "DayMatch")
            self.assertLessEqual(len(d["ids"]), 4)
            self.assertEqual(d["ids"], d["match_ids"][:4])
        hit = next(d for d in found["days"] if d["day"] == DAY)
        self.assertGreaterEqual(hit["n"], 1)
        self.assertIn(self.frames()[0]["DSC05040.ARW"]["id"], hit["match_ids"])
        # only dates: the days in that span, with nothing matched inside them
        dated = self.client.get("/m/api/search?q=2026-10-01").get_json()
        self.assertEqual(dated["signals"], ["dates"])
        self.assertEqual(dated["photos"], 0)
        self.assertEqual([d["day"] for d in dated["days"]], [DAY])
        self.assertEqual(dated["days"][0], {"day": DAY, "n": 0, "ids": [], "match_ids": [], "why": ""})
        self.assertEqual(self.client.get("/m/api/search?q=%20").status_code, 400)
        self.assertEqual(self.client.get("/m/api/search?q=%20").get_json(), {"error": "missing q"})

    def test_contract_cull_like(self):
        fid = self.frames()[0]["DSC05036.ARW"]["id"]
        like = self.client.get(f"/m/api/like/{fid}").get_json()
        self.assert_shape(like, {"days": list, "photos": int, "signals": list, "notes": list}, "DayLike")
        self.assertNotIn("query", like)
        for d in like["days"]:
            self.assert_shape(d, self.DAY_MATCH, "DayMatch")
            self.assertNotEqual(d["day"], DAY)                      # its own day is the one you are in
        self.assertEqual(self.client.get("/m/api/like/999999999").status_code, 404)

    def test_contract_cull_write_round_trip(self):
        self.addCleanup(self.wipe)
        self.wipe()
        fr, _ = self.frames()
        a, b = fr["DSC05061.ARW"]["id"], fr["DSC05036.ARW"]["id"]
        post = lambda path, body: self.client.post(path, json=body, headers=self.H)

        # decide: stars are kept for a pick and dropped for a reject
        act = str(uuid.uuid4())
        body = {"action_id": act, "day": DAY, "label": "Kept DSC05061 ★ 4",
                "changes": [{"id": a, "flag": "pick", "stars": 4, "via": "card"},
                            {"id": b, "flag": "reject", "stars": 5, "note": "too soft", "via": "burst"}]}
        r = post("/m/api/decide", body)
        self.assertEqual((r.status_code, r.get_json()), (200, {"ok": True}))
        fr, day = self.frames()
        self.assert_shape(fr["DSC05061.ARW"]["decision"], self.DECISION, "Decision")
        self.assertEqual(fr["DSC05061.ARW"]["decision"],
                         {"flag": "pick", "stars": 4, "note": "", "state": "draft", "outcome": None})
        self.assertEqual(fr["DSC05036.ARW"]["decision"],
                         {"flag": "reject", "stars": None, "note": "too soft", "state": "draft", "outcome": None})
        # the same action_id again is acknowledged and ignored, whatever the body says
        again = dict(body, changes=[{"id": a, "flag": "none", "via": "card"}])
        self.assertEqual(post("/m/api/decide", body).get_json(), {"ok": True, "replay": True})
        self.assertEqual(post("/m/api/decide", again).get_json(), {"ok": True, "replay": True})
        self.assertEqual(self.frames()[0]["DSC05061.ARW"]["decision"]["flag"], "pick")

        # undo puts the rows back as they were: no decision at all
        self.assertEqual(post("/m/api/undo", {"action_id": act}).get_json(), {"ok": True})
        fr, _ = self.frames()
        self.assertIsNone(fr["DSC05061.ARW"]["decision"])
        self.assertIsNone(fr["DSC05036.ARW"]["decision"])
        self.assertEqual(post("/m/api/undo", {"action_id": act}).get_json(), {"ok": True, "replay": True})
        self.assertEqual(post("/m/api/decide", body).get_json(), {"ok": True, "replay": True})   # still seen
        self.assertIsNone(self.frames()[0]["DSC05061.ARW"]["decision"])
        r = post("/m/api/undo", {"action_id": "never-made"})
        self.assertEqual((r.status_code, r.get_json()), (404, {"error": "unknown action"}))

        # decide again under a new id, save progress, then send
        act2 = str(uuid.uuid4())
        post("/m/api/decide", dict(body, action_id=act2))
        r = self.client.put(f"/m/api/day/{DAY}/progress", json={"pass": 2, "cursor": 3, "finished": False}, headers=self.H)
        self.assertEqual((r.status_code, r.get_json()), (200, {"ok": True}))
        fr, day = self.frames()
        self.assertEqual(day["progress"], {"pass": 2, "cursor": 3})
        r = post(f"/m/api/day/{DAY}/send", {})
        sent = r.get_json()
        self.assertEqual((r.status_code, sent["ok"], sent["queued"]), (200, True, 2))
        self.assertGreaterEqual(sent["file_rows"], 2)               # pair partners ride along
        self.assertEqual(set(sent), {"ok", "queued", "file_rows"})
        fr, day = self.frames()
        self.assertEqual({fr["DSC05061.ARW"]["decision"]["state"], fr["DSC05036.ARW"]["decision"]["state"]}, {"queued"})
        self.assertEqual(day["progress"], {"pass": 2, "cursor": 3})  # Send keeps the position
        rows = (self.inbox / "cull-decisions.tsv").read_text().splitlines()
        self.assertEqual(rows[0], "#cull-decisions v1")
        self.assertIn("2026-10-01\tDSC05061.ARW\tpick\t4\t", "\n".join(rows))
        self.assertEqual(len(rows) - 1, sent["file_rows"])
        # nothing new: still ok, with zeros
        self.assertEqual(post(f"/m/api/day/{DAY}/send", {}).get_json(), {"ok": True, "queued": 0, "file_rows": 0})

        # reset clears the decisions, the position, and the rows waiting in the inbox
        r = post(f"/m/api/day/{DAY}/reset", {})
        self.assertEqual((r.status_code, r.get_json()), (200, {"ok": True, "cleared": 2, "withdrawn": sent["file_rows"]}))
        fr, day = self.frames()
        self.assertTrue(all(f["decision"] is None for f in fr.values()))
        self.assertIsNone(day["progress"])
        self.assertFalse((self.inbox / "cull-decisions.tsv").exists())
        self.assertEqual(post(f"/m/api/day/{DAY}/reset", {}).get_json(), {"ok": True, "cleared": 0, "withdrawn": 0})

    def test_send_several_days_at_once(self):
        self.addCleanup(self.wipe)
        self.wipe()
        other = "2026/2026-08-09"
        con = self.anno()
        try:
            for day in (DAY, other):
                path = self.db_ro().execute(
                    "SELECT path FROM images WHERE path LIKE ? AND lower(filename) LIKE '%.arw' ORDER BY rowid LIMIT 1",
                    (f"%/{day}/%",)).fetchone()[0]
                con.execute("INSERT INTO cull_decisions(path, day, flag, stars, note, via, decided_at, state) "
                            "VALUES (?,?,?,?,?,?,?,?)", (path, day, "pick", None, "", "test", "2026-11-23T00:00:00", "draft"))
            con.commit()
        finally:
            con.close()
        listed = {d["day"]: d for d in self.client.get("/m/api/days").get_json()["days"]}
        self.assertEqual((listed[DAY]["unsent"], listed[other]["unsent"]), (1, 1))
        r = self.client.post("/m/api/send", json={"days": [DAY, other, DAY]}, headers=self.H)
        body = r.get_json()
        self.assertEqual((r.status_code, body["ok"], body["queued"]), (200, True, 2))
        self.assertEqual(body["days"], [{"day": DAY, "queued": 1}, {"day": other, "queued": 1}])
        listed = {d["day"]: d for d in self.client.get("/m/api/days").get_json()["days"]}
        self.assertEqual((listed[DAY]["unsent"], listed[other]["unsent"]), (0, 0))
        self.assertTrue(listed[DAY]["sent_at"] and listed[other]["sent_at"])
        rows = (self.inbox / "cull-decisions.tsv").read_text()
        self.assertIn("2026-10-01\t", rows)
        self.assertIn("2026-08-09\t", rows)
        # bad bodies, an unknown day, and the header
        for bad in ({}, {"days": []}, {"days": "x"}, {"days": [1]}):
            self.assertEqual(self.client.post("/m/api/send", json=bad, headers=self.H).status_code, 400)
        r = self.client.post("/m/api/send", json={"days": [DAY, "1999/1999-01-01"]}, headers=self.H)
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self.client.post("/m/api/send", json={"days": [DAY]}).status_code, 403)

    def test_contract_cull_send_before_any_progress_leaves_progress_null(self):
        self.addCleanup(self.wipe)
        self.wipe()
        r = self.client.post(f"/m/api/day/{DAY}/send", json={}, headers=self.H)
        self.assertEqual(r.get_json(), {"ok": True, "queued": 0, "file_rows": 0})
        self.assertIsNone(self.frames()[1]["progress"])

    def test_contract_cull_progress_follows_path_when_stacks_change(self):
        import stacks
        self.addCleanup(self.wipe)
        self.wipe()
        day = self.frames()[1]
        target = day["stacks"][1]
        put = lambda body: self.client.put(f"/m/api/day/{DAY}/progress", json=body, headers=self.H)
        body = {"pass": 2, "cursor": target["id"], "lead": target["lead"]}
        self.assertEqual(put(body).get_json(), {"ok": True})
        with closing(self.db_ro()) as con:
            path = con.execute("SELECT path FROM images WHERE rowid=?", (target["lead"],)).fetchone()[0]
        with closing(self.anno()) as con, con:
            self.assertEqual(con.execute("SELECT cursor_path FROM cull_days WHERE day=?", (DAY,)).fetchone()[0], path)

        build = stacks.build_stacks
        def earlier_stack(rows, **kw):
            extra = dict(rows[0], rowid=-1, filename="earlier.JPG", path=f"/mnt/passport/Pictures/{DAY}/earlier.JPG",
                         capture_ts=min(r["capture_ts"] for r in rows) - 3600, seq=None, drive=None)
            return build([extra] + rows, **kw)
        with patch.object(stacks, "build_stacks", side_effect=earlier_stack):
            changed = self.frames()[1]
        self.assertEqual(len(changed["stacks"]), len(day["stacks"]) + 1)
        self.assertEqual(changed["progress"], {"pass": 2, "cursor": target["id"] + 1})
        self.assertEqual(changed["stacks"][changed["progress"]["cursor"]]["lead"], target["lead"])
        self.assertEqual([s["id"] for s in changed["stacks"]], list(range(len(changed["stacks"]))))

        # The saved photo can become a pair partner, or leave the response altogether.
        def as_partner(rows, **kw):
            result = build([r for r in rows if r["rowid"] != target["lead"]], **kw)
            result[-1]["frames"][0]["partners"].append(Path(path).name)
            result[-1]["frames"][0]["partner_ids"].append(target["lead"])
            return result
        with patch.object(stacks, "build_stacks", side_effect=as_partner):
            paired = self.frames()[1]
            self.assertEqual(paired["progress"]["cursor"], len(paired["stacks"]) - 1)
        with patch.object(stacks, "build_stacks", side_effect=lambda rows, **kw: build(
                [r for r in rows if r["rowid"] != target["lead"]], **kw)):
            self.assertEqual(self.frames()[1]["progress"], {"pass": 2, "cursor": target["id"]})

        # A later save from an old client replaces the anchor with its integer cursor.
        self.assertEqual(put({"pass": 1, "cursor": 4}).status_code, 200)
        self.assertEqual(self.frames()[1]["progress"], {"pass": 1, "cursor": 4})
        with closing(self.anno()) as con, con:
            self.assertIsNone(con.execute("SELECT cursor_path FROM cull_days WHERE day=?", (DAY,)).fetchone()[0])

    def test_contract_cull_progress_migrates_old_days_table(self):
        self.addCleanup(self.wipe)
        self.wipe()
        with closing(self.anno()) as con, con:
            con.execute("DROP TABLE IF EXISTS cull_days")
            con.execute("CREATE TABLE cull_days(day TEXT PRIMARY KEY, pass INTEGER, cursor INTEGER, "
                        "finished_at TEXT, sent_at TEXT)")
            con.execute("INSERT INTO cull_days VALUES (?, 2, 3, 'finished', 'sent')", (DAY,))
        for _ in range(2):
            self.assertEqual(self.frames()[1]["progress"], {"pass": 2, "cursor": 3})
        with closing(self.anno()) as con, con:
            row = dict(con.execute("SELECT * FROM cull_days WHERE day=?", (DAY,)).fetchone())
        self.assertEqual(row, {"day": DAY, "pass": 2, "cursor": 3, "cursor_path": None,
                               "finished_at": "finished", "sent_at": "sent"})
        lead = self.frames()[1]["stacks"][3]["lead"]
        r = self.client.put(f"/m/api/day/{DAY}/progress", json={"pass": 2, "cursor": 3, "lead": lead}, headers=self.H)
        self.assertEqual(r.status_code, 200)
        with closing(self.anno()) as con, con:
            self.assertIsInstance(con.execute("SELECT cursor_path FROM cull_days WHERE day=?", (DAY,)).fetchone()[0], str)

    def test_contract_cull_queued_decide_and_undo_withdraw_partners(self):
        import stacks
        self.addCleanup(self.wipe)
        self.wipe()
        frame = self.frames()[0]["DSC05061.ARW"]
        pair = stacks.pair_frames
        def paired(rows):
            frames = pair(rows)
            for f in frames:
                if f["rowid"] == frame["id"]:
                    f["partners"].append(dict(f, rowid=-1, filename="DSC05061.JPG",
                                               path=str(Path(f["path"]).with_suffix(".JPG"))))
            return frames
        post = lambda path, body: self.client.post(path, json=body, headers=self.H)
        action = str(uuid.uuid4())
        original = {"action_id": action, "day": DAY,
                    "changes": [{"id": frame["id"], "flag": "pick", "stars": 4, "via": "card"}]}
        inbox = self.inbox / "cull-decisions.tsv"
        other = "2026-09-29\tother.ARW\treject\t\t\n"
        with patch.object(stacks, "pair_frames", side_effect=paired):
            self.assertEqual(post("/m/api/decide", original).status_code, 200)
            self.assertEqual(post(f"/m/api/day/{DAY}/send", {}).get_json()["file_rows"], 2)
            inbox.write_text(inbox.read_text() + other)
            queued = inbox.read_bytes()
            self.assertIn(b"DSC05061.JPG", queued)
            # A retry never withdraws the original action's queued rows.
            self.assertEqual(post("/m/api/decide", original).get_json(), {"ok": True, "replay": True})
            self.assertEqual(inbox.read_bytes(), queued)

            second = str(uuid.uuid4())
            self.assertEqual(post("/m/api/decide", dict(original, action_id=second, changes=[
                {"id": frame["id"], "flag": "reject", "via": "card"}])).status_code, 200)
            self.assertEqual(inbox.read_text().splitlines()[1:], [other.rstrip("\n")])
            self.assertEqual(self.frames()[0][frame["file"]]["decision"]["state"], "draft")
            # Undoing the second decision restores the queued pick and both file rows.
            self.assertEqual(post("/m/api/undo", {"action_id": second}).get_json(), {"ok": True})
            self.assertEqual(set(inbox.read_text().splitlines()), set(queued.decode().splitlines()))
            self.assertEqual(self.frames()[0][frame["file"]]["decision"]["state"], "queued")
            self.assertEqual(post("/m/api/undo", {"action_id": action}).get_json(), {"ok": True})
            self.assertIsNone(self.frames()[0][frame["file"]]["decision"])
            self.assertEqual(inbox.read_text().splitlines()[1:], [other.rstrip("\n")])

            # A replayed undo must not withdraw a later action on the same photo.
            post("/m/api/decide", dict(original, action_id=str(uuid.uuid4())))
            post(f"/m/api/day/{DAY}/send", {})
            queued = inbox.read_bytes()
            self.assertEqual(post("/m/api/undo", {"action_id": action}).get_json(), {"ok": True, "replay": True})
            self.assertEqual(inbox.read_bytes(), queued)

    def test_contract_cull_undo_refuses_once_in_lightroom(self):
        self.addCleanup(self.wipe)
        frame = self.frames()[0]["DSC05061.ARW"]
        post = lambda path, body: self.client.post(path, json=body, headers=self.H)
        for outcome, state in (("applied", "landed"), ("your_flag_kept", "conflict")):
            with self.subTest(state=state):
                self.wipe()
                action = str(uuid.uuid4())
                post("/m/api/decide", {"action_id": action, "day": DAY,
                                      "changes": [{"id": frame["id"], "flag": "pick", "via": "card"}]})
                post(f"/m/api/day/{DAY}/send", {})
                applied = self.inbox / "applied"
                applied.mkdir(exist_ok=True)
                (applied / "20261001-120000-receipt.tsv").write_text(f"2026-10-01\tDSC05061.ARW\t{outcome}\n")
                before = self.cull_snapshot()
                r = post("/m/api/undo", {"action_id": action})   # undo itself reads the new receipt
                self.assertEqual(r.status_code, 409)
                self.assertEqual(set(r.get_json()), {"error", "applied"})
                self.assertEqual(r.get_json()["applied"], 1)
                self.assertIn("already in Lightroom", r.get_json()["error"])
                after = self.cull_snapshot()
                self.assertEqual(after[0]["cull_actions"], before[0]["cull_actions"])   # not marked undone
                self.assertEqual(after[1], before[1])                                   # inbox untouched
                decision = self.frames()[0][frame["file"]]["decision"]
                self.assertEqual((decision["flag"], decision["state"]), ("pick", state))

    def cull_snapshot(self):
        """Decisions, actions, progress and inbox, for assertions that failures change nothing."""
        with closing(self.anno()) as con, con:
            rows = {t: [dict(r) for r in con.execute(f"SELECT * FROM {t} ORDER BY rowid")]
                    for t in ("cull_decisions", "cull_actions", "cull_days")}
        inbox = self.inbox / "cull-decisions.tsv"
        return rows, inbox.read_bytes() if inbox.exists() else None

    def test_contract_cull_unavailable_inbox_keeps_decide_and_undo_unchanged(self):
        from flask import Flask
        import mobile
        self.addCleanup(self.wipe)
        self.wipe()
        frame = self.frames()[0]["DSC05061.ARW"]
        app = Flask(__name__)
        tmp = Path(self.tmp.name)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=self.db_ro, anno=self.anno, pc=None, cache_dir=tmp, static_dir=tmp, state_dir=tmp / "unmounted",
            inbox=self.inbox, check_mount=True))
        unavailable = app.test_client()   # this temp inbox is not a mount
        for method, route, body in (("put", "progress", {"pass": 2, "cursor": 0}),
                                     ("post", "send", {}), ("post", "reset", {})):
            r = getattr(unavailable, method)(f"/m/api/day/no-such-day/{route}", json=body, headers=self.H)
            self.assertEqual((r.status_code, r.get_json()), (404, {"error": "no such day"}))
        post = lambda path, body: self.client.post(path, json=body, headers=self.H)
        original = {"action_id": str(uuid.uuid4()), "day": DAY,
                    "changes": [{"id": frame["id"], "flag": "pick", "via": "card"}]}
        post("/m/api/decide", original)
        post(f"/m/api/day/{DAY}/send", {})
        second = dict(original, action_id=str(uuid.uuid4()))
        before = self.cull_snapshot()
        for path, body in (("/m/api/decide", second), ("/m/api/undo", {"action_id": original["action_id"]})):
            r = unavailable.post(path, json=body, headers=self.H)
            self.assertEqual(r.status_code, 503)
            self.assertIsInstance(r.get_json()["error"], str)
            self.assertEqual(self.cull_snapshot(), before)
        self.assertEqual(unavailable.post("/m/api/decide", json=original, headers=self.H).get_json(),
                         {"ok": True, "replay": True})
        self.assertEqual(self.cull_snapshot(), before)
        # Restoring a queued before-row also needs the inbox, even if the current row is draft.
        post("/m/api/decide", second)
        before = self.cull_snapshot()
        r = unavailable.post("/m/api/undo", json={"action_id": second["action_id"]}, headers=self.H)
        self.assertEqual(r.status_code, 503)
        self.assertEqual(self.cull_snapshot(), before)

    def test_contract_cull_progress_finished_sticks(self):
        self.addCleanup(self.wipe)
        self.wipe()
        put = lambda body: self.client.put(f"/m/api/day/{DAY}/progress", json=body, headers=self.H)
        put({"pass": 2, "cursor": 0, "finished": True})
        put({"pass": 1, "cursor": 4, "finished": False})
        self.assertEqual(self.frames()[1]["progress"], {"pass": 1, "cursor": 4})
        day = next(d for d in self.client.get("/m/api/days").get_json()["days"] if d["day"] == DAY)
        self.assertTrue(day["finished"])                            # finished: false does not take it back

    def test_contract_cull_reset_refuses_once_in_lightroom(self):
        self.addCleanup(self.wipe)
        self.wipe()
        fr, _ = self.frames()
        x = fr["DSC05061.ARW"]["id"]
        post = lambda path, body: self.client.post(path, json=body, headers=self.H)
        post("/m/api/decide", {"action_id": str(uuid.uuid4()), "day": DAY,
                               "changes": [{"id": x, "flag": "pick", "via": "card"}]})
        post(f"/m/api/day/{DAY}/send", {})
        applied = self.inbox / "applied"                            # what the plug-in leaves after a sync
        applied.mkdir(exist_ok=True)
        (applied / "20261001-120000-receipt.tsv").write_text("2026-10-01\tDSC05061.ARW\tapplied\n")
        fr, _ = self.frames()
        self.assertEqual(fr["DSC05061.ARW"]["decision"]["state"], "landed")
        r = post(f"/m/api/day/{DAY}/reset", {})
        self.assertEqual(r.status_code, 409)
        body = r.get_json()
        self.assertEqual(body["applied"], 1)
        self.assertIn("already in Lightroom", body["error"])
        self.assertEqual(self.frames()[0]["DSC05061.ARW"]["decision"]["state"], "landed")   # nothing was cleared

    def test_contract_cull_write_errors(self):
        self.addCleanup(self.wipe)
        self.wipe()
        fr, _ = self.frames()
        x = fr["DSC05061.ARW"]["id"]
        before = self.cull_snapshot()
        for method, path in (("post", "/m/api/decide"), ("post", "/m/api/undo"), ("put", f"/m/api/day/{DAY}/progress"),
                             ("post", f"/m/api/day/{DAY}/send"), ("post", f"/m/api/day/{DAY}/reset")):
            r = getattr(self.client, method)(path, json={})            # no X-Culling-Bay header
            self.assertEqual(r.status_code, 403, path)
            self.assertIn("error", r.get_json())
            for raw in ("", "null", "[]", '[{"id": 1}]', '"text"', "42", "true", "{invalid"):
                with self.subTest(path=path, body=raw):
                    r = getattr(self.client, method)(path, data=raw, content_type="application/json", headers=self.H)
                    self.assertEqual(r.status_code, 400)
                    self.assertEqual(set(r.get_json()), {"error"})
                    self.assertIsInstance(r.get_json()["error"], str)
            self.assertEqual(getattr(self.client, method)(path, headers=self.H).status_code, 400)
        post = lambda body: self.client.post("/m/api/decide", json=body, headers=self.H)
        for body in ({}, {"action_id": "e1", "day": DAY}, {"action_id": "e2", "day": DAY, "changes": []},
                     {"action_id": "e3", "changes": [{"id": x, "flag": "pick", "via": "card"}]},
                     {"action_id": "e4", "day": DAY, "changes": [{"id": str(x), "flag": "pick", "via": "card"}]}):
            r = post(body)
            self.assertEqual(r.status_code, 400, body)
            self.assertIsInstance(r.get_json()["error"], str)
        valid = {"action_id": "bad-body", "day": DAY, "changes": [{"id": x, "flag": "pick", "via": "card"}]}
        bad_bodies = [dict(valid, changes=c) for c in (None, {}, "change", 1, True, [None], [[]], ["change"], [1])]
        bad_bodies += [dict(valid, **{key: value}) for key in ("action_id", "day")
                       for value in (None, "", [], {}, True, 1)]
        bad_bodies += [dict(valid, label=v) for v in (False, 1, [], {})]
        bad_changes = [{"id": v} for v in (True, False, None, "1", 1.5, [], {}, 999999999)]
        bad_changes += [{"stars": v} for v in (True, False, 0, -1, 6, 2.5, "3", [], {})]
        bad_changes += [{"note": v} for v in (True, 1, [], {})]
        bad_changes += [{key: v} for key in ("flag", "via") for v in (None, "invalid", [], {})]
        with closing(self.db_ro()) as con:
            other = con.execute("SELECT rowid FROM images WHERE path NOT LIKE ? LIMIT 1", (f"%/{DAY}/%",)).fetchone()[0]
        bad_changes.append({"id": other})
        bad_bodies += [dict(valid, changes=[dict(valid["changes"][0], **change)]) for change in bad_changes]
        for body in bad_bodies:
            with self.subTest(body=body):
                r = post(body)
                self.assertEqual(r.status_code, 400)
                self.assertIsInstance(r.get_json()["error"], str)
        bad_progress = [{}, {"pass": 1}, {"pass": 0, "cursor": 1}, {"pass": 2, "cursor": "1"}]
        bad_progress += [dict({"pass": 2, "cursor": 0}, **{key: value})
                         for key, values in (("pass", (True, False, 1.0, None, "2", [], {})),
                                             ("cursor", (True, False, 1.0, None, [], {})),
                                             ("lead", (True, False, 1.0, "1", [], {}, 999999999, other)),
                                             ("finished", (None, 0, 1, "true", [], {}))) for value in values]
        for p in bad_progress:
            r = self.client.put(f"/m/api/day/{DAY}/progress", json=p, headers=self.H)
            self.assertEqual(r.status_code, 400, p)
            self.assertIsInstance(r.get_json()["error"], str)
        for body in ({}, {"action_id": None}, {"action_id": ""}, {"action_id": []}, {"action_id": {}}, {"action_id": True}):
            r = self.client.post("/m/api/undo", json=body, headers=self.H)
            self.assertEqual(r.status_code, 400, body)
            self.assertIsInstance(r.get_json()["error"], str)
        self.assertEqual(self.cull_snapshot(), before)
        r = self.client.put(f"/m/api/day/{DAY}/progress", json={"pass": 2, "cursor": 0, "lead": None}, headers=self.H)
        self.assertEqual(r.status_code, 200)    # a null lead is the same as none

        # Null/omitted strings and stars are allowed; reject/none ignore stars of any type.
        for flag, stars in (("pick", None), ("pick", 1), ("pick", 5), ("reject", {"ignored": True}), ("none", True)):
            body = dict(valid, action_id=str(uuid.uuid4()), label=None,
                        changes=[dict(valid["changes"][0], flag=flag, stars=stars, note=None)])
            self.assertEqual(post(body).status_code, 200)
            decision = self.frames()[0]["DSC05061.ARW"]["decision"]
            self.assertEqual(decision["stars"], stars if flag == "pick" else None)
            self.assertEqual(decision["note"], "")
            with closing(self.anno()) as con, con:
                self.assertEqual(con.execute("SELECT label FROM cull_actions WHERE action_id=?",
                                             (body["action_id"],)).fetchone()[0], "")
        self.assertEqual(post({"action_id": "e5", "day": DAY, "changes": [{"id": x, "flag": "none", "via": "sweep"}]})
                         .get_json(), {"ok": True})                 # the whole flag and via lists are accepted

    def test_contract_cull_writes_reject_unknown_days(self):
        import stacks
        self.addCleanup(self.wipe)
        self.wipe()
        self.frames()   # initialise the phone tables
        before = self.cull_snapshot()
        for day in ("no-such-day", "2026"):
            for method, route, body in (("put", "progress", {"pass": 2, "cursor": 0}),
                                         ("post", "send", {}), ("post", "reset", {})):
                with self.subTest(day=day, route=route), patch.object(stacks, "build_stacks", side_effect=AssertionError):
                    r = getattr(self.client, method)(f"/m/api/day/{day}/{route}", json=body, headers=self.H)
                    self.assertEqual((r.status_code, r.get_json()), (404, {"error": "no such day"}))
                    self.assertEqual(self.cull_snapshot(), before)

    def test_contract_cull_writes_accept_days_with_only_phone_state(self):
        import stacks
        self.addCleanup(self.wipe)
        self.frames()
        day = "vanished/day"
        for table in ("cull_days", "cull_decisions"):
            for method, route, body in (("put", "progress", {"pass": 2, "cursor": 0}),
                                         ("post", "send", {}), ("post", "reset", {})):
                with self.subTest(table=table, route=route):
                    self.wipe()
                    with closing(self.anno()) as con, con:
                        if table == "cull_days":
                            con.execute("INSERT INTO cull_days(day) VALUES (?)", (day,))
                        else:
                            con.execute("INSERT INTO cull_decisions(path, day, flag, via, decided_at) VALUES (?,?,?,?,?)",
                                        (f"/mnt/passport/Pictures/{day}/gone.ARW", day, "reject", "card", "now"))
                    with patch.object(stacks, "build_stacks", side_effect=AssertionError):
                        r = getattr(self.client, method)(f"/m/api/day/{day}/{route}", json=body, headers=self.H)
                    self.assertEqual(r.status_code, 200, r.get_json())
                    self.assertTrue(r.get_json()["ok"])

    def test_json_reads_revalidate_with_an_etag(self):
        r = self.client.get(f"/m/api/gallery/day/{DAY}")
        tag = r.headers["ETag"]
        self.assertEqual(r.headers["Cache-Control"], "no-cache")
        again = self.client.get(f"/m/api/gallery/day/{DAY}", headers={"If-None-Match": tag})
        self.assertEqual(again.status_code, 304)
        self.assertEqual(again.data, b"")


if __name__ == "__main__":
    unittest.main()

    def test_pipeline_health(self):
        from datetime import datetime, timedelta
        now = datetime.now().astimezone()
        at = lambda h: (now - timedelta(hours=h)).isoformat(timespec="seconds")
        self.log.write_text("\n".join([
            "first line is skipped as a possible partial line",
            f"[{at(400)}] run FAILED for /mnt/passport/Pictures/2025/2025-01-01 -- leaving unmarked",   # over a week old
            f"[{at(30)}] run FAILED for /mnt/passport/Pictures/2026/2026-09-29 -- leaving unmarked, will retry next poll",
            f"[{at(29)}] done: /mnt/passport/Pictures/2026/2026-09-29 -> /mnt/Passport_AICullInbox/pending.tsv",
            f"[{at(5)}] export FAILED for /mnt/passport/Pictures/2026/2026-10-01 -- leaving unmarked, will retry next poll",
            f"[{at(4)}] msmtp send FAILED (check ~/.msmtprc) -- ignored",
            f"[{at(3)}] processing /mnt/passport/Pictures/2026/2026-10-01", ""]))
        d = self.client.get("/m/api/pipeline-health").get_json()
        self.assertIn(d["status"], ("warn", "bad"))
        titles = [a["title"] for a in d["alerts"]]
        self.assertIn("Ollama not answering", titles)
        self.assertIn("Ingest export failing", titles)          # no later done: for that folder
        self.assertNotIn("Ingest run failing", titles)           # 2026-09-29 was done afterwards
        self.assertTrue(all(a["level"] in ("warn", "bad") and a["fix"] for a in d["alerts"]))
        steps = [(r["step"], r["resolved"]) for r in d["recent"]]
        self.assertEqual(steps, [("run", True), ("export", False)])   # the old one and msmtp are left out
        self.assertEqual(d["last_ingest"]["shoot"], "2026-09-29")
        self.assertIsNone(d["model"]["installed"])
        self.assertGreater(d["index"]["ok"], 40000)



@unittest.skipUnless(TRIAL_DB.exists(), "needs trial_out/trial.db")
class DecodeAhead(unittest.TestCase):
    """A card's picture being asked for starts its full RAW decode in the background, so its
    1:1 check (and the viewer's HD zoom) is ready by the time you ask. A fake decoder stands in
    for rawpy, counting its calls."""

    def setUp(self):
        from flask import Flask
        from PIL import Image
        import mobile
        import photo_cull as pc
        self.tmp = tempfile.TemporaryDirectory()
        tmp = Path(self.tmp.name)
        self.calls = []
        self.lock = threading.Lock()
        self.decode_seconds = 0.4

        def fake_decode(path):
            with self.lock:
                self.calls.append(Path(path).name)
            time.sleep(self.decode_seconds)
            return Image.new("RGB", (600, 400), "grey")

        self.regions = []

        def fake_region(path, x, y, w, h):
            with self.lock:
                self.regions.append(Path(path).name)
            return Image.new("RGB", (w, h), "grey"), (0, 0, w, h, 600, 400)

        def db_ro():
            con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            return con

        def anno():
            return anno_connection(tmp / "annotations.db")

        (tmp / "static").mkdir()
        (tmp / "inbox").mkdir()
        app = Flask(__name__)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=db_ro, anno=anno, pc=FakePC(), cache_dir=tmp, static_dir=tmp / "static", state_dir=tmp / "state",
            inbox=tmp / "inbox", check_mount=False, ingest_log=tmp / "ingest.log",
            ollama_url="http://127.0.0.1:9", raw_decoder=fake_decode, region_decoder=fake_region))
        self.client = app.test_client()
        con = db_ro()
        try:
            self.raws = [r[0] for r in con.execute(
                "SELECT rowid FROM images WHERE path LIKE ? AND lower(filename) LIKE '%.arw' ORDER BY rowid LIMIT 3",
                (f"%/{DAY}/%",))]
            self.many_raws = [r[0] for r in con.execute(
                "SELECT rowid FROM images WHERE lower(filename) LIKE '%.arw' ORDER BY rowid LIMIT ?",
                (mobile.FULL_CACHE_FRAMES + 4,))]
        finally:
            con.close()

    def tearDown(self):
        self.tmp.cleanup()

    def wait_for_calls(self, n, seconds=5.0):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            with self.lock:
                if len(self.calls) >= n:
                    return True
            time.sleep(0.02)
        return False

    def test_crops_keep_working_once_the_decode_cache_is_full(self):
        # the cache holds FULL_CACHE_FRAMES decodes; the ones after that evict the oldest
        self.decode_seconds = 0
        for rid in self.many_raws:
            r = self.client.get(f"/m/api/crop/{rid}?x=0.5&y=0.5&w=64&h=64")
            self.assertEqual(r.status_code, 200, f"crop of {rid}: {r.get_json()}")
        # the oldest was evicted and decodes again; the newest is still cached
        before = len(self.calls)
        self.assertEqual(self.client.get(f"/m/api/crop/{self.many_raws[-1]}?x=0.5&y=0.5&w=64&h=64").status_code, 200)
        self.assertEqual(len(self.calls), before)
        self.assertEqual(self.client.get(f"/m/api/crop/{self.many_raws[0]}?x=0.5&y=0.5&w=64&h=64").status_code, 200)
        self.assertEqual(len(self.calls), before + 1)

    def test_crop_with_odd_numbers_today(self):
        """Documents what the route does now, not what it should do (server.md "Input validation", card
        D3, not chosen). Infinity is clamped like any too-big number, and a non-numeric size is a 400;
        NaN as the centre decodes the whole RAW and then fails (500, an HTML page), and so does an id
        past SQLite's integer range. If validation is added, those two become 400s."""
        self.decode_seconds = 0
        rid = self.raws[0]
        crop = f"/m/api/crop/{rid}?y=0.5&w=200&h=200&x="
        self.assertEqual(self.client.get(crop + "inf").status_code, 200)
        self.assertEqual(self.client.get(crop + "-inf").status_code, 200)
        r = self.client.get(f"/m/api/crop/{rid}?x=0.5&y=0.5&w={2 ** 70}&h={2 ** 70}")      # clamped to the frame
        self.assertEqual((r.status_code, r.headers["X-Crop-Box"]), (200, "0,0,600,400 of 600x400"))
        self.assertEqual(self.client.get(f"/m/api/crop/{rid}?x=0.5&y=0.5&w=nan&h=200").status_code, 400)
        logger = self.client.application.logger.name
        for url in (crop + "nan", f"/m/api/crop/{2 ** 70}?x=0.5&y=0.5"):
            with self.subTest(url=url[-30:]), self.assertLogs(logger, "ERROR"):
                r = self.client.get(url)
                self.assertEqual(r.status_code, 500)
                self.assertIsNone(r.get_json(silent=True))

    def test_a_cards_picture_starts_its_decode_and_the_crop_uses_it(self):
        rid = self.raws[0]
        self.assertEqual(self.client.get(f"/m/api/img/{rid}?s=view").status_code, 200)
        self.assertTrue(self.wait_for_calls(1), "the view request should start a background decode")
        time.sleep(0.6)                                   # let it finish
        r = self.client.get(f"/m/api/crop/{rid}?x=0.5&y=0.5&w=200&h=200")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(self.calls), 1)              # the crop came from the decode-ahead

    def test_a_crop_during_the_decode_waits_for_it_rather_than_decoding_again(self):
        rid = self.raws[1]
        self.client.get(f"/m/api/img/{rid}?s=view")
        self.assertTrue(self.wait_for_calls(1))
        r = self.client.get(f"/m/api/crop/{rid}?x=0.5&y=0.5&w=200&h=200")   # still decoding
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(self.calls), 1)

    def test_warm_starts_the_decodes_a_saved_day_never_asks_for(self):
        # a day saved on the phone never asks for its cards' pictures; the app names them instead
        a, b = self.raws[0], self.raws[1]
        r = self.client.get(f"/m/api/warm?ids={a},{b}")
        self.assertEqual((r.status_code, r.data), (204, b""))
        self.assertTrue(self.wait_for_calls(2), "both photos should be decoded ahead")
        time.sleep(0.6)
        before = len(self.calls)
        for rid in (a, b):                                  # the 1:1 checks come from those decodes
            self.assertEqual(self.client.get(f"/m/api/crop/{rid}?x=0.5&y=0.5&w=64&h=64").status_code, 200)
        self.assertEqual(len(self.calls), before)

    def test_warm_takes_the_most_urgent_first(self):
        self.client.get(f"/m/api/warm?ids={self.raws[2]},{self.raws[0]}")
        self.assertTrue(self.wait_for_calls(1))
        con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
        try:
            first = con.execute("SELECT filename FROM images WHERE rowid=?", (self.raws[2],)).fetchone()[0]
        finally:
            con.close()
        self.assertEqual(self.calls[0], first)

    def test_warm_skips_what_it_cannot_use(self):
        con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
        try:
            jpeg = con.execute("SELECT rowid FROM images WHERE status='ok' AND lower(filename) LIKE '%.jpg' LIMIT 1").fetchone()[0]
        finally:
            con.close()
        for query in ("", "ids=", "ids=abc,,-3", f"ids={2 ** 70}", "ids=999999999", f"ids={jpeg}"):
            with self.subTest(query=query):
                self.assertEqual(self.client.get(f"/m/api/warm?{query}").status_code, 204)
        time.sleep(0.5)
        self.assertEqual(self.calls, [])

    def test_warm_names_at_most_four_photos(self):
        self.decode_seconds = 0
        ids = ",".join(str(i) for i in self.many_raws[:6])
        self.client.get(f"/m/api/warm?ids={ids}")
        self.wait_for_calls(4)
        time.sleep(0.5)
        self.assertEqual(len(self.calls), 4)

    def test_thumbnails_do_not_start_a_decode(self):
        self.client.get(f"/m/api/img/{self.raws[2]}?s=thumb")
        time.sleep(0.5)
        self.assertEqual(self.calls, [])

    def test_a_decoded_photo_is_not_decoded_again(self):
        rid = self.raws[0]
        self.client.get(f"/m/api/crop/{rid}?x=0.5&y=0.5&w=200&h=200")      # decoded on request
        self.client.get(f"/m/api/img/{rid}?s=view")                       # already in memory
        time.sleep(0.5)
        self.assertEqual(len(self.calls), 1)

    def test_offline_saving_neither_warms_nor_fills_the_cache(self):
        rid = self.raws[1]
        self.client.get(f"/m/api/img/{rid}?s=view&warm=0")                 # no decode-ahead
        time.sleep(0.5)
        self.assertEqual(self.calls, [])
        for _ in range(2):                                                  # keep=0: the crop's area only
            r = self.client.get(f"/m/api/crop/{rid}?x=0.5&y=0.5&w=200&h=200&keep=0")
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers["X-Crop-Box"], "0,0,200,200 of 600x400")
        self.assertEqual((len(self.calls), len(self.regions)), (0, 2))      # no full decode, nothing kept
        self.client.get(f"/m/api/crop/{rid}?x=0.5&y=0.5&w=200&h=200")        # an ordinary 1:1 decodes and keeps
        self.client.get(f"/m/api/crop/{rid}?x=0.5&y=0.5&w=200&h=200&keep=0") # which keep=0 then uses
        self.assertEqual((len(self.calls), len(self.regions)), (1, 2))


class HealthFixture(unittest.TestCase):
    """A blueprint over a small temp DB, a temp ingest log and a temp known-unreadable list, so the
    real snapshot's counts don't matter."""
    LIB = "/mnt/passport/Pictures"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.db = self.dir / "t.db"
        self.known = self.dir / "known-unreadable.txt"
        self.log = self.dir / "ingest.log"
        self.n = 0

    def add(self, folder, *, n=1, status="error", size=100, cls="model", attempts=1, msg="Server disconnected"):
        """n rows under LIB/<folder>; returns their paths."""
        import photo_cull as pc
        con = pc.connect(self.db)
        paths = []
        for _ in range(n):
            self.n += 1
            path = f"{self.LIB}/{folder}/IMG_{self.n:05d}.ARW"
            con.execute("INSERT INTO images(path, filename, size, status, attempts, error_class, error_msg, processed_at) "
                        "VALUES(?,?,?,?,?,?,?,?)",
                        (path, Path(path).name, size, status, attempts, cls if status == "error" else None,
                         msg if status == "error" else None, "2026-01-01T00:00:00+00:00"))
            paths.append(path)
        con.commit()
        con.close()
        return paths

    def health(self):
        from flask import Flask
        import mobile
        import photo_cull as pc
        if not self.db.exists():
            pc.connect(self.db).close()

        def db_ro():
            con = sqlite3.connect(f"file:{self.db}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            return con

        (self.dir / "static").mkdir(exist_ok=True)
        app = Flask(__name__)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=db_ro, anno=lambda: sqlite3.connect(self.dir / "annotations.db"), pc=pc, cache_dir=self.dir,
            static_dir=self.dir / "static", state_dir=self.dir / "state", inbox=self.dir / "inbox",
            check_mount=False, ingest_log=self.log, known_unreadable=self.known,
            ollama_url="http://127.0.0.1:9"))
        return app.test_client().get("/m/api/pipeline-health").get_json()

    def alert(self, d, suffix):
        found = [a for a in d["alerts"] if a["title"].endswith(suffix)]
        return found[0] if found else None


class PipelineHealthFailures(HealthFixture):
    """The two alerts for photos that failed to tag: still waiting for a retry, and originals that
    can't be read. A small temp DB with an error row of each kind."""

    def seed(self):
        self.add("2026/2026-09-29", n=3, cls="model", attempts=1)
        self.add("2026/2026-09-29", n=2, cls="timeout", attempts=2)
        self.add("2026/2026-06-27", n=2, cls="io", attempts=3, msg="Input/output error")
        self.add("2024/2024-04-14", n=3, cls="io", size=0, msg="Input/output error")       # as ingested in August
        self.add("2024/2024-04-14", n=1, cls="empty", size=0, msg="The file on the NAS is empty (0 bytes)")
        self.add("2024/2024-12-25", n=1, cls="io", attempts=4, msg="broken data stream")  # out of tries
        acked = self.add("2025/2025-01-01", n=1, cls="io", size=0)[0]       # the one Danny listed
        self.add("2026/2026-10-01", n=4, status="ok", attempts=1)
        self.known.write_text(f"{acked}\n")
        return acked

    def test_a_retry_alert_and_a_cant_be_read_alert(self):
        self.seed()
        d = self.health()
        wait = self.alert(d, "waiting for a retry")
        self.assertEqual(wait["title"], "7 photos waiting for a retry")
        self.assertEqual(wait["level"], "warn")
        self.assertIn("5 in 2026-09-29 and 2 in 2026-06-27", wait["detail"])
        self.assertIn("Causes: model (3), timeout (2), io (2)", wait["detail"])
        self.assertIn("every 15 minutes", wait["fix"])
        self.assertIn("up to 4 tries", wait["fix"])
        self.assertIn("cd ~/photo-culling && ./venv/bin/python photo_cull.py run <folder> "
                      "--db trial_out/trial.db --retry-failed", wait["fix"])
        bad = self.alert(d, "can't be read")
        self.assertEqual(bad["title"], "5 originals can't be read")
        self.assertEqual(bad["level"], "warn")
        self.assertIn("4 in 2024-04-14 and 1 in 2024-12-25", bad["detail"])
        self.assertRegex(bad["detail"], r"IMG_\d{5}\.ARW")                      # a few file names
        self.assertIn("another copy", bad["fix"])
        self.assertIn("camera card", bad["fix"])
        self.assertIn("~/photo-culling/trial_out/known-unreadable.txt", bad["fix"])
        self.assertIn(d["status"], ("warn", "bad"))

    def test_index_block(self):
        acked = self.seed()
        idx = self.health()["index"]
        self.assertEqual(idx["retrying"], 7)
        self.assertEqual(idx["unreadable"], 5)
        self.assertEqual(idx["acknowledged_unreadable"], 1)
        self.assertEqual(idx["caption_errors"], 13)                             # every error row, as before
        self.assertEqual(len(idx["unreadable_files"]), 5)
        first = idx["unreadable_files"][0]
        self.assertEqual(set(first), {"path", "size", "error"})
        self.assertEqual(first["path"], f"{self.LIB}/2024/2024-04-14/IMG_00008.ARW")   # sorted by path
        self.assertEqual((first["size"], first["error"]), (0, "Input/output error"))
        self.assertNotIn(acked, [f["path"] for f in idx["unreadable_files"]])
        self.assertEqual(idx["ok"], 4)

    def test_known_unreadable_file_format(self):
        paths = self.add("2024/2024-04-14", n=5, cls="io", size=0)
        self.known.write_text("\n".join([
            "# the 14 April 2024 shoot, accepted as lost",
            "",
            f"  {paths[0]}  ",                            # spaces around a path
            f"{paths[1]} # card was reformatted",          # a trailing comment
            f"#{paths[2]}",                                # commented out: still reported
            "/some/other/file.ARW"]))                      # not in the DB: ignored
        d = self.health()
        self.assertEqual(d["index"]["acknowledged_unreadable"], 2)
        self.assertEqual(d["index"]["unreadable"], 3)
        self.assertEqual(self.alert(d, "can't be read")["title"], "3 originals can't be read")

    def test_a_missing_list_means_nothing_is_acknowledged(self):
        self.add("2024/2024-04-14", n=2, cls="io", size=0)
        self.assertFalse(self.known.exists())
        d = self.health()
        self.assertEqual(d["index"]["acknowledged_unreadable"], 0)
        self.assertEqual(d["index"]["unreadable"], 2)

    def test_listing_every_unreadable_file_silences_the_alert(self):
        paths = self.add("2024/2024-04-14", n=3, cls="io", size=0)
        self.known.write_text("\n".join(paths))
        d = self.health()
        self.assertIsNone(self.alert(d, "can't be read"))
        self.assertEqual((d["index"]["unreadable"], d["index"]["acknowledged_unreadable"]), (0, 3))
        self.assertEqual(d["index"]["unreadable_files"], [])

    def test_unreadable_files_is_capped_at_100_but_the_count_is_not(self):
        self.add("2024/2024-04-14", n=130, cls="io", size=0)
        idx = self.health()["index"]
        self.assertEqual(idx["unreadable"], 130)
        self.assertEqual(len(idx["unreadable_files"]), 100)

    def test_one_photo_reads_in_the_singular(self):
        self.add("2026/2026-09-29", n=1)
        self.add("2024/2024-04-14", n=1, cls="empty", size=0)
        d = self.health()
        self.assertEqual(self.alert(d, "waiting for a retry")["title"], "1 photo waiting for a retry")
        self.assertEqual(self.alert(d, "can't be read")["title"], "1 original can't be read")

    def test_rows_with_missing_attempts_or_class_are_still_retried(self):
        paths = self.add("2026/2026-09-29", n=2)
        import photo_cull as pc
        con = pc.connect(self.db)
        con.execute("UPDATE images SET attempts=NULL WHERE path=?", (paths[0],))
        con.execute("UPDATE images SET error_class=NULL WHERE path=?", (paths[1],))
        con.commit()
        con.close()
        d = self.health()
        self.assertEqual((d["index"]["retrying"], d["index"]["unreadable"]), (2, 0))
        self.assertIn("unknown (1)", self.alert(d, "waiting for a retry")["detail"])

    def test_the_retry_limit_comes_from_photo_cull(self):
        import photo_cull as pc
        self.add("2026/2026-09-29", n=1, attempts=pc.MAX_ATTEMPTS - 1)
        self.add("2026/2026-09-29", n=1, attempts=pc.MAX_ATTEMPTS)
        idx = self.health()["index"]
        self.assertEqual((idx["retrying"], idx["unreadable"]), (1, 1))

    def test_nothing_failed_nothing_alerted(self):
        self.add("2026/2026-10-01", n=3, status="ok")
        d = self.health()
        self.assertIsNone(self.alert(d, "waiting for a retry"))
        self.assertIsNone(self.alert(d, "can't be read"))
        idx = d["index"]
        self.assertEqual((idx["retrying"], idx["unreadable"], idx["acknowledged_unreadable"], idx["unreadable_files"]),
                         (0, 0, 0, []))
        self.assertEqual(idx["caption_errors"], 0)


class PipelineHealthWatcher(HealthFixture):
    """The ingest log: is the watcher alive, and which of its lines count as failures."""

    def write_log(self, lines, age_hours=None):
        """Lines as (hours ago, text). The file's own time is set to the newest line's, unless
        age_hours says otherwise (a run that is still writing)."""
        from datetime import datetime, timedelta
        now = datetime.now().astimezone()
        out = ["first line is skipped as a possible partial line"]
        for hours, text in lines:
            out.append(f"[{(now - timedelta(hours=hours)).isoformat(timespec='seconds')}] {text}")
        self.log.write_text("\n".join(out) + "\n")
        newest = min(h for h, _ in lines) if lines else 0
        t = time.time() - 3600 * (newest if age_hours is None else age_hours)
        os.utime(self.log, (t, t))

    def test_an_old_log_means_the_watcher_has_stopped(self):
        self.write_log([(7, "poll: 394 folders, 0 changed, 0 processed, 22s"), (5.2, "processing /x/2026/2026-10-01")])
        d = self.health()
        a = self.alert(d, "hours")
        self.assertEqual(a["title"], "Ingest watcher hasn't run for 5 hours")
        self.assertEqual(a["level"], "bad")
        self.assertEqual(d["status"], "bad")
        self.assertIn("ingest_watch.log", a["fix"])
        self.assertIn("photo-cull-ingest.timer", a["fix"])

    def test_the_hourly_heartbeat_keeps_it_quiet(self):
        self.write_log([(9, "done: /x/2026/2026-10-01 -> /inbox/pending.tsv"),
                        (1.2, "poll: 394 folders, 0 changed, 0 processed, 3s")])
        d = self.health()
        self.assertIsNone(self.alert(d, "hours"))

    def test_just_under_two_hours_is_fine_and_just_over_is_not(self):
        self.write_log([(1.9, "poll: 394 folders, 0 changed, 0 processed, 3s")])
        self.assertIsNone(self.alert(self.health(), "hours"))
        self.write_log([(2.1, "poll: 394 folders, 0 changed, 0 processed, 3s")])
        self.assertEqual(self.alert(self.health(), "hours")["title"], "Ingest watcher hasn't run for 2 hours")

    def test_no_log_no_alert(self):
        self.assertFalse(self.log.exists())
        d = self.health()
        self.assertIsNone(self.alert(d, "hours"))
        self.assertIsNone(d["last_poll"])

    def test_a_long_run_still_writing_the_log_is_alive(self):
        # A backlog run writes a line per photo but no timestamped line for hours.
        self.write_log([(6, "processing /x/2026/2026-10-01")], age_hours=0.01)
        self.assertIsNone(self.alert(self.health(), "hours"))

    def test_last_poll_is_the_newest_timestamped_line(self):
        from datetime import datetime, timedelta
        self.write_log([(3, "poll: 394 folders, 0 changed, 0 processed, 3s"), (0.5, "done: /x/2026/2026-10-01 -> /i/p.tsv")])
        d = self.health()
        got = datetime.fromisoformat(d["last_poll"])
        self.assertLess(abs((datetime.now().astimezone() - timedelta(hours=0.5) - got).total_seconds()), 5)
        self.assertEqual(d["last_ingest"]["shoot"], "2026-10-01")

    def test_poll_and_retry_lines_are_not_failures(self):
        self.write_log([
            (3, "run deferred: Ollama not answering"),
            (2.5, "retry pending for /x/2026/2026-09-29: 35 photos"),
            (2, "poll: 394 folders, 1 changed, 1 processed, 40s"),
            (1.5, "poll: 5 folders, 0 changed, 0 processed, 1s FAILED"),     # never a failure, whatever it says
            (1, "marker upgraded for /x/2026/2026-02-02 (nothing changed since it was finished)")])
        d = self.health()
        self.assertEqual(d["recent"], [])
        titles = [a["title"] for a in d["alerts"]]
        self.assertFalse([t for t in titles if t.startswith("Ingest")], titles)

    def test_real_failures_still_count(self):
        self.write_log([(3, "export FAILED for /x/2026/2026-10-01 -- leaving unmarked, will retry next poll"),
                        (0.2, "poll: 394 folders, 1 changed, 1 processed, 40s")])
        d = self.health()
        self.assertEqual([r["step"] for r in d["recent"]], ["export"])
        self.assertIn("Ingest export failing", [a["title"] for a in d["alerts"]])


@unittest.skipUnless(TRIAL_DB.exists(), "needs trial_out/trial.db")
class PressPanos(unittest.TestCase):
    """The 29 Sep 2026 beach panorama was shot press by press (DSC04906..DSC04912, each its own
    press) and showed as seven single cards. The day now has it as one pano stack, measured from
    this PC's thumbnails (review/cache, read only here) and remembered in pano_steps.json."""
    DAY = "2026/2026-09-29"

    def setUp(self):
        from flask import Flask
        import mobile
        import photo_cull as pc
        import previews
        self.tmp = tempfile.TemporaryDirectory()
        tmp = Path(self.tmp.name)
        cache = ROOT / "review" / "cache"
        con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
        try:
            paths = [r[0] for r in con.execute(
                "SELECT path FROM images WHERE path LIKE ? AND filename BETWEEN 'DSC04906' AND 'DSC04913'",
                (f"%/{self.DAY}/%",))]
        finally:
            con.close()
        if len(paths) < 7 or not all(previews.preview_path(cache, p, 320).exists() for p in paths):
            self.skipTest("needs the 29 Sep thumbnails in review/cache")

        def db_ro():
            c = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
            c.row_factory = sqlite3.Row
            return c

        (tmp / "static").mkdir()
        (tmp / "inbox").mkdir()
        self.state = tmp / "state"
        app = Flask(__name__)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=db_ro, anno=lambda: anno_connection(tmp / "annotations.db"), pc=pc, cache_dir=cache,
            static_dir=tmp / "static", state_dir=self.state, inbox=tmp / "inbox", check_mount=False,
            ingest_log=tmp / "ingest.log", ollama_url="http://127.0.0.1:9", backup_status=tmp / "b.json",
            known_unreadable=tmp / "k.txt"))
        self.client = app.test_client()

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_beach_sweep_is_one_pano_card(self):
        body = self.client.get(f"/m/api/day/{self.DAY}").get_json()
        files = lambda s: [f["file"] for f in s["frames"]]
        pano = next(s for s in body["stacks"] if "DSC04906.ARW" in files(s))
        self.assertEqual(pano["kind"], "pano")
        self.assertEqual(files(pano), [f"DSC049{n:02d}.ARW" for n in range(6, 13)])
        before = next(s for s in body["stacks"] if "DSC04905.ARW" in files(s))
        self.assertNotEqual(before["kind"], "pano")                     # a different shot, kept apart
        steps = json.loads((self.state / "pano_steps.json").read_text())
        self.assertGreaterEqual(len(steps), 6)                          # the pairs were measured and kept

    def test_the_days_list_counts_the_pano_as_one_stack(self):
        day = next(d for d in self.client.get("/m/api/days").get_json()["days"] if d["day"] == self.DAY)
        body = self.client.get(f"/m/api/day/{self.DAY}").get_json()
        self.assertEqual(day["stacks"], len(body["stacks"]))
