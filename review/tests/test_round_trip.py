"""Phone -> Lightroom -> phone, end to end: the review server records decisions and sends them,
the real AI Cull plugin (SyncAICull.lua on the fake SDK, under lua5.1) applies them and writes a
receipt, and the server reads the receipt back. Uses the real trial.db (read-only), a temp
annotations.db and a temp inbox. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
TRIAL_DB = ROOT / "trial_out" / "trial.db"
DAY = "2026/2026-10-01"
MAC_DIR = "/Volumes/Passport/Pictures/2026/2026-10-01/"
H = {"X-Culling-Bay": "1"}


@unittest.skipUnless(TRIAL_DB.exists() and shutil.which("lua5.1"), "needs trial.db and lua5.1")
class RoundTrip(unittest.TestCase):
    def setUp(self):
        from flask import Flask
        import mobile
        import photo_cull as pc
        self.tmp = tempfile.TemporaryDirectory()
        tmp = Path(self.tmp.name)
        self.inbox = tmp / "inbox"
        self.inbox.mkdir()

        def db_ro():
            con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            return con

        def anno():
            con = sqlite3.connect(tmp / "annotations.db")
            con.row_factory = sqlite3.Row
            return con

        app = Flask(__name__)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=db_ro, anno=anno, pc=pc, cache_dir=tmp, static_dir=tmp, state_dir=tmp / "state",
            inbox=self.inbox, check_mount=False))
        self.c = app.test_client()
        self.anno = anno

    def tearDown(self):
        self.tmp.cleanup()

    def ids(self):
        body = self.c.get(f"/m/api/day/{DAY}").get_json()
        return {f["file"]: f for s in body["stacks"] for f in s["frames"]}

    def decide(self, action_id, changes):
        r = self.c.post("/m/api/decide", json={"action_id": action_id, "day": DAY, "label": action_id,
                                                "changes": changes}, headers=H)
        self.assertTrue(r.get_json()["ok"], r.get_json())

    def lightroom(self, photos, pick):
        """Run the plugin; photos: {file: (pickStatus, rating, caption)} as they are in Lightroom."""
        spec = Path(self.tmp.name) / "photos.tsv"
        spec.write_text("".join(f"{MAC_DIR}{f}\t{p}\t{r}\t{c}\n" for f, (p, r, c) in photos.items()))
        out = subprocess.run(["lua5.1", "lightroom-plugin/tests/run_sync.lua", str(spec), str(pick)],
                             cwd=ROOT, capture_output=True, text=True, check=True).stdout
        return {parts[0]: parts[1:] for parts in (line.split("\t") for line in out.splitlines())}

    def states(self):
        fr = self.ids()
        return {f: (fr[f]["decision"] or {}).get("state") for f in fr}

    def test_phone_to_lightroom_and_back(self):
        fr = self.ids()
        note = "Burst reject · kept DSC05039"
        self.decide("keep-39", [{"id": fr["DSC05039.ARW"]["id"], "flag": "pick", "via": "card"}] + [
            {"id": fr[f]["id"], "flag": "reject", "note": note, "via": "card"}
            for f in ("DSC05036.ARW", "DSC05037.ARW", "DSC05038.ARW")])
        self.decide("hero-61", [{"id": fr["DSC05061.ARW"]["id"], "flag": "pick", "stars": 5, "via": "card"}])
        self.decide("rej-62", [{"id": fr["DSC05062.ARW"]["id"], "flag": "reject", "via": "sweep"}])

        sent = self.c.post(f"/m/api/day/{DAY}/send", json={}, headers=H).get_json()
        self.assertEqual(sent["queued"], 6)
        lines = (self.inbox / "cull-decisions.tsv").read_text().splitlines()
        self.assertEqual(lines[0], "#cull-decisions v1")
        self.assertIn(f"2026-10-01\tDSC05036.ARW\treject\t\t{note}", lines)
        self.assertIn("2026-10-01\tDSC05061.ARW\tpick\t5\t", lines)
        self.assertEqual(set(self.states().values()) - {None}, {"queued"})

        # Lightroom: you had picked DSC05038 by hand; DSC05062 isn't in the selection
        lr = self.lightroom({
            "DSC05036.ARW": (0, 0, ""), "DSC05037.ARW": (0, 0, ""), "DSC05038.ARW": (1, 0, ""),
            "DSC05039.ARW": (0, 0, ""), "DSC05061.ARW": (0, 0, "")}, self.inbox / "cull-decisions.tsv")
        self.assertEqual(lr["DSC05036.ARW"][:2], ["-1", "0"])
        self.assertEqual(lr["DSC05036.ARW"][2], note)
        self.assertIn("Cull > Burst reject", lr["DSC05036.ARW"][3])
        self.assertEqual(lr["DSC05038.ARW"][:3], ["1", "0", ""])     # your pick, no note
        self.assertEqual(lr["DSC05039.ARW"][0], "1")
        self.assertEqual(lr["DSC05061.ARW"][:2], ["1", "5"])
        self.assertFalse((self.inbox / "cull-decisions.tsv").exists())  # moved to applied/

        st = self.states()                                             # reading the day ingests the receipt
        self.assertEqual(st["DSC05036.ARW"], "landed")
        self.assertEqual(st["DSC05039.ARW"], "landed")
        self.assertEqual(st["DSC05061.ARW"], "landed")
        self.assertEqual(st["DSC05038.ARW"], "conflict")
        self.assertEqual(st["DSC05062.ARW"], "missing")
        self.assertEqual(self.ids()["DSC05038.ARW"]["decision"]["outcome"], "you picked it")

        # the plugin's catalog file: what Lightroom now holds, and who set it
        fr = self.ids()
        self.assertEqual(fr["DSC05038.ARW"]["lr"], {"pick": 1, "rating": 0, "by": "you", "stars_by": ""})
        self.assertEqual(fr["DSC05036.ARW"]["lr"]["by"], "phone")
        self.assertEqual(fr["DSC05061.ARW"]["lr"], {"pick": 1, "rating": 5, "by": "phone", "stars_by": "phone"})
        self.assertIsNone(fr["DSC05062.ARW"]["lr"])                     # not in the Lightroom selection

        # Send again: only the missing one goes; landed and conflict rows stay put
        again = self.c.post(f"/m/api/day/{DAY}/send", json={}, headers=H).get_json()
        self.assertEqual(again["queued"], 1)
        self.assertEqual([l.split("\t")[1] for l in (self.inbox / "cull-decisions.tsv").read_text().splitlines()[1:]],
                         ["DSC05062.ARW"])
        days = {d["day"]: d for d in self.c.get("/m/api/days").get_json()["days"]}
        self.assertEqual((days[DAY]["landed"], days[DAY]["conflicts"]), (4, 1))
        self.assertEqual(days[DAY]["lr_done"], 1)                       # the burst you picked from by hand

    def test_lost_rows_are_written_again(self):
        fr = self.ids()
        self.decide("rej-61", [{"id": fr["DSC05061.ARW"]["id"], "flag": "reject", "via": "card"}])
        self.c.post(f"/m/api/day/{DAY}/send", json={}, headers=H)
        con = self.anno()
        con.execute("UPDATE cull_decisions SET sent_at='2026-10-10T11:00:00'")   # sent well before the receipt
        con.commit(); con.close()
        (self.inbox / "cull-decisions.tsv").unlink()                            # deleted with an earlier file
        (self.inbox / "applied").mkdir()
        (self.inbox / "applied" / "20261010-120000-receipt.tsv").write_text("#cull-receipt v1\n")
        self.assertEqual(self.states()["DSC05061.ARW"], "queued")
        self.assertIn("DSC05061.ARW", (self.inbox / "cull-decisions.tsv").read_text())

    def test_reset_a_day(self):
        fr = self.ids()
        self.decide("rej-61", [{"id": fr["DSC05061.ARW"]["id"], "flag": "reject", "via": "sweep"}])
        self.decide("rej-62", [{"id": fr["DSC05062.ARW"]["id"], "flag": "reject", "via": "sweep"}])
        self.c.put(f"/m/api/day/{DAY}/progress", json={"pass": 2, "cursor": 3}, headers=H)
        self.c.post(f"/m/api/day/{DAY}/send", json={}, headers=H)                  # queued, not yet synced
        (self.inbox / "cull-decisions.tsv").write_text(                              # another day's row shares the file
            (self.inbox / "cull-decisions.tsv").read_text() + "2026-09-29\tDSC04001.ARW\treject\t\t\n")
        r = self.c.post(f"/m/api/day/{DAY}/reset", json={}, headers=H).get_json()
        self.assertEqual((r["cleared"], r["withdrawn"]), (2, 2))
        self.assertEqual((self.inbox / "cull-decisions.tsv").read_text().splitlines()[1:],
                         ["2026-09-29\tDSC04001.ARW\treject\t\t"])                # the other day stays
        body = self.c.get(f"/m/api/day/{DAY}").get_json()
        self.assertIsNone(body["progress"])
        self.assertTrue(all(f["decision"] is None for s in body["stacks"] for f in s["frames"]))

    def test_reset_refused_once_in_lightroom(self):
        fr = self.ids()
        self.decide("rej-61", [{"id": fr["DSC05061.ARW"]["id"], "flag": "reject", "via": "sweep"}])
        con = self.anno()
        con.execute("UPDATE cull_decisions SET state='landed'")
        con.commit(); con.close()
        r = self.c.post(f"/m/api/day/{DAY}/reset", json={}, headers=H)
        self.assertEqual(r.status_code, 409)
        self.assertIn("already in Lightroom", r.get_json()["error"])

    def test_send_refuses_without_the_inbox_mount(self):
        import mobile
        from flask import Flask
        app = Flask(__name__)
        tmp = Path(self.tmp.name)
        con = self.anno()
        con.executescript(mobile.SCHEMA)
        con.execute("INSERT INTO cull_days(day) VALUES (?)", (DAY,))  # a known day, without reading the library
        con.commit()
        con.close()
        app.register_blueprint(mobile.make_blueprint(
            db_ro=lambda: None, anno=self.anno, pc=None, cache_dir=tmp, static_dir=tmp, state_dir=tmp / "s2",
            inbox=tmp / "not-a-mount", check_mount=True))
        r = app.test_client().post(f"/m/api/day/{DAY}/send", json={}, headers=H)
        self.assertEqual(r.status_code, 503)
        self.assertIn("not mounted", r.get_json()["error"])


if __name__ == "__main__":
    unittest.main()
