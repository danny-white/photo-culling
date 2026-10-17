"""review/search.py on a small fake library: query parsing, date filters, and the rules that keep
meaning searches from returning noise."""
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

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
                              ollama_url="http://x", library_root=ROOT)

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


if __name__ == "__main__":
    unittest.main()
