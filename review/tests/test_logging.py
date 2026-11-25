"""Errors reach the journal: server.configure_logging(), the warning each decode failure leaves,
and the timing log staying out of the journal. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import io
import json
import logging
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
TRIAL_DB = ROOT / "trial_out" / "trial.db"


class FakePC:
    """photo_cull, except that reading a photo for a preview can be made to fail."""
    load_error: Exception | None = None

    def __getattr__(self, name):
        import photo_cull
        return getattr(photo_cull, name)

    def load_source(self, path):
        from PIL import Image
        if self.load_error:
            raise self.load_error
        return Image.new("RGB", (64, 48))


@unittest.skipUnless(TRIAL_DB.exists(), "needs trial_out/trial.db")
class DecodeFailuresAreLogged(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from flask import Flask
        import mobile
        import perf
        cls.tmp = tempfile.TemporaryDirectory()
        tmp = Path(cls.tmp.name)
        cls.pc = FakePC()
        cls.decode_error: Exception | None = None

        def fake_decode(path):
            if cls.decode_error:
                raise cls.decode_error
            from PIL import Image
            return Image.new("RGB", (600, 400), "grey")

        def db_ro():
            con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            return con

        def anno():
            con = sqlite3.connect(tmp / "annotations.db")
            con.row_factory = sqlite3.Row
            return con

        (tmp / "static").mkdir()
        (tmp / "inbox").mkdir()
        cls.app = Flask(__name__)
        cls.perf_log = tmp / "perf.jsonl"
        perf.install(cls.app, cls.perf_log)
        cls.app.register_blueprint(mobile.make_blueprint(
            db_ro=db_ro, anno=anno, pc=cls.pc, cache_dir=tmp / "cache", static_dir=tmp / "static",
            state_dir=tmp / "state", inbox=tmp / "inbox", check_mount=False, ingest_log=tmp / "ingest.log",
            ollama_url="http://127.0.0.1:9", raw_decoder=fake_decode))
        (tmp / "cache").mkdir()
        cls.client = cls.app.test_client()
        con = db_ro()
        try:
            cls.rowid, cls.path = con.execute(
                "SELECT rowid, path FROM images WHERE lower(filename) LIKE '%.arw' ORDER BY rowid LIMIT 1").fetchone()
        finally:
            con.close()
        cls.name = Path(cls.path).name

    @classmethod
    def tearDownClass(cls):
        import perf
        for h in list(perf.LOG.handlers):
            if getattr(h, "baseFilename", None) == str(cls.perf_log.resolve()):
                perf.LOG.removeHandler(h)
                h.close()
        cls.tmp.cleanup()

    def setUp(self):
        type(self).decode_error = None
        self.pc.load_error = None
        for f in (Path(self.tmp.name) / "cache").iterdir():   # a made preview would answer without decoding
            f.unlink()

    def perf_line(self, path):
        import perf
        for h in perf.LOG.handlers:
            h.flush()
        lines = [json.loads(x) for x in self.perf_log.read_text().splitlines()]
        return [x for x in lines if x.get("path") == path][-1]

    def failing_get(self, url, level="WARNING"):
        with self.assertLogs("mobile", level) as logs:
            r = self.client.get(url)
            r.close()
        self.assertEqual(r.status_code, 415, url)
        return r, logs

    ROUTES = {
        "crop": lambda s: f"/m/api/crop/{s.rowid}?x=0.5&y=0.5&w=200&h=200",
        "export": lambda s: f"/m/api/export/{s.rowid}?s=large",
        "img": lambda s: f"/m/api/img/{s.rowid}?s=view&warm=0",
    }

    def break_decoding(self, error):
        type(self).decode_error = error
        self.pc.load_error = error

    def test_each_415_route_logs_the_photo_and_the_reason_and_marks_the_timing_line(self):
        for route, url in self.ROUTES.items():
            with self.subTest(route):
                self.break_decoding(OSError("Input/output error on the share"))
                u = url(self)
                r, logs = self.failing_get(u)
                self.assertEqual(r.get_json(), {"error": "decode failed: Input/output error on the share"})
                self.assertEqual(len(logs.records), 1, logs.output)
                text = logs.output[0]
                self.assertIn(f"photo {self.rowid} ({self.name})", text)
                self.assertIn("OSError: Input/output error on the share", text)
                self.assertNotIn("Traceback", text, "a read error says enough in one line")
                self.assertEqual(self.perf_line(u)["attrs"]["error"], "OSError: Input/output error on the share")
                self.assertEqual(self.perf_line(u)["status"], 415)

    def test_an_unexpected_failure_keeps_its_traceback(self):
        self.break_decoding(TypeError("cannot use a Image as a set member"))
        r, logs = self.failing_get(self.ROUTES["crop"](self))
        self.assertIn("Traceback", logs.output[0])
        self.assertIn("TypeError: cannot use a Image as a set member", logs.output[0])

    def test_the_reason_is_one_clean_line_in_the_timing_header(self):
        self.break_decoding(RuntimeError('bad "frame"\nsecond line é'))
        u = self.ROUTES["crop"](self)
        r, logs = self.failing_get(u)
        self.assertIn("Server-Timing", r.headers)             # a newline here would have been a 500
        self.assertEqual(self.perf_line(u)["attrs"]["error"], "RuntimeError: bad 'frame' second line ?")

    def test_a_failed_decode_ahead_is_a_warning(self):
        type(self).decode_error = OSError("Input/output error")   # the picture itself reads fine
        with self.assertLogs("mobile", "WARNING") as logs:
            r = self.client.get(f"/m/api/img/{self.rowid}?s=view")   # starts the background decode
            r.close()
            self.assertEqual(r.status_code, 200)
            end = time.monotonic() + 5
            while not logs.records and time.monotonic() < end:
                time.sleep(0.02)
        self.assertIn(f"decode-ahead failed for {self.name}: OSError: Input/output error", logs.output[0])


class JournalOutput(unittest.TestCase):
    """What ends up on stderr (journald) once the server has configured logging."""

    def setUp(self):
        self.root = logging.getLogger()
        self.saved = (self.root.handlers[:], self.root.level, logging.getLogger("werkzeug").level)
        self.root.handlers[:] = []
        self.addCleanup(self.restore)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def restore(self):
        for h in self.root.handlers:
            h.close()
        self.root.handlers[:] = self.saved[0]
        self.root.setLevel(self.saved[1])
        logging.getLogger("werkzeug").setLevel(self.saved[2])

    def configure(self):
        import server
        self.stderr = io.StringIO()
        with patch.object(sys, "stderr", self.stderr):
            server.configure_logging()

    def test_info_and_warnings_reach_stderr_and_werkzeug_lines_do_not(self):
        self.configure()
        logging.getLogger("mobile").info("region decode fell back for DSC1.ARW: odd sensor")
        logging.getLogger("mobile").warning("decode failed for photo 7 (DSC1.ARW): OSError: gone")
        logging.getLogger("werkzeug").info('127.0.0.1 - - "GET /m/api/days HTTP/1.1" 200 -')
        out = self.stderr.getvalue().splitlines()
        self.assertEqual(out, ["INFO mobile: region decode fell back for DSC1.ARW: odd sensor",
                               "WARNING mobile: decode failed for photo 7 (DSC1.ARW): OSError: gone"])

    def test_timing_lines_stay_out_of_the_journal(self):
        import perf
        from flask import Flask, jsonify
        self.configure()
        self.assertFalse(perf.LOG.propagate)
        app = Flask(__name__)
        log = Path(self.tmp.name) / "perf.jsonl"
        perf.install(app, log)
        self.addCleanup(self.drop_perf_handler, log)

        @app.route("/ok")
        def ok():
            return jsonify(fine=True)

        app.test_client().get("/ok").close()
        for h in perf.LOG.handlers:
            h.flush()
        self.assertIn('"path":"/ok"', log.read_text())
        self.assertNotIn("/ok", self.stderr.getvalue())

    def drop_perf_handler(self, log):
        import perf
        for h in list(perf.LOG.handlers):
            if getattr(h, "baseFilename", None) == str(log.resolve()):
                perf.LOG.removeHandler(h)
                h.close()

    def test_an_unhandled_exception_in_a_route_reaches_stderr_with_its_traceback(self):
        from flask import Flask
        self.configure()
        app = Flask(__name__)

        @app.route("/boom")
        def boom():
            raise ValueError("a bug in a route")

        app.config["PROPAGATE_EXCEPTIONS"] = False
        with self.assertLogs(app.logger.name, "ERROR") as logs:
            self.assertEqual(app.test_client().get("/boom").status_code, 500)
        self.assertIn("Traceback", logs.output[0])
        self.assertIn("ValueError: a bug in a route", logs.output[0])
        # assertLogs swaps the logger's handlers out, so ask again to see what stderr gets
        self.assertEqual(app.test_client().get("/boom").status_code, 500)
        err = self.stderr.getvalue()
        self.assertIn("ERROR", err)
        self.assertIn("Traceback", err)
        self.assertIn("ValueError: a bug in a route", err)


if __name__ == "__main__":
    unittest.main()
