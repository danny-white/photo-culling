"""review/search.py on a small fake library: query parsing, date filters, and the rules that keep
meaning searches from returning noise."""
import http.server
import json
import sqlite3
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import search  # noqa: E402

ROOT = "/lib"


def unit(v):
    v = np.asarray(v, np.float32)
    return v / np.linalg.norm(v)


class FakePC:
    """Stands in for photo_cull: two embedding versions, a query embedder and a CLIP text half
    that both look words up in a table of vectors."""
    EMBED_VERSION, CLIP_VERSION, EMBED_MODEL = "cap:v1", "clip:v1", "cap"
    WORDS: dict[str, np.ndarray] = {}

    @staticmethod
    def unpack_vector(b):
        return np.frombuffer(b, np.float32)

    def infer_embed(self, base, key, model, text, timeout=30):
        return FakePC.WORDS[text]

    class Clip:
        def __init__(self, threads=0):
            pass

        def text(self, q):
            return FakePC.WORDS["pic:" + q]


def day_of(path):
    rel = path[len(ROOT) + 1:]
    return rel.rsplit("/", 1)[0]


def day_date(day):
    return day.rsplit("/", 1)[-1]


class SearchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rng = np.random.default_rng(3)
        cls.tmp = tempfile.TemporaryDirectory()
        db = Path(cls.tmp.name) / "trial.db"

        def db_ro():
            c = sqlite3.connect(db)
            c.row_factory = sqlite3.Row
            return c
        cls.con = con = db_ro()
        con.executescript("""
            CREATE TABLE images (path TEXT, filename TEXT, status TEXT, caption TEXT, subject TEXT, scene TEXT,
              activity TEXT, tags TEXT, animals TEXT, content_type TEXT, place TEXT, processed_at TEXT);
            CREATE TABLE embeddings (path TEXT, embed_version TEXT, model TEXT, dims INTEGER, vector BLOB, created_at TEXT);
            CREATE TABLE day_summaries (folder TEXT, summary TEXT, created_at TEXT);""")
        # 3 days of 40 photos, random directions; a few planted on purpose below
        cap_q, pic_q = unit(rng.normal(size=64)), unit(rng.normal(size=32))
        FakePC.WORDS = {"kayak": cap_q, "pic:kayak": pic_q, "lanai": unit(rng.normal(size=64)),
                        "pic:lanai": unit(rng.normal(size=32))}
        rows = []
        for d, day in enumerate(("2019/2019-07-04", "2025/2025-05-25", "2026/2026-09-29")):
            for k in range(40):
                path = f"{ROOT}/{day}/DSC0{d}{k:03d}.ARW"
                cap, pic, caption = rng.normal(size=64), rng.normal(size=32), f"photo {k}"
                if day.startswith("2025") and k < 5:          # kayaks: both signals agree
                    cap, pic, caption = cap_q * 8 + cap * .1, pic_q * 8 + pic * .1, "a person paddling a yellow kayak"
                if day.startswith("2026") and k < 3:          # look like kayaks to CLIP, captions disagree
                    cap, pic, caption = -cap_q * 3 + cap, pic_q * 8 + pic * .1, "a deer in a park"
                if day.startswith("2019") and k == 0:         # the word, in a caption the vector misses
                    caption = "kayak rack on a car"
                rows.append((path, caption, unit(cap), unit(pic)))
        for path, caption, cap, pic in rows:
            con.execute("INSERT INTO images VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                        (path, Path(path).name, "ok", caption, "", "", "", json.dumps([]), "", "", None, ""))
            con.execute("INSERT INTO embeddings VALUES (?,?,?,?,?,?)", (path, "cap:v1", "cap", 64, cap.tobytes(), "t"))
            con.execute("INSERT INTO embeddings VALUES (?,?,?,?,?,?)", (path, "clip:v1", "clip", 32, pic.tobytes(), "t"))
        con.execute("INSERT INTO day_summaries VALUES (?,?,?)", (f"{ROOT}/2026/2026-09-29", "Seabird chicks on Lanai.", "t"))
        con.commit()
        cls.s = search.Search(db_ro=db_ro, pc=FakePC(), day_of=day_of, day_date=day_date,
                              ollama_url="http://x", library_root=ROOT, embed=lambda text: FakePC.WORDS[text])

    @classmethod
    def tearDownClass(cls):
        cls.con.close()
        cls.tmp.cleanup()

    def test_parse(self):
        self.assertEqual(search.parse("snow 2019")[0], ["snow"])
        self.assertEqual(search.parse("29 sept")[1]["mdays"], {29})
        self.assertEqual(search.parse("may")[0], ["may"])                   # a word, not a month...
        self.assertEqual(search.parse("may 2024")[1]["months"], {5})        # ...unless next to a year
        self.assertEqual(search.parse("2 dogs")[0], ["2", "dogs"])

    def test_date_ok(self):
        f = search.parse("june 2015")[1]
        self.assertTrue(search.date_ok("2015-06-29", f))
        self.assertFalse(search.date_ok("2016-06-29", f))
        self.assertTrue(search.date_ok("2026-10-01", search.parse("2026-10")[1]))

    def test_words_captions_and_agreeing_pictures(self):
        r = self.s.search("kayak")
        days = {d["day"]: d for d in r["days"]}
        self.assertEqual(days["2025/2025-05-25"]["n"], 5)
        self.assertEqual(days["2019/2019-07-04"]["n"], 1, "a word match alone still counts")
        # the deer look like kayaks to CLIP, but their captions disagree: not matches
        self.assertNotIn("2026/2026-09-29", days)
        self.assertEqual(r["days"][0]["day"], "2025/2025-05-25")
        self.assertEqual(len(days["2025/2025-05-25"]["match_ids"]), 5)

    def test_date_filter_applies_before_the_cut(self):
        r = self.s.search("kayak 2019")
        self.assertEqual([d["day"] for d in r["days"]], ["2019/2019-07-04"])

    def test_dates_alone_list_days(self):
        r = self.s.search("2025")
        self.assertEqual([d["day"] for d in r["days"]], ["2025/2025-05-25"])

    def test_file_names_skip_meaning(self):
        r = self.s.search("DSC01003")
        self.assertEqual(r["signals"], ["words"])
        self.assertEqual(r["photos"], 1)

    def test_summary_words_find_the_day(self):
        r = self.s.search("lanai")
        self.assertEqual([(d["day"], d["why"]) for d in r["days"]], [("2026/2026-09-29", "In the day’s summary")])

    def test_like_skips_its_own_day(self):
        rid = self.con.execute("SELECT rowid FROM images WHERE caption LIKE '%yellow kayak%' LIMIT 1").fetchone()[0]
        r = self.s.like(rid)
        self.assertTrue(r["days"])
        self.assertNotIn("2025/2025-05-25", [d["day"] for d in r["days"]])
        self.assertEqual(r["days"][0]["day"], "2026/2026-09-29", "the deer look like it")
        self.assertIsNone(self.s.like(10 ** 9))

    def test_photos_rank_matches_across_days(self):
        r = self.s.photos("kayak")
        self.assertEqual(r["total"], 6)
        self.assertEqual(len(r["ids"]), 6)
        days = [day_of(self.con.execute("SELECT path FROM images WHERE rowid=?", (i,)).fetchone()[0]) for i in r["ids"]]
        self.assertEqual(days[0], "2025/2025-05-25", "the day with five kayaks has the strongest matches")
        self.assertIn("2019/2019-07-04", days)
        self.assertNotIn("2026/2026-09-29", days)

    def test_photos_for_dates_alone_newest_first(self):
        r = self.s.photos("2025")
        self.assertEqual(r["signals"], ["dates"])
        self.assertTrue(r["ids"])
        self.assertEqual(r["total"], len(r["ids"]))

    def test_like_photos_include_its_own_day_but_not_itself(self):
        rid = self.con.execute("SELECT rowid FROM images WHERE caption LIKE '%yellow kayak%' LIMIT 1").fetchone()[0]
        r = self.s.like_photos(rid)
        self.assertTrue(r["ids"])
        self.assertNotIn(rid, r["ids"])
        self.assertIsNone(self.s.like_photos(10 ** 9))


class Clock:
    """A clock the tests move by hand; installed in search's own `time`, so nothing else sees it."""

    def __init__(self):
        self.now = 1_000_000.0

    def __call__(self):
        return self.now

    def patched(self):
        return patch.object(search, "time", types.SimpleNamespace(time=self, perf_counter=time.perf_counter))


class Lib:
    """A tiny library in a temp DB that tests add to and change in place, with a Search over it that
    counts how many times it builds its index."""

    SCHEMA = """
        CREATE TABLE images (path TEXT, filename TEXT, status TEXT, caption TEXT, subject TEXT, scene TEXT,
          activity TEXT, tags TEXT, animals TEXT, content_type TEXT, place TEXT, processed_at TEXT);
        CREATE TABLE embeddings (path TEXT, embed_version TEXT, model TEXT, dims INTEGER, vector BLOB, created_at TEXT,
          PRIMARY KEY (path, embed_version));
        CREATE TABLE day_summaries (folder TEXT PRIMARY KEY, summary TEXT, created_at TEXT);"""

    def __init__(self, tmp, photos=4, **kw):
        self.db = Path(tmp) / "trial.db"
        self.rng = np.random.default_rng(5)
        con = self.connect()
        con.executescript(self.SCHEMA)
        con.close()
        for i in range(photos):
            self.add(f"DSC{i:04d}.ARW")
        self.builds = []
        self.s = search.Search(db_ro=self.connect, pc=FakePC(), day_of=day_of, day_date=day_date,
                               ollama_url="http://x", library_root=ROOT, embed=lambda text: FakePC.WORDS[text], **kw)
        real = self.s._load

        def counting(con):
            self.builds.append(time.monotonic())
            return real(con)
        self.s._load = counting

    def connect(self):
        c = sqlite3.connect(self.db)
        c.row_factory = sqlite3.Row
        return c

    def change(self, sql, *args):
        con = self.connect()
        with con:
            con.execute(sql, args)
        con.close()

    def add(self, name, day="2025/2025-05-25", status="ok", embeddings=True):
        con = self.connect()
        with con:
            path = f"{ROOT}/{day}/{name}"
            con.execute("INSERT INTO images (path, filename, status, caption, processed_at) VALUES (?,?,?,?,?)",
                        (path, name, status, f"photo {name}", "2026-11-24T10:00:00"))
            if embeddings:
                for version, dims in (("cap:v1", 8), ("clip:v1", 4)):
                    v = unit(self.rng.normal(size=dims))
                    con.execute("INSERT INTO embeddings VALUES (?,?,?,?,?,?)", (path, version, "m", dims, v.tobytes(), "t"))
        con.close()


class IndexRefreshTest(unittest.TestCase):
    """The index is rebuilt when the library changes, not on a timer, and never under the lock."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.lib = Lib(self.tmp.name)
        self.clock = Clock()
        patcher = self.clock.patched()
        patcher.start()
        self.addCleanup(patcher.stop)

    def later(self, seconds):
        self.clock.now += seconds

    def test_an_unchanged_library_is_not_reloaded(self):
        first = self.lib.s.index()
        for minutes in (2, 11, 25, 60, 600):   # the old 10-minute bucket would have rebuilt at the second
            self.later(minutes * 60)
            self.assertIs(self.lib.s.index(), first)
        self.assertEqual(len(self.lib.builds), 1)

    def test_it_is_only_looked_at_every_refresh_interval(self):
        self.lib.s.index()
        self.lib.add("DSC9999.ARW")
        self.later(search.REFRESH_S - 1)
        self.assertEqual(len(self.lib.s.index()["ids"]), 4, "too soon to look")
        self.later(2)
        self.assertEqual(len(self.lib.s.index()["ids"]), 5)

    def test_a_daily_backstop_rebuilds_an_unchanged_library(self):
        self.lib.s.index()
        self.later(search.BACKSTOP_S - 100)
        self.lib.s.index()
        self.assertEqual(len(self.lib.builds), 1)
        self.later(200)
        self.lib.s.index()
        self.assertEqual(len(self.lib.builds), 2)

    def test_a_new_photo_reloads(self):
        self.lib.s.index()
        self.lib.add("DSC9999.ARW")
        self.later(search.REFRESH_S + 1)
        idx = self.lib.s.index()
        self.assertEqual(len(self.lib.builds), 2)
        self.assertEqual(len(idx["ids"]), 5)

    def test_changes_made_in_place_reload_too(self):
        images = "UPDATE images SET {} WHERE filename='DSC0001.ARW'"
        changes = {
            "a vector added later": lambda: (self.lib.add("DSC7000.ARW", embeddings=False),
                                             self.lib.change("INSERT INTO embeddings VALUES (?,?,?,?,?,?)",
                                                             f"{ROOT}/2025/2025-05-25/DSC7000.ARW", "cap:v1", "m", 8,
                                                             unit(np.ones(8)).tobytes(), "t")),
            "an error row that became ok": lambda: self.lib.change(
                "UPDATE images SET status='ok' WHERE filename='DSC6000.ARW'"),
            "a photo retagged": lambda: self.lib.change(images.format("processed_at='2026-11-25T09:00:00'")),
            "a photo geotagged": lambda: self.lib.change(images.format("place='kihei, hawaii, us'")),
            "a day summary": lambda: self.lib.change("INSERT INTO day_summaries VALUES (?,?,?)",
                                                     f"{ROOT}/2025/2025-05-25", "Paddling.", "t"),
        }
        self.lib.add("DSC6000.ARW", status="error", embeddings=False)
        for what, make in changes.items():
            with self.subTest(what):
                self.lib.s.index()
                before = len(self.lib.builds)
                make()
                self.later(search.REFRESH_S + 1)
                self.lib.s.index()
                self.assertEqual(len(self.lib.builds), before + 1)
                self.later(search.REFRESH_S + 1)          # and then nothing more to do
                self.lib.s.index()
                self.assertEqual(len(self.lib.builds), before + 1)

    def test_a_library_with_no_day_summaries_table_still_loads(self):
        self.lib.change("DROP TABLE day_summaries")
        self.assertEqual(len(self.lib.s.index()["ids"]), 4)
        self.later(search.REFRESH_S + 1)
        self.lib.s.index()
        self.assertEqual(len(self.lib.builds), 1)

    def test_a_failed_build_keeps_the_old_index_and_says_so(self):
        old = self.lib.s.index()
        self.lib.add("DSC9999.ARW")
        self.later(search.REFRESH_S + 1)
        real = self.lib.s._load
        self.lib.s._load = lambda con: (_ for _ in ()).throw(sqlite3.OperationalError("database is locked"))
        with self.assertLogs("search", "WARNING") as logs:
            self.assertIs(self.lib.s.index(), old, "searches carry on with the index they have")
        self.assertIn("keeping the old one: OperationalError: database is locked", logs.output[0])
        self.assertIs(self.lib.s.index(), old)           # not retried on every search
        self.lib.s._load = real
        self.later(search.REFRESH_S + 1)
        self.assertEqual(len(self.lib.s.index()["ids"]), 5, "the next look finds the change and builds it")

    def test_a_failed_first_build_raises_and_the_next_search_tries_again(self):
        real = self.lib.s._load
        self.lib.s._load = lambda con: (_ for _ in ()).throw(sqlite3.OperationalError("database is locked"))
        with self.assertRaises(sqlite3.OperationalError):
            self.lib.s.index()
        self.lib.s._load = real
        self.assertEqual(len(self.lib.s.index()["ids"]), 4)

    def slow_loads(self, seconds):
        real = self.lib.s._load

        def slow(con):
            time.sleep(seconds)
            return real(con)
        self.lib.s._load = slow

    def test_searches_that_arrive_together_build_the_index_once(self):
        self.slow_loads(0.3)
        got, errors = [], []

        def go():
            try:
                got.append(self.lib.s.index())
            except Exception as e:  # noqa: BLE001
                errors.append(e)
        threads = [threading.Thread(target=go) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(10)
        self.assertEqual(errors, [])
        self.assertEqual(len(self.lib.builds), 1)
        self.assertEqual(len(got), 8)
        self.assertTrue(all(i is got[0] for i in got), "they all waited for the one build")

    def test_while_a_new_index_builds_searches_use_the_old_one_without_waiting(self):
        old = self.lib.s.index()
        self.lib.add("DSC9999.ARW")
        self.later(search.REFRESH_S + 1)
        self.slow_loads(0.6)
        builder = threading.Thread(target=self.lib.s.index)
        builder.start()
        time.sleep(0.15)                                  # the build is under way
        t = time.monotonic()
        seen = [self.lib.s.index() for _ in range(5)]
        waited = time.monotonic() - t
        builder.join(10)
        self.assertTrue(all(i is old for i in seen))
        self.assertLess(waited, 0.3, f"searches waited {waited:.2f}s for the build")
        self.assertEqual(len(self.lib.builds), 2, "one build, however many searches came")
        self.assertEqual(len(self.lib.s.index()["ids"]), 5)

    def test_the_lock_is_free_while_the_index_builds(self):
        self.lib.s.index()
        self.lib.add("DSC9999.ARW")
        self.later(search.REFRESH_S + 1)
        self.slow_loads(0.5)
        builder = threading.Thread(target=self.lib.s.index)
        builder.start()
        time.sleep(0.1)
        self.assertTrue(self.lib.s.lock.acquire(timeout=0.1), "the build holds the lock")
        self.lib.s.lock.release()
        builder.join(10)


class ClipOnceTest(unittest.TestCase):
    def test_two_first_searches_load_clip_once(self):
        made = []

        class SlowClip:
            def __init__(self, threads=0):
                made.append(self)
                time.sleep(0.2)

        pc = FakePC()
        pc.Clip = SlowClip
        with tempfile.TemporaryDirectory() as tmp:
            lib = Lib(tmp)
            s = search.Search(db_ro=lib.connect, pc=pc, day_of=day_of, day_date=day_date, ollama_url="http://x",
                              library_root=ROOT)
            got = []
            threads = [threading.Thread(target=lambda: got.append(s.clip)) for _ in range(8)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(10)
        self.assertEqual(len(made), 1)
        self.assertTrue(all(c is made[0] for c in got) and len(got) == 8)


class FakeOllama(http.server.BaseHTTPRequestHandler):
    seen: list = []
    status = 200

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeOllama.seen.append((self.path, body))
        payload = json.dumps({"embeddings": [[3.0, 4.0]]} if self.status == 200 else {"error": "model not found"}).encode()
        self.send_response(self.status)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        pass


class CaptionQueryTest(unittest.TestCase):
    def setUp(self):
        FakeOllama.seen, FakeOllama.status = [], 200
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.shutdown)
        self.addCleanup(self.httpd.server_close)
        self.s = search.Search(db_ro=None, pc=FakePC(), day_of=day_of, day_date=day_date,
                               ollama_url=f"http://127.0.0.1:{self.httpd.server_address[1]}/", library_root=ROOT)

    def test_the_query_goes_to_api_embed_and_asks_ollama_to_keep_the_model(self):
        v = self.s._caption_vec("a red kayak")
        self.assertEqual(FakeOllama.seen, [("/api/embed", {"model": "cap", "input": "a red kayak", "keep_alive": "2h"})])
        np.testing.assert_allclose(v, [0.6, 0.8])             # unit length, whatever Ollama returned

    def test_an_ollama_error_reaches_the_search_notes(self):
        FakeOllama.status = 404
        with self.assertRaisesRegex(RuntimeError, r"HTTP 404: .*model not found"):
            self.s._caption_vec("kayak")

    def test_prime_loads_clip_and_the_caption_model_and_never_raises(self):
        pc = FakePC()
        calls = []
        pc.Clip = type("C", (), {"__init__": lambda self, threads=0: None,
                                 "text": lambda self, q: calls.append(("clip", q))})
        s = search.Search(db_ro=None, pc=pc, day_of=day_of, day_date=day_date, ollama_url="http://x", library_root=ROOT,
                          embed=lambda text: calls.append(("caption", text)) or [1.0, 0.0])
        s.prime()
        self.assertEqual([c[0] for c in calls], ["clip", "caption"])
        broken = search.Search(db_ro=None, pc=pc, day_of=day_of, day_date=day_date, ollama_url="http://x",
                               library_root=ROOT, embed=lambda text: 1 / 0)
        with self.assertLogs("search", "WARNING") as logs:
            broken.prime()
        self.assertIn("caption model failed: ZeroDivisionError", logs.output[0])


if __name__ == "__main__":
    unittest.main()
