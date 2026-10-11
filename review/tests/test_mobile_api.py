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
            inbox=tmp / "inbox", check_mount=False))
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

    def test_day_stacks(self):
        body = self.client.get(f"/m/api/day/{DAY}").get_json()
        st = body["stacks"]
        self.assertEqual(sum(len(s["frames"]) for s in st), 32)
        by_file = {f["file"]: s for s in st for f in s["frames"]}
        bracket = by_file["DSC05040.ARW"]
        self.assertEqual(bracket["kind"], "bracket")
        lead = next(f for f in bracket["frames"] if f["id"] == bracket["lead"])
        self.assertEqual(lead["file"], "DSC05040.ARW")          # the normal exposure, not the brightest
        burst = by_file["DSC05036.ARW"]
        self.assertEqual(burst["kind"], "burst")
        self.assertEqual(len(burst["frames"]), 4)
        lead = next(f for f in burst["frames"] if f["id"] == burst["lead"])
        self.assertEqual(lead["file"], "DSC05039.ARW")          # sharpness 445, the burst's highest
        self.assertIsNone(body["progress"])
        self.assertEqual(body["budget"], {"stacks": 5, "per_hour": 15, "hours": 0.19})   # an 11-minute shoot
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


if __name__ == "__main__":
    unittest.main()
