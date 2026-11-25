"""review/perf.py: the timing log line and Server-Timing header, and the phone's reports."""
import contextlib
import io
import json
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import perf  # noqa: E402
import perf_report  # noqa: E402

SAFARI_IPHONE = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 "
                 "(KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1")
NATIVE_APP = "CullingBay/110 CFNetwork/1494.0.7 Darwin/23.4.0"
MAC_SAFARI = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
              "(KHTML, like Gecko) Version/18.1 Safari/605.1.15")


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

    def test_user_agents_are_told_apart(self):
        cases = [
            (SAFARI_IPHONE, ("iphone", "web")),
            ("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1",
             ("ipad", "web")),
            ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/126.0 Mobile Safari/537.36",
             ("android", "web")),
            (NATIVE_APP, ("iphone", "ios")),
            ("CullingBay/9 CFNetwork/1335.0.3 Darwin/21.6.0", ("iphone", "ios")),
            ("Other/1 CFNetwork/1494.0.7 Darwin/23.4.0", ("iphone", "ios")),
            (MAC_SAFARI, ("desktop", "web")),
            ("Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0", ("desktop", "web")),
            ("", ("desktop", "web")),
        ]
        for agent, want in cases:
            with self.subTest(agent[:40]):
                self.assertEqual(perf.classify_agent(agent), want)

    def test_client_lines_carry_device_and_app(self):
        for agent, want in ((NATIVE_APP, ("iphone", "ios")), (SAFARI_IPHONE, ("iphone", "web")),
                            (MAC_SAFARI, ("desktop", "web"))):
            with self.subTest(agent[:20]):
                perf.client_lines([{"type": "viewer_photo", "ms": 123.4, "name": agent[:12]}], "100.64.0.9", agent)
                line = [x for x in self.lines() if x.get("kind") == "client" and x.get("name") == agent[:12]][-1]
                self.assertEqual((line["device"], line["app"]), want)

    def test_server_lines_say_when_the_native_app_asked(self):
        self.client.get("/work/1?from=app", headers={"User-Agent": NATIVE_APP}).close()
        self.client.get("/work/1?from=safari", headers={"User-Agent": SAFARI_IPHONE}).close()
        self.client.get("/work/1?from=none").close()
        by = {x["path"]: x for x in self.lines() if x.get("path", "").startswith("/work/1?from=")}
        self.assertEqual(by["/work/1?from=app"]["app"], "ios")
        self.assertNotIn("app", by["/work/1?from=safari"])
        self.assertNotIn("app", by["/work/1?from=none"])

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


class PerfReportTest(unittest.TestCase):
    """perf_report over logs written before and after the lines said which app they came from."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.log = Path(self.tmp.name) / "perf.jsonl"
        self.now = datetime.now().isoformat(timespec="milliseconds")

    def client(self, ms, app=None, **kw):
        line = {"ts": self.now, "kind": "client", "client": "100.64.0.9", "device": "desktop",
                "type": "viewer_photo", "ms": ms, **kw}
        if app:
            line["app"] = app
        return line

    def server(self, ms, app=None):
        line = {"ts": self.now, "kind": "server", "method": "GET", "route": "/m/api/img/<int:rowid>",
                "path": "/m/api/img/5?s=thumb", "status": 200, "ms": ms, "send_ms": ms + 1, "bytes": 10,
                "client": "100.64.0.9", "stages": {}, "attrs": {}}
        if app:
            line["app"] = app
        return line

    def report(self, lines, *args):
        self.log.write_text("\n".join(json.dumps(x) for x in lines) + "\n")
        out = io.StringIO()
        with patch.object(sys, "argv", ["perf_report.py", "--log", str(self.log), *args]), contextlib.redirect_stdout(out):
            perf_report.main()
        return out.getvalue()

    def phone_rows(self, text):
        block = text.split("PHONE")[1].split("\n\n")[0].splitlines()[1:]   # header, then the rows
        return [row.split() for row in block]

    def test_old_lines_alone_read_as_before(self):
        text = self.report([self.client(100), self.client(300), self.server(5)])
        header, row = self.phone_rows(text)
        self.assertEqual(header[:3], ["measurement", "n", "p50"])      # no app column when no line has one
        self.assertEqual(row[:2], ["viewer_photo", "2"])

    def test_mixed_lines_split_by_app(self):
        text = self.report([self.client(100), self.client(200, "ios"), self.client(300, "ios"),
                            self.client(400, "web"), self.server(5), self.server(6, "ios")])
        self.assertIn("2 server requests and 4 phone measurements", text)
        header, *rows = self.phone_rows(text)
        self.assertEqual(header[:4], ["measurement", "app", "n", "p50"])
        self.assertEqual({(r[1], r[2]) for r in rows}, {("ios", "2"), ("web", "1"), ("?", "1")})

    def test_app_filter_keeps_that_apps_lines(self):
        lines = [self.client(100), self.client(200, "ios"), self.client(300, "ios"), self.client(400, "web"),
                 self.server(5), self.server(6, "ios")]
        text = self.report(lines, "--app", "ios")
        self.assertIn("1 server requests and 2 phone measurements", text)
        self.assertIn("from the iPhone app only", text)
        _, row = self.phone_rows(text)
        self.assertEqual(row[1:3], ["ios", "2"])
        text = self.report(lines, "--app", "web")
        self.assertIn("0 server requests and 1 phone measurements", text)


if __name__ == "__main__":
    unittest.main()
