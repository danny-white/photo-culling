"""server.install_compression(): JSON is gzipped for clients that ask, the ETag goes weak and still
gets its 304, and nothing else is touched. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import gzip
import json
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
TRIAL_DB = ROOT / "trial_out" / "trial.db"
GZ = {"Accept-Encoding": "gzip"}
from review.tests.helpers import FakePC, anno_connection  # noqa: E402


@unittest.skipUnless(TRIAL_DB.exists(), "needs trial_out/trial.db")
class Compression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from flask import Flask, Response, send_file
        from PIL import Image
        import mobile
        import perf
        import server
        cls.tmp = tmp = Path(tempfile.mkdtemp())
        (tmp / "static").mkdir()
        (tmp / "inbox").mkdir()
        (tmp / "cache").mkdir()
        (tmp / "ios").mkdir()
        cls.ipa = bytes(range(256)) * 40                        # 10 KB, compressible, not JSON
        (tmp / "ios" / "CullingBay-9.ipa").write_bytes(cls.ipa)
        cls.json_file = tmp / "big.json"
        cls.json_file.write_text(json.dumps({"pad": "y" * 3000}))
        cls.perf_log = tmp / "perf.jsonl"

        def db_ro():
            con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            return con

        def anno():
            return anno_connection(tmp / "annotations.db")

        def fake_decode(path):
            return Image.new("RGB", (600, 400), "grey")

        app = Flask(__name__)
        perf.install(app, cls.perf_log)
        server.install_compression(app)                         # in main()'s order: after perf
        app.register_blueprint(mobile.make_blueprint(
            db_ro=db_ro, anno=anno, pc=FakePC(), cache_dir=tmp / "cache", static_dir=tmp / "static",
            state_dir=tmp / "state", inbox=tmp / "inbox", check_mount=False, ingest_log=tmp / "ingest.log",
            ollama_url="http://127.0.0.1:9", ios_dir=tmp / "ios", raw_decoder=fake_decode))

        @app.route("/sized/<int:n>")
        def sized(n):
            head = '{"p":"'
            return Response(head + "x" * (n - len(head) - 2) + '"}', mimetype="application/json")

        @app.route("/already")
        def already():
            return Response(gzip.compress(b'{"p":"' + b"x" * 2000 + b'"}'), mimetype="application/json",
                            headers={"Content-Encoding": "gzip"})

        @app.route("/sent-json")
        def sent_json():
            return send_file(cls.json_file, mimetype="application/json")

        @app.route("/error")
        def error():
            return Response('{"error":"' + "e" * 3000 + '"}', mimetype="application/json", status=409)

        cls.client = app.test_client()
        con = db_ro()
        try:
            cls.raw_id = con.execute(
                "SELECT rowid FROM images WHERE lower(filename) LIKE '%.arw' ORDER BY rowid LIMIT 1").fetchone()[0]
        finally:
            con.close()

    @classmethod
    def tearDownClass(cls):
        import shutil
        import perf
        for h in list(perf.LOG.handlers):
            if getattr(h, "baseFilename", None) == str(cls.perf_log.resolve()):
                perf.LOG.removeHandler(h)
                h.close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def get(self, path, **headers):
        r = self.client.get(path, headers=headers)
        r.get_data()                  # a streamed file can't be read after close
        r.close()
        return r

    def test_json_is_compressed_for_a_client_that_asks(self):
        plain = self.get("/m/api/days")
        r = self.get("/m/api/days", **GZ)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.headers["Content-Encoding"], "gzip")
        self.assertIn("Accept-Encoding", r.headers["Vary"])
        self.assertEqual(int(r.headers["Content-Length"]), len(r.data))
        self.assertLess(len(r.data), len(plain.data) / 3)
        self.assertEqual(gzip.decompress(r.data), plain.data)    # byte for byte the same JSON
        self.assertEqual(r.mimetype, "application/json")

    def test_nothing_changes_without_the_header_or_when_gzip_is_refused(self):
        for headers in ({}, {"Accept-Encoding": "identity"}, {"Accept-Encoding": "gzip;q=0, br"},
                        {"Accept-Encoding": "br"}):
            with self.subTest(headers):
                r = self.get("/m/api/days", **headers)
                self.assertNotIn("Content-Encoding", r.headers)
                self.assertNotIn("Vary", r.headers)
                self.assertFalse(r.headers["ETag"].startswith("W/"), "a plain body keeps its strong ETag")
                self.assertGreater(len(r.get_json()["days"]), 300)

    def test_a_browser_style_header_list_is_accepted(self):
        r = self.get("/m/api/days", **{"Accept-Encoding": "deflate, gzip;q=0.8, br"})
        self.assertEqual(r.headers["Content-Encoding"], "gzip")

    def test_small_bodies_are_left_alone(self):
        for n, packed in ((1023, False), (1024, True)):
            with self.subTest(n):
                r = self.get(f"/sized/{n}", **GZ)
                self.assertEqual(r.headers.get("Content-Encoding") == "gzip", packed)
                self.assertEqual(len(gzip.decompress(r.data) if packed else r.data), n)
        r = self.get("/m/api/gps-health?nope", **GZ)             # a JSON route of the blueprint, whatever its size
        self.assertEqual(r.status_code, 200)

    def test_the_weak_etag_still_gets_its_304(self):
        first = self.get("/m/api/days", **GZ)
        tag = first.headers["ETag"]
        self.assertTrue(tag.startswith('W/"'), tag)
        plain_tag = self.get("/m/api/days").headers["ETag"]
        self.assertEqual(tag, "W/" + plain_tag, "the tag is made from the uncompressed body")
        # what the iOS client does: send back whatever ETag it got
        again = self.get("/m/api/days", **GZ, **{"If-None-Match": tag})
        self.assertEqual((again.status_code, again.data), (304, b""))
        self.assertNotIn("Content-Encoding", again.headers)
        # a client without gzip holding the weak tag, and one holding the strong tag, are matched too
        self.assertEqual(self.get("/m/api/days", **{"If-None-Match": tag}).status_code, 304)
        self.assertEqual(self.get("/m/api/days", **GZ, **{"If-None-Match": plain_tag}).status_code, 304)
        # a tag from some other body is a fresh 200, compressed again
        other = self.get("/m/api/days", **GZ, **{"If-None-Match": 'W/"not-this-one"'})
        self.assertEqual((other.status_code, other.headers["Content-Encoding"]), (200, "gzip"))

    def test_the_timing_line_has_the_size_that_went_over_the_wire(self):
        import perf
        r = self.get("/m/api/days?wire=1", **GZ)
        for h in perf.LOG.handlers:
            h.flush()
        end = time.monotonic() + 3
        while True:
            lines = [json.loads(x) for x in self.perf_log.read_text().splitlines()]
            hit = [x for x in lines if x.get("path") == "/m/api/days?wire=1"]
            if hit or time.monotonic() > end:
                break
            time.sleep(0.02)
        self.assertEqual(hit[-1]["bytes"], len(r.data))

    def test_pictures_crops_and_downloads_are_never_compressed(self):
        for path, mimetype in ((f"/m/api/img/{self.raw_id}?s=thumb&warm=0", "image/jpeg"),
                               (f"/m/api/crop/{self.raw_id}?x=0.5&y=0.5&w=600&h=400", "image/jpeg"),
                               ("/m/ios/CullingBay-9.ipa", "application/octet-stream")):
            with self.subTest(path):
                r = self.get(path, **GZ)
                self.assertEqual((r.status_code, r.mimetype), (200, mimetype))
                self.assertNotIn("Content-Encoding", r.headers)
        self.assertEqual(self.get("/m/ios/CullingBay-9.ipa", **GZ).data, self.ipa)

    def test_what_is_already_encoded_or_streamed_or_not_a_200_is_not_touched(self):
        r = self.get("/already", **GZ)                           # no second layer of gzip
        self.assertEqual(r.headers["Content-Encoding"], "gzip")
        self.assertEqual(json.loads(gzip.decompress(r.data))["p"], "x" * 2000)
        r = self.get("/sent-json", **GZ)                         # send_file: direct passthrough
        self.assertNotIn("Content-Encoding", r.headers)
        self.assertEqual(r.data, self.json_file.read_bytes())
        r = self.get("/error", **GZ)
        self.assertEqual(r.status_code, 409)
        self.assertNotIn("Content-Encoding", r.headers)


if __name__ == "__main__":
    unittest.main()
