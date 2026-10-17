"""review/perf.py: the timing log line and Server-Timing header, and the phone's reports."""
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import perf  # noqa: E402


class PerfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from flask import Flask, jsonify
        cls.tmp = tempfile.TemporaryDirectory()
        cls.log = Path(cls.tmp.name) / "perf.jsonl"
        app = Flask(__name__)
        perf.install(app, cls.log)

        @app.route("/work/<int:n>")
        def work(n):
            with perf.stage("decode"):
                time.sleep(0.02)
            with perf.stage("decode"):     # the same name twice adds up
                time.sleep(0.01)
            perf.note(cache="miss")
            return jsonify({"n": n})

        @app.route("/file")
        def file():
            from flask import send_file
            f = Path(cls.tmp.name) / "blob.bin"
            f.write_bytes(b"x" * 5000)
            return send_file(f)

        @app.route("/boom")
        def boom():
            raise ValueError("nope")

        app.logger.disabled = True   # the /boom traceback is expected
        cls.client = app.test_client()

    @classmethod
    def tearDownClass(cls):
        for h in list(perf.LOG.handlers):
            perf.LOG.removeHandler(h)
            h.close()
        cls.tmp.cleanup()

    def lines(self):
        for h in perf.LOG.handlers:
            h.flush()
        return [json.loads(x) for x in self.log.read_text().splitlines()]

    def test_header_and_line(self):
        r = self.client.get("/work/7?x=1")
        header = r.headers["Server-Timing"]
        r.close()
        self.assertIn("total;dur=", header)
        self.assertIn("decode;dur=", header)
        self.assertIn('cache;desc="miss"', header)
        line = [x for x in self.lines() if x.get("path") == "/work/7?x=1"][-1]
        self.assertEqual(line["route"], "/work/<int:n>")
        self.assertEqual(line["status"], 200)
        self.assertGreaterEqual(line["stages"]["decode"], 29)
        self.assertGreaterEqual(line["send_ms"], line["ms"])
        self.assertEqual(line["attrs"], {"cache": "miss"})

    def test_a_raising_handler_is_logged_as_500(self):
        self.client.application.config["PROPAGATE_EXCEPTIONS"] = False
        self.client.get("/boom").close()
        line = [x for x in self.lines() if x.get("path") == "/boom"][-1]
        self.assertEqual((line["status"], line.get("error")), (500, "ValueError"))

    def test_stage_outside_a_request_does_nothing(self):
        with perf.stage("x"):
            pass
        perf.note(a="b")

    def test_client_lines_keep_known_fields_only(self):
        n = perf.client_lines([{"type": "viewer_photo", "ms": 412.3, "name": "/m/api/img/5?s=view",
                                "evil": "x" * 50, "bytes": True},
                               {"type": "no-ms"}, "junk"], "100.91.65.36", "Mozilla/5.0 (iPhone; CPU iPhone OS)")
        self.assertEqual(n, 1)
        line = [x for x in self.lines() if x.get("kind") == "client"][-1]
        self.assertEqual(line["device"], "iphone")
        self.assertEqual(line["ms"], 412.3)
        self.assertNotIn("evil", line)
        self.assertNotIn("bytes", line)          # a boolean isn't a size

    def test_files_sent_with_send_file_are_logged_once_sent(self):
        r = self.client.get("/file")
        body = r.data
        r.close()
        self.assertEqual(body, b"x" * 5000)
        line = [x for x in self.lines() if x.get("path") == "/file"][-1]
        self.assertEqual(line["bytes"], 5000)
        self.assertIn("send_ms", line)


if __name__ == "__main__":
    unittest.main()
