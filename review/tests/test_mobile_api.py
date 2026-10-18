"""Integration tests for the /m routes, against the real trial.db (read-only) with a throwaway
annotations.db, cache and state dir. Skipped when trial.db is missing. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import io
import sqlite3
import sys
import tempfile
import unittest
import uuid
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
           "lr_done": int, "finished": bool, "sent_at": (str, None)}
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

    # ------------------------------------------------ the Cull half of the contract
    STACK = {"id": int, "kind": str, "lead": int, "frames": list}
    FRAME = {"id": int, "file": str, "partners": list, "partner_ids": list, "sharpness": ((int, float), None),
             "af": (list, None), "badges": list, "lr": (dict, None), "decision": (dict, None),
             "lens": (str, None), "caption": (str, None), "blown_pct": ((int, float), None),
             "mean_lum": ((int, float), None), "place": (str, None)}
    LR = {"pick": int, "rating": int, "by": str, "stars_by": str}
    DECISION = {"flag": str, "stars": (int, None), "note": str, "state": str, "outcome": (str, None)}
    BUDGET = {"stacks": int, "per_hour": int, "hours": (int, float)}
    PROGRESS = {"pass": (int, None), "cursor": (int, None)}
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

    def test_contract_cull_send_before_any_progress_leaves_nulls(self):
        self.addCleanup(self.wipe)
        self.wipe()
        r = self.client.post(f"/m/api/day/{DAY}/send", json={}, headers=self.H)
        self.assertEqual(r.get_json(), {"ok": True, "queued": 0, "file_rows": 0})
        self.assertEqual(self.frames()[1]["progress"], {"pass": None, "cursor": None})   # not null

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
        applied.mkdir()
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
        fr, _ = self.frames()
        x = fr["DSC05061.ARW"]["id"]
        for method, path in (("post", "/m/api/decide"), ("post", "/m/api/undo"), ("put", f"/m/api/day/{DAY}/progress"),
                             ("post", f"/m/api/day/{DAY}/send"), ("post", f"/m/api/day/{DAY}/reset")):
            r = getattr(self.client, method)(path, json={})            # no X-Culling-Bay header
            self.assertEqual(r.status_code, 403, path)
            self.assertIn("error", r.get_json())
        post = lambda body: self.client.post("/m/api/decide", json=body, headers=self.H)
        for body in ({}, {"action_id": "e1", "day": DAY}, {"action_id": "e2", "day": DAY, "changes": []},
                     {"action_id": "e3", "changes": [{"id": x, "flag": "pick", "via": "card"}]},
                     {"action_id": "e4", "day": DAY, "changes": [{"id": str(x), "flag": "pick", "via": "card"}]}):
            r = post(body)
            self.assertEqual(r.status_code, 400, body)
            self.assertIsInstance(r.get_json()["error"], str)
        for p in ({}, {"pass": 1}, {"pass": 0, "cursor": 1}, {"pass": 2, "cursor": "1"}):
            r = self.client.put(f"/m/api/day/{DAY}/progress", json=p, headers=self.H)
            self.assertEqual(r.status_code, 400, p)
        self.assertEqual(post({"action_id": "e5", "day": DAY, "changes": [{"id": x, "flag": "none", "via": "sweep"}]})
                         .get_json(), {"ok": True})                 # the whole flag and via lists are accepted

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

