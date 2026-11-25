"""The server under a real waitress server (the way it runs live), not Flask's test client: connections
stay open, the timing log still gets its lines, HEAD works, a big file streams, and a burst of slow
crops leaves threads for a decide. Everything binds 127.0.0.1 on a free port. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import hashlib
import http.client
import json
import os
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
TRIAL_DB = ROOT / "trial_out" / "trial.db"
DAY = "2026/2026-10-01"
from review.tests.helpers import anno_connection  # noqa: E402


class Served:
    """A Flask app served by waitress with the settings server.py uses, on a free local port."""

    def __init__(self, app):
        import waitress
        import server
        self.srv = waitress.create_server(app, host="127.0.0.1", port=0, **server.WAITRESS)
        self.port = self.srv.effective_port
        self.thread = threading.Thread(target=self.srv.run, daemon=True, name="waitress-test")
        self.thread.start()

    def conn(self) -> http.client.HTTPConnection:
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)

    def close(self):
        self.srv.close()
        self.thread.join(10)


def drop_perf_handler(log: Path):
    import perf
    for h in list(perf.LOG.handlers):
        if getattr(h, "baseFilename", None) == str(log.resolve()):
            perf.LOG.removeHandler(h)
            h.close()


class WaitressServing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from flask import Flask, jsonify, send_file
        import mobile
        import perf
        cls.tmp = tempfile.TemporaryDirectory()
        tmp = Path(cls.tmp.name)
        cls.perf_log = tmp / "perf.jsonl"
        (tmp / "ios").mkdir()
        (tmp / "static").mkdir()
        (tmp / "static" / "index.html").write_text("<!doctype html><title>Culling Bay</title>")
        cls.big = tmp / "ios" / "CullingBay-999.ipa"
        digest = hashlib.sha256()
        with cls.big.open("wb") as f:
            for _ in range(50):
                block = os.urandom(1024 * 1024)
                digest.update(block)
                f.write(block)
        cls.big_sha = digest.hexdigest()
        small = tmp / "small.bin"
        small.write_bytes(b"x" * 5000)

        app = Flask(__name__)
        perf.install(app, cls.perf_log)

        @app.route("/probe")
        def probe():
            return jsonify(ok=True, items=list(range(50)))

        @app.route("/small")
        def small_file():
            return send_file(small)

        unavailable_db = Mock(side_effect=AssertionError("these routes need no database"))
        with patch.object(mobile.search, "Search"):
            app.register_blueprint(mobile.make_blueprint(
                db_ro=unavailable_db, anno=unavailable_db, pc=Mock(), cache_dir=tmp, static_dir=tmp / "static",
                state_dir=tmp / "state", inbox=tmp / "inbox", check_mount=False, ios_dir=tmp / "ios"))
        cls.served = Served(app)

    @classmethod
    def tearDownClass(cls):
        cls.served.close()
        drop_perf_handler(cls.perf_log)
        cls.tmp.cleanup()

    def line_for(self, method, path, seconds=5.0):
        """The timing-log line for a request; it is written once the body has gone out."""
        import perf
        end = time.monotonic() + seconds
        while True:
            for h in perf.LOG.handlers:
                h.flush()
            lines = [json.loads(x) for x in self.perf_log.read_text().splitlines()]
            found = [x for x in lines if x.get("path") == path and x.get("method") == method]
            if found or time.monotonic() > end:
                self.assertTrue(found, f"no timing line for {method} {path}")
                return found[-1]
            time.sleep(0.02)

    def test_requests_share_one_connection(self):
        c = self.served.conn()
        local_ports = set()
        for _ in range(3):
            c.request("GET", "/probe?keepalive=1")
            r = c.getresponse()
            body = json.loads(r.read())
            self.assertEqual((r.status, body["ok"]), (200, True))
            self.assertFalse(r.will_close, "waitress must not answer Connection: close")
            local_ports.add(c.sock.getsockname()[1])      # a new connection would have a new local port
        self.assertEqual(len(local_ports), 1)
        self.assertEqual(r.getheader("Server"), "waitress")
        c.close()

    def test_timing_lines_for_a_json_route_and_a_sent_file(self):
        c = self.served.conn()
        c.request("GET", "/probe?timing=1")
        r = c.getresponse()
        r.read()
        self.assertIn("total;dur=", r.getheader("Server-Timing"))
        c.request("GET", "/small?timing=1")
        r = c.getresponse()
        self.assertEqual(r.read(), b"x" * 5000)
        c.close()
        for path, size in (("/probe?timing=1", None), ("/small?timing=1", 5000)):
            line = self.line_for("GET", path)
            self.assertEqual(line["status"], 200, path)
            self.assertIn("send_ms", line, path)
            self.assertGreaterEqual(line["send_ms"], line["ms"])
            if size:
                self.assertEqual(line["bytes"], size)

    def test_head_requests(self):
        c = self.served.conn()
        c.request("GET", "/probe?head=1")
        r = c.getresponse()
        length = len(r.read())
        for path, size in (("/probe?head=1", length), ("/small?head=1", 5000)):
            c.request("HEAD", path)
            r = c.getresponse()
            self.assertEqual((r.status, r.read()), (200, b""), path)
            self.assertEqual(int(r.getheader("Content-Length")), size, path)
        c.request("GET", "/probe?head=1")                   # and the connection is still good
        self.assertEqual(c.getresponse().status, 200)
        c.close()
        self.assertEqual(self.line_for("HEAD", "/small?head=1")["status"], 200)

    def test_a_large_file_streams_whole(self):
        c = self.served.conn()
        c.request("GET", "/m/ios/CullingBay-999.ipa")
        r = c.getresponse()
        self.assertEqual(r.status, 200)
        size = int(r.getheader("Content-Length"))
        digest, got = hashlib.sha256(), 0
        while chunk := r.read(1024 * 1024):
            digest.update(chunk)
            got += len(chunk)
        self.assertEqual((got, size), (50 * 1024 * 1024, 50 * 1024 * 1024))
        self.assertEqual(digest.hexdigest(), self.big_sha)
        c.request("GET", "/probe?after=big")                 # the same connection carries on
        self.assertEqual(c.getresponse().status, 200)
        c.close()
        line = self.line_for("GET", "/m/ios/CullingBay-999.ipa")
        self.assertEqual((line["status"], line["bytes"]), (200, 50 * 1024 * 1024))
        self.assertIn("send_ms", line)


class GzipUnderWaitress(unittest.TestCase):
    """install_compression() over a real connection: the body that arrives is gzip, the connection
    stays open, and a client that doesn't ask gets plain JSON."""

    @classmethod
    def setUpClass(cls):
        from flask import Flask, jsonify, request
        import perf
        import server
        cls.tmp = tempfile.TemporaryDirectory()
        cls.perf_log = Path(cls.tmp.name) / "perf.jsonl"
        app = Flask(__name__)
        perf.install(app, cls.perf_log)
        server.install_compression(app)

        @app.route("/big")
        def big():
            resp = jsonify(items=[{"n": i, "name": f"photo {i}"} for i in range(400)])
            resp.add_etag()                    # what the mobile blueprint's revalidate hook does
            return resp.make_conditional(request)

        cls.served = Served(app)

    @classmethod
    def tearDownClass(cls):
        cls.served.close()
        drop_perf_handler(cls.perf_log)
        cls.tmp.cleanup()

    def test_gzip_over_a_kept_open_connection(self):
        import gzip
        c = self.served.conn()
        c.request("GET", "/big")
        plain = c.getresponse()
        plain_body = plain.read()
        self.assertIsNone(plain.getheader("Content-Encoding"))
        ports = {c.sock.getsockname()[1]}
        c.request("GET", "/big", headers={"Accept-Encoding": "gzip"})
        r = c.getresponse()
        body = r.read()
        ports.add(c.sock.getsockname()[1])
        self.assertEqual(r.getheader("Content-Encoding"), "gzip")
        self.assertEqual(int(r.getheader("Content-Length")), len(body))
        self.assertLess(len(body), len(plain_body) / 3)
        self.assertEqual(gzip.decompress(body), plain_body)
        self.assertTrue(r.getheader("ETag").startswith('W/"'))
        self.assertEqual(len(ports), 1, "one connection carried both")
        # (waitress 3 answers every 304 with Connection: close, so the connection isn't checked after it)
        c.request("GET", "/big", headers={"Accept-Encoding": "gzip", "If-None-Match": r.getheader("ETag")})
        again = c.getresponse()
        self.assertEqual((again.status, again.read()), (304, b""))
        c.close()


@unittest.skipUnless(TRIAL_DB.exists(), "needs trial_out/trial.db")
class SlowCropsLeaveRoomForDecides(unittest.TestCase):
    """A 1:1 crop can hold a thread for seconds (a NAS read, or waiting for one of the two decode
    slots). The development server had a thread for every connection; waitress has 16. A burst
    of slow crops, more than the phone sends at once, must not hold up a tap."""

    CROPS = 12
    DECODE_S = 0.7

    @classmethod
    def setUpClass(cls):
        from flask import Flask
        from PIL import Image
        import mobile
        import photo_cull as pc
        cls.tmp = tempfile.TemporaryDirectory()
        tmp = Path(cls.tmp.name)

        def slow_decode(path):
            time.sleep(cls.DECODE_S)
            return Image.new("RGB", (600, 400), "grey")

        def slow_region(path, x, y, w, h):
            time.sleep(cls.DECODE_S)
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
            db_ro=db_ro, anno=anno, pc=pc, cache_dir=tmp, static_dir=tmp / "static", state_dir=tmp / "state",
            inbox=tmp / "inbox", check_mount=False, ingest_log=tmp / "ingest.log",
            ollama_url="http://127.0.0.1:9", raw_decoder=slow_decode, region_decoder=slow_region))
        cls.served = Served(app)
        con = db_ro()
        try:
            cls.raws = [r[0] for r in con.execute(
                "SELECT rowid FROM images WHERE lower(filename) LIKE '%.arw' ORDER BY rowid LIMIT ?", (cls.CROPS,))]
        finally:
            con.close()

    @classmethod
    def tearDownClass(cls):
        cls.served.close()
        cls.tmp.cleanup()

    def get(self, path):
        c = self.served.conn()
        c.request("GET", path)
        r = c.getresponse()
        body = r.read()
        c.close()
        return r.status, body

    def test_a_decide_goes_through_while_slow_crops_fill_threads(self):
        status, body = self.get(f"/m/api/day/{DAY}")
        self.assertEqual(status, 200)
        frame = json.loads(body)["stacks"][0]["frames"][0]["id"]
        done, crop_status = [], []

        def crop(rowid, keep0):
            status, _ = self.get(f"/m/api/crop/{rowid}?x=0.5&y=0.5&w=200&h=200" + ("&keep=0" if keep0 else ""))
            crop_status.append(status)
            done.append(time.monotonic())

        t0 = time.monotonic()
        threads = [threading.Thread(target=crop, args=(rid, i % 2 == 0)) for i, rid in enumerate(self.raws)]
        for t in threads:
            t.start()
        time.sleep(0.25)                                    # all of them are in a thread, waiting or decoding
        c = self.served.conn()
        t = time.monotonic()
        c.request("POST", "/m/api/decide", body=json.dumps(
            {"action_id": "slow-crops", "day": DAY, "label": "Kept",
             "changes": [{"id": frame, "flag": "pick", "via": "card"}]}),
            headers={"X-Culling-Bay": "1", "Content-Type": "application/json"})
        r = c.getresponse()
        decide = time.monotonic() - t
        self.assertEqual((r.status, json.loads(r.read())["ok"]), (200, True))
        c.close()
        still_running = sum(1 for t in threads if t.is_alive())
        for t in threads:
            t.join(60)
        burst = max(done) - t0
        self.assertEqual(crop_status, [200] * self.CROPS)
        self.assertGreater(still_running, self.CROPS // 2, "the decide should have overlapped the burst")
        self.assertLess(decide, 0.5, f"a decide took {decide:.2f}s beside a {burst:.1f}s burst of slow crops")


if __name__ == "__main__":
    unittest.main()
