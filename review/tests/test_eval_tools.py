"""eval/ tools (caption-accuracy eval): the sampler's rules, todo batching, and the scorer.

These use synthetic data only (a temp sqlite table, hand-made label and grade files); they never
touch trial_out/trial.db or the real eval/ directories.
"""
import hashlib
import json
import sqlite3
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "eval"))
sys.path.insert(0, str(ROOT))
import sample  # noqa: E402
import score  # noqa: E402
import todo  # noqa: E402

CAMERAS = {
    "Sony A7R III/IIIA": "SONY ILCE-7RM3",
    "Canon T5i": "Canon Canon EOS REBEL T5i",
    "Nikon D40/D60": "NIKON CORPORATION NIKON D40",
    "Canon R6": "Canon Canon EOS R6",
    "iPhone/other": "Apple iPhone 17 Pro",
}
SCENES = ["portrait", "landscape", "street", "wildlife", "night"]


def make_db(path: Path, rows: list) -> None:
    con = sqlite3.connect(path)
    con.execute("""CREATE TABLE images (path TEXT PRIMARY KEY, status TEXT, camera TEXT, scene TEXT,
        people_count INTEGER, burst_id INTEGER, caption TEXT, subject TEXT, tags TEXT, activity TEXT,
        indoor_outdoor TEXT, time_of_day TEXT, animals TEXT, content_type TEXT, visible_text TEXT,
        prompt_version TEXT, model_used TEXT)""")
    for r in rows:
        con.execute("INSERT INTO images VALUES (:path,:status,:camera,:scene,:people_count,:burst_id,:caption,"
                    ":subject,:tags,:activity,:indoor_outdoor,:time_of_day,:animals,:content_type,"
                    ":visible_text,:prompt_version,:model_used)", r)
    con.commit()
    con.close()


def row(path, camera="SONY ILCE-7RM3", scene="portrait", people=0, burst=None, status="ok",
        caption="a caption", content_type="photo"):
    return {"path": path, "status": status, "camera": camera, "scene": scene, "people_count": people,
            "burst_id": burst, "caption": caption, "subject": "s", "tags": json.dumps(["a", "b"]),
            "activity": "", "indoor_outdoor": "outdoor", "time_of_day": "day", "animals": "[]",
            "content_type": content_type, "visible_text": "", "prompt_version": "v", "model_used": "m"}


def synthetic_library(per_day=14, days_per_era=None):
    """Shoot days for every era, each era with days in both splits; Canon R6 and iPhone/other are rare."""
    days_per_era = days_per_era or {"Sony A7R III/IIIA": 40, "Canon T5i": 24, "Nikon D40/D60": 16,
                                    "Canon R6": 4, "iPhone/other": 4}
    rows, burst, n = [], 0, 0
    for era, want in days_per_era.items():
        got = {"dev": 0, "test": 0}
        while min(got.values()) < want // 2:
            n += 1
            day = f"2024-{n // 28 + 1:02d}-{n % 28 + 1:02d}"
            split = sample.split_of(day)
            if got[split] >= want // 2:
                continue
            got[split] += 1
            for k in range(per_day):
                burst += 1
                rows.append(row(f"/lib/2024/{day}/IMG_{k:04d}.JPG", CAMERAS[era], SCENES[(n + k) % len(SCENES)],
                                people=(k % 2), burst=burst))
    return rows


class SamplerRules(unittest.TestCase):
    def test_split_is_stable_and_by_folder_name(self):
        self.assertEqual(sample.split_of("2024-04-12"), sample.split_of("2024-04-12"))
        want = "dev" if hashlib.sha1(b"2024-04-12").digest()[0] % 2 == 0 else "test"
        self.assertEqual(sample.split_of("2024-04-12"), want)
        self.assertEqual(sample.day_of("/mnt/passport/Pictures/2024/2024-04-12/IMG_1.JPG"), "2024-04-12")
        splits = {sample.split_of(f"2024-{m:02d}-{d:02d}") for m in range(1, 13) for d in range(1, 29)}
        self.assertEqual(splits, {"dev", "test"})

    def test_era_groups(self):
        self.assertEqual(sample.era_of("SONY ILCE-7RM3A"), "Sony A7R III/IIIA")
        self.assertEqual(sample.era_of("Canon Canon EOS REBEL T5i"), "Canon T5i")
        self.assertEqual(sample.era_of("NIKON CORPORATION NIKON D60"), "Nikon D40/D60")
        self.assertEqual(sample.era_of("Canon Canon EOS R6"), "Canon R6")
        self.assertEqual(sample.era_of(None), "iPhone/other")
        self.assertEqual(sample.era_of("Research In Motion BlackBerry 9630"), "iPhone/other")

    def test_query_filters_and_is_read_only(self):
        with tempfile.TemporaryDirectory() as t:
            db = Path(t) / "t.db"
            make_db(db, [row("/l/d1/a.JPG"), row("/l/d1/b.JPG", status="error"), row("/l/d1/c.JPG", caption=""),
                         row("/l/d1/d.JPG", content_type="screenshot"), row("/l/d1/e.JPG", content_type=None)])
            got = sample.load_rows(db)
            self.assertEqual(sorted(r["path"] for r in got), ["/l/d1/a.JPG", "/l/d1/e.JPG"])
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            with self.assertRaises(sqlite3.OperationalError):
                con.execute("DELETE FROM images")   # what load_rows opens: it cannot write
            con.close()

    def test_raw_jpeg_pair_keeps_one(self):
        rows = [dict(row("/l/d1/DSC1.ARW"), id=1), dict(row("/l/d1/DSC1.JPG"), id=2),
                dict(row("/l/d1/DSC2.ARW"), id=3), dict(row("/l/d2/DSC1.ARW"), id=4)]
        kept = [r["path"] for r in sample.dedupe_pairs(rows)]
        self.assertEqual(sorted(kept), ["/l/d1/DSC1.JPG", "/l/d1/DSC2.ARW", "/l/d2/DSC1.ARW"])

    def test_one_per_burst_and_null_burst_is_its_own(self):
        rows = [dict(row(f"/l/d1/{i}.JPG", burst=7), id=i) for i in range(5)]
        rows += [dict(row(f"/l/d1/n{i}.JPG", burst=None), id=100 + i) for i in range(3)]
        reps = sample.one_per_burst(rows, seed=1)
        self.assertEqual(len([r for r in reps if r["burst_id"] == 7]), 1)
        self.assertEqual(len([r for r in reps if r["burst_id"] is None]), 3)
        again = sample.one_per_burst(list(reversed(rows)), seed=1)
        self.assertEqual([r["id"] for r in reps], [r["id"] for r in again])   # not order dependent

    def test_allocation_has_minimums_and_sums(self):
        q = sample.allocate({"a": 0.52, "b": 0.28, "c": 0.19, "d": 0.012, "e": 0.001}, 100, 8)
        self.assertEqual(sum(q.values()), 100)
        self.assertEqual((q["d"], q["e"]), (8, 8))
        self.assertGreater(q["a"], q["b"])
        self.assertGreater(q["b"], q["c"])

    def test_draw_on_a_synthetic_library(self):
        rows = []
        for i, r in enumerate(synthetic_library(), 1):
            rows.append(dict(r, id=i))
        entries = sample.build(rows, seed=1, per_split=60, accept=lambda split, r: True)
        again = sample.build(rows, seed=1, per_split=60, accept=lambda split, r: True)
        self.assertEqual([e["id"] for e in entries], [e["id"] for e in again])   # deterministic
        self.assertNotEqual([e["id"] for e in entries],
                            [e["id"] for e in sample.build(rows, seed=2, per_split=60, accept=lambda s, r: True)])

        days = {s: {e["day"] for e in entries if e["split"] == s} for s in ("dev", "test")}
        self.assertFalse(days["dev"] & days["test"])                       # a day is in one split only
        for e in entries:
            self.assertEqual(e["split"], sample.split_of(e["day"]))
        self.assertEqual(len({e["id"] for e in entries}), len(entries))
        bursts = Counter(next(r["burst_id"] for r in rows if r["id"] == e["id"]) for e in entries)
        self.assertEqual(max(bursts.values()), 1)                          # one photo per burst
        for s in ("dev", "test"):
            es = [e for e in entries if e["split"] == s]
            self.assertEqual(len(es), 60)
            eras = Counter(sample.era_of(e["camera"]) for e in es)
            for era in sample.ERAS:
                self.assertGreaterEqual(eras[era], 8, (s, era, eras))      # era minimum
            self.assertGreater(eras["Sony A7R III/IIIA"], eras["Nikon D40/D60"])   # roughly proportional
            people = sum(e["people_count"] > 0 for e in es)
            self.assertAlmostEqual(people / len(es), 0.45, delta=0.1)
            self.assertGreaterEqual(len({e["scene"] for e in es}), 4)      # spread over scenes
            per_day = Counter(e["day"] for e in es)
            for day, n in per_day.items():
                cap = 3 if not any(sample.era_of(e["camera"]) in ("Canon R6", "iPhone/other") for e in es if e["day"] == day) else 40
                self.assertLessEqual(n, cap)

    def test_day_cap_is_three_when_days_are_plentiful(self):
        rows = [dict(r, id=i) for i, r in enumerate(synthetic_library(), 1)]
        entries = sample.build(rows, seed=1, per_split=30, accept=lambda s, r: True)
        for s in ("dev", "test"):
            sony = Counter(e["day"] for e in entries if e["split"] == s and sample.era_of(e["camera"]) == "Sony A7R III/IIIA")
            self.assertLessEqual(max(sony.values()), 3)

    def test_rejected_images_are_replaced(self):
        rows = [dict(r, id=i) for i, r in enumerate(synthetic_library(), 1)]
        bad = {r["id"] for r in rows[::3]}
        entries = sample.build(rows, seed=1, per_split=30, accept=lambda s, r: r["id"] not in bad)
        self.assertFalse({e["id"] for e in entries} & bad)
        self.assertEqual(Counter(e["split"] for e in entries), {"dev": 30, "test": 30})

    def test_set_entry_shape(self):
        r = dict(row("/l/2024/2024-01-02/a.JPG", scene="street", people=2), id=9,
                 tags=json.dumps(["x", "y"]), animals=json.dumps(["dog"]))
        e = sample.set_entry(r, "dev")
        self.assertEqual({k: e[k] for k in ("id", "split", "path", "day", "scene", "people_count")},
                         {"id": 9, "split": "dev", "path": "/l/2024/2024-01-02/a.JPG", "day": "2024-01-02",
                          "scene": "street", "people_count": 2})
        self.assertEqual(e["prod"]["tags"], ["x", "y"])
        self.assertEqual(e["prod"]["animals"], ["dog"])
        self.assertEqual(set(e["prod"]), set(sample.PROD_FIELDS))


class TodoTools(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.d = Path(self._t.name)
        self.entries = [{"id": i, "split": "dev" if i < 5 else "test"} for i in range(1, 8)]

    def tearDown(self):
        self._t.cleanup()

    def put(self, *parts, obj=None):
        p = self.d.joinpath(*parts)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(obj or {}))

    def test_batches(self):
        self.assertEqual(todo.batches([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
        self.assertEqual(todo.batches([], 20), [])
        self.assertEqual(todo.batches([1, 2], 0), [[1], [2]])

    def test_labels_todo_skips_labelled(self):
        self.put("labels", "2.json")
        self.put("labels", "5.json")
        self.assertEqual(todo.pending_labels(self.entries, self.d), [1, 3, 4, 6, 7])

    def test_grades_need_label_and_run_output(self):
        for i in (1, 2, 3, 4):
            self.put("labels", f"{i}.json")
        for i in (2, 3, 4, 5):
            self.put("runs", "r", f"{i}.json")
        self.put("grades", "r", "3.json")
        ready, waiting = todo.pending_grades(self.entries, "r", self.d)
        self.assertEqual(ready, [2, 4])            # 1: no run output; 3: graded; 5: no label
        self.assertEqual(waiting, [1, 5, 6, 7])

    def test_packet_has_only_factual_fields(self):
        self.put("labels", "2.json", obj={"id": 2, "caption": "ref"})
        out = {"id": 2, "caption": "c", "subject": "s", "scene": "street", "people_count": 1, "tags": ["t"],
               "activity": "a", "indoor_outdoor": "outdoor", "time_of_day": "day", "animals": [],
               "content_type": "photo", "visible_text": "", "aesthetic": 9, "keep_hint": True, "issues": ["x"],
               "eyes_closed": True, "raw": "{...}", "seconds": 3.2}
        self.put("runs", "r", "2.json", obj=out)
        p = todo.packet(2, "r", self.d)
        self.assertEqual(p["label"], {"id": 2, "caption": "ref"})
        self.assertEqual(set(p["output"]), set(todo.FACTUAL))
        for k in ("aesthetic", "keep_hint", "issues", "eyes_closed", "raw", "seconds"):
            self.assertNotIn(k, p["output"])
        self.assertTrue(p["image"].endswith("images/2.jpg"))
        with self.assertRaises(SystemExit):
            todo.packet(3, "r", self.d)


def grade(i, errors=(), tags=(6, 0), people=True, activity="ok", io=True, tod=True, scene=True,
          animals=True, text="n/a", mm=(2, 2), **kw):
    g = {"id": i, "run": "r", "caption_errors": [{"type": t, "detail": "d"} for t in errors],
         "tags_total": tags[0], "tags_wrong": tags[1], "tags_wrong_list": [], "people_count_ok": people,
         "activity": activity, "indoor_outdoor_ok": io, "time_of_day_ok": tod, "scene_ok": scene,
         "animals_ok": animals, "visible_text": text, "must_mention_hit": mm[0],
         "must_mention_total": mm[1], "notes": ""}
    g.update(kw)
    return g


class Scorer(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.d = Path(self._t.name)
        self.entries = [{"id": i, "split": "dev" if i <= 10 else "test"} for i in range(1, 15)]
        for e in self.entries:
            self.write("labels", f"{e['id']}.json", obj={"id": e["id"], "confidence": "high"})
        self.write("labels", "10.json", obj={"id": 10, "confidence": "low"})   # a dev photo that is low-confidence

    def tearDown(self):
        self._t.cleanup()

    def write(self, *parts, obj):
        p = self.d.joinpath(*parts[:-1]) / parts[-1]
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(obj if isinstance(obj, str) else json.dumps(obj))

    def run_grades(self, name, grades):
        for g in grades:
            self.write("grades", name, f"{g['id']}.json", obj=g)

    def scored(self, name):
        return score.score_run(score.load_grades(name, self.entries, self.d))

    def test_primary_metric_counts_only_the_four_types(self):
        self.run_grades("a", [grade(1, ["hallucination"]), grade(2, ["wrong_setting"]), grade(3),
                              grade(4, ["over_assertion", "wrong_count"]), grade(5, ["missed_subject"])])
        m = self.scored("a")["dev"]["metrics"]
        self.assertEqual(m["primary"]["value"], 2 / 5)         # photos 1 and 4; one photo counts once
        self.assertEqual(m["err:wrong_setting"]["value"], 1 / 5)
        self.assertEqual(m["err:over_assertion"]["value"], 1 / 5)
        self.assertLessEqual(m["primary"]["lo"], 0.4)
        self.assertGreaterEqual(m["primary"]["hi"], 0.4)
        self.assertEqual(self.scored("a")["test"]["scored"], 0)

    def test_secondary_metrics(self):
        self.run_grades("a", [
            grade(1, tags=(6, 1), people=False, activity="wrong", io=False, text="invented", mm=(1, 3)),
            grade(2, tags=(4, 0), activity="n/a", text="ok", mm=(2, 2)),
            grade(3, tags=(5, 1), activity="ok", scene=False, text="missed", mm=(0, 0), animals=False)])
        m = self.scored("a")["dev"]["metrics"]
        self.assertAlmostEqual(m["tag_precision"]["value"], 1 - 2 / 15)
        self.assertAlmostEqual(m["people_count_exact"]["value"], 2 / 3)
        self.assertAlmostEqual(m["activity_ok"]["value"], 1 / 2)            # the n/a photo is not counted
        self.assertAlmostEqual(m["indoor_outdoor_acc"]["value"], 2 / 3)
        self.assertAlmostEqual(m["scene_acc"]["value"], 2 / 3)
        self.assertAlmostEqual(m["animals_acc"]["value"], 2 / 3)
        self.assertAlmostEqual(m["visible_text_invented"]["value"], 1 / 3)
        self.assertAlmostEqual(m["visible_text_missed"]["value"], 1 / 3)
        self.assertAlmostEqual(m["must_mention_recall"]["value"], 3 / 5)

    def test_low_confidence_is_excluded_and_counted_apart(self):
        self.run_grades("a", [grade(1), grade(2), grade(10, ["hallucination"])])
        r = self.scored("a")["dev"]
        self.assertEqual((r["graded"], r["scored"]), (3, 2))
        self.assertEqual(r["low_confidence"], {"n": 1, "primary_rate": 1.0})
        self.assertEqual(r["metrics"]["primary"]["value"], 0.0)

    def test_malformed_files_are_reported_not_fatal(self):
        self.write("grades", "a", "1.json", obj="{not json")
        self.write("grades", "a", "2.json", obj=grade(2, ["made_up_type"]))
        self.write("grades", "a", "3.json", obj=grade(3, tags=(3, 5)))
        self.write("grades", "a", "4.json", obj={"id": 4})
        self.write("grades", "a", "5.json", obj=grade(6))                      # wrong id inside
        self.write("grades", "a", "99.json", obj=grade(99))                    # not in the set
        self.write("grades", "a", "6.json", obj=grade(6, activity="maybe", visible_text="x", people_count_ok="yes"))
        self.write("labels", "7.json", obj="")                                 # unreadable label
        self.write("grades", "a", "7.json", obj=grade(7))
        self.write("grades", "a", "8.json", obj=grade(8))                      # the one good file
        data = score.load_grades("a", self.entries, self.d)
        bad = {Path(m["file"]).stem: m["problems"] for m in data["dev"]["malformed"]}
        self.assertEqual(sorted(bad), ["1", "2", "3", "4", "5", "6", "7"])
        self.assertTrue(any("made_up_type" in p for p in bad["2"]))
        self.assertTrue(any("exceeds" in p for p in bad["3"]))
        self.assertTrue(any("id is" in p for p in bad["5"]))
        self.assertTrue(any("activity" in p for p in bad["6"]))
        self.assertTrue(any("label" in p for p in bad["7"]))
        self.assertEqual([Path(m["file"]).stem for m in data["unmatched"]], ["99"])
        res = score.score_run(data)
        self.assertEqual(res["dev"]["scored"], 1)
        text = score.render({"a": res}, None)
        self.assertIn("MALFORMED [a]", text)
        self.assertIn("not in set.json", text)

    def test_ungraded_count(self):
        self.run_grades("a", [grade(1), grade(2)])
        r = self.scored("a")
        self.assertEqual((r["dev"]["set"], r["dev"]["ungraded"]), (10, 8))
        self.assertEqual(r["test"]["ungraded"], 4)

    def test_paired_fixed_and_broken(self):
        self.run_grades("a", [grade(1, ["hallucination"]), grade(2, ["wrong_count"]), grade(3, ["over_assertion"]),
                              grade(4), grade(5), grade(6, ["misidentification"]), grade(7)])
        self.run_grades("b", [grade(1), grade(2), grade(3, ["over_assertion"]), grade(4, ["hallucination"]),
                              grade(5), grade(6, ["wrong_setting"])])             # 7 only in a; 6: wrong_setting isn't primary
        ra, rb = score.load_grades("a", self.entries, self.d), score.load_grades("b", self.entries, self.d)
        c = score.compare(ra, rb)["dev"]
        self.assertEqual(c["n"], 6)
        self.assertEqual((c["fixed"], c["broken"], c["both_error"], c["both_clean"]), (3, 1, 1, 1))
        self.assertEqual(c["fixed_ids"], [1, 2, 6])
        self.assertEqual(c["broken_ids"], [4])
        self.assertAlmostEqual(c["primary_a"], 4 / 6)
        self.assertAlmostEqual(c["primary_b"], 2 / 6)
        self.assertAlmostEqual(c["diff_b_minus_a"], -2 / 6)
        self.assertLess(c["lo"], c["diff_b_minus_a"])
        self.assertGreater(c["hi"], c["diff_b_minus_a"])
        self.assertEqual(score.compare(ra, rb)["test"], {"n": 0})
        text = score.render({"a": score.score_run(ra), "b": score.score_run(rb)}, score.compare(ra, rb))
        self.assertIn("fixed 3, broken 1", text)

    def test_bootstrap_is_seeded(self):
        self.run_grades("a", [grade(i, ["hallucination"] if i % 3 == 0 else []) for i in range(1, 10)])
        self.assertEqual(self.scored("a"), self.scored("a"))
        idx = score.bootstrap_idx(9)
        self.assertEqual(idx.shape, (2000, 9))

    def test_a_clean_run_has_zero_width_interval_at_zero(self):
        self.run_grades("a", [grade(i) for i in range(1, 6)])
        m = self.scored("a")["dev"]["metrics"]["primary"]
        self.assertEqual((m["value"], m["lo"], m["hi"]), (0.0, 0.0, 0.0))


class ProductionUnchanged(unittest.TestCase):
    """The only change in photo_cull.py is optional prompt/model arguments to analyze_vlm."""

    def test_default_call_sends_the_production_prompt_and_model(self):
        import photo_cull as pc
        from PIL import Image

        calls = []

        class Client:
            def chat(self, **kw):
                calls.append(kw)
                return {"message": {"content": json.dumps({"caption": "x", "people_count": 1})}}

        im = Image.new("RGB", (64, 48))
        vlm, model = pc.analyze_vlm(Client(), im, False)
        self.assertEqual(model, pc.MODEL_PRIMARY)
        k = calls[0]
        self.assertEqual(k["messages"][0]["content"], pc.VLM_PROMPT)
        self.assertEqual((k["model"], k["think"], k["format"], k["options"], k["keep_alive"]),
                         (pc.MODEL_PRIMARY, False, pc.VLM_SCHEMA, {"num_ctx": pc.NUM_CTX, "temperature": 0},
                          pc.KEEP_ALIVE))
        self.assertEqual(vlm, pc.coerce_vlm({"caption": "x", "people_count": 1}))
        calls.clear()
        pc.analyze_vlm(Client(), im, True)
        self.assertEqual(calls[0]["model"], pc.MODEL_FALLBACK)
        self.assertEqual(calls[0]["messages"][0]["content"], pc.VLM_PROMPT)

    def test_prompt_and_model_overrides_and_ladder(self):
        import photo_cull as pc
        from PIL import Image

        seen = []

        class OomClient:
            def chat(self, **kw):
                seen.append((kw["model"], kw["messages"][0]["content"]))
                if len(seen) < 3:
                    raise RuntimeError("CUDA out of memory")
                return {"message": {"content": "{}"}}

        _, used = pc.analyze_vlm(OomClient(), Image.new("RGB", (64, 48)), False, prompt="P", model="other:1b")
        self.assertEqual(seen, [("other:1b", "P"), ("other:1b", "P"), (pc.MODEL_FALLBACK, "P")])
        self.assertEqual(used, pc.MODEL_FALLBACK)

    def test_prompt_version_is_the_hash_of_the_prompt(self):
        import photo_cull as pc
        self.assertEqual(pc.VLM_PROMPT_VERSION, hashlib.sha256(pc.VLM_PROMPT.encode("utf-8")).hexdigest()[:12])
        self.assertEqual(pc.VLM_PROMPT_VERSION, "f2417791aa47")   # the value before the eval tooling was added


if __name__ == "__main__":
    unittest.main()
