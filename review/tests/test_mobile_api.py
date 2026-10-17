"""Integration tests for the /m routes, against the real trial.db (read-only) with a throwaway
annotations.db, cache and state dir. Skipped when trial.db is missing. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import io
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
TRIAL_DB = ROOT / "trial_out" / "trial.db"
DAY = "2026/2026-10-01"


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
            con = sqlite3.connect(tmp / "annotations.db")
            con.row_factory = sqlite3.Row
            return con

        (tmp / "static").mkdir()
        (tmp / "static" / "index.html").write_text("<!doctype html><title>Culling Bay</title>")
        app = Flask(__name__)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=db_ro, anno=anno, pc=pc, cache_dir=tmp, static_dir=tmp / "static", state_dir=tmp / "state",
            inbox=tmp / "inbox", check_mount=False, ingest_log=tmp / "ingest.log",
            ollama_url="http://127.0.0.1:9"))   # nothing listens there: Ollama "not answering"
        cls.log = tmp / "ingest.log"
        cls.client = app.test_client()

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

    H = {"X-Culling-Bay": "1"}

    def frames(self):
        body = self.client.get(f"/m/api/day/{DAY}").get_json()
        return {f["file"]: f for s in body["stacks"] for f in s["frames"]}, body

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
        import time
        from PIL import Image
        fid = self.frames()[0]["DSC05036.ARW"]["id"]
        t = time.time()
        r = self.client.get(f"/m/api/crop/{fid}?x=0.5&y=0.5&w=800&h=600")
        first = time.time() - t
        self.assertEqual(r.status_code, 200)
        self.assertEqual(Image.open(io.BytesIO(r.data)).size, (800, 600))
        self.assertTrue(r.headers["X-Crop-Box"].endswith("of 7968x5320"))
        r.close()
        t = time.time()
        r = self.client.get(f"/m/api/crop/{fid}?x=1&y=0&w=5000&h=400")   # clamped to the corner
        second = time.time() - t
        self.assertTrue(r.headers["X-Crop-Box"].startswith("5568,0,2400,400"), r.headers["X-Crop-Box"])
        r.close()
        self.assertLess(second, first / 2, f"second crop should reuse the decode ({first:.2f}s, {second:.2f}s)")
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
        if not Path(path).exists():
            self.skipTest("the NAS is not mounted")
        r = self.client.get(f"/m/api/export/{rowid}")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data, Path(path).read_bytes())
        r.close()

    def test_export_original_raw_is_a_download_of_the_file(self):
        lead = self.client.get(f"/m/api/gallery/day/{DAY}").get_json()["photos"][0]
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

