"""Eval audit routes and scoring, using only synthetic files in temporary directories."""
import contextlib
import io
import json
import os
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

from flask import Flask
from PIL import Image

from eval import score
from review import eval_audit


def grade(i, bad=False, **changes):
    value = {"id": i, "run": "fixture", "caption_errors": (
        [{"type": "hallucination", "detail": "Invented a bird"}] if bad else []),
        "tags_total": 2, "tags_wrong": int(bad), "tags_wrong_list": ["bird"] if bad else [],
        "people_count_ok": not bad, "activity": "wrong" if bad else "ok",
        "indoor_outdoor_ok": not bad, "time_of_day_ok": not bad, "scene_ok": not bad,
        "animals_ok": not bad, "visible_text": "invented" if bad else "ok",
        "must_mention_hit": 0 if bad else 2, "must_mention_total": 2, "notes": ""}
    value.update(changes)
    return value


class SyntheticEval(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def write(self, path, value):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")

    def read(self, path):
        return json.loads((self.root / path).read_text(encoding="utf-8"))


class EvalAuditApi(SyntheticEval):
    H = {"X-Culling-Bay": "1"}

    def setUp(self):
        super().setUp()
        self.entries = [{"id": i, "split": "test" if i == 6 else "dev", "path": "/private/library.jpg"}
                        for i in range(7, 0, -1)]
        self.write("set.json", self.entries)
        for e in self.entries:
            i = e["id"]
            label = {"id": i, "caption": "A tree", "subject": "tree", "scene": "landscape",
                     "people_count": 0, "activity": "", "tags": ["tree"], "indoor_outdoor": "outdoor",
                     "time_of_day": "day", "animals": [], "visible_text": "", "content_type": "photo",
                     "uncertain": ["species"], "confidence": "high"}
            self.write(f"labels/{i}.json", label)
            for run in ("baseline", "v2"):
                self.write(f"runs/{run}/{i}.json", dict(label, raw="private raw text", keep_hint=True,
                                                       aesthetic=9, seconds=4, issues=[], eyes_closed=False))
                if i == 6:
                    continue
                self.write(f"grades/{run}/{i}.json", grade(
                    i, bad=(i == 3 or (i == 4 and run == "baseline")),
                    people_count_ok=i != 2,
                    notes="REF: tree may be a shrub" if i == 7 or (i == 5 and run == "baseline") else ""))
        (self.root / "grades/empty").mkdir()
        self.write("runs/ungraded/1.json", {"caption": "No grades yet"})
        (self.root / "images").mkdir()
        Image.new("RGB", (8, 6), color="green").save(self.root / "images/1.jpg")
        app = Flask(__name__)
        app.config["TESTING"] = True
        app.register_blueprint(eval_audit.make_eval_blueprint(self.root))
        self.app = app
        self.client = app.test_client()
        self.body = {"reference": "wrong", "corrections": {"caption": "A shrub", "people_count": 0,
                     "activity": "", "note": "Look at the leaves"},
                     "grades": {"baseline": "disagree", "v2": "agree"}, "note": "Danny’s review"}

    def post(self, body=None, id=1):
        return self.client.post(f"/m/eval/api/audit/{id}", json=self.body if body is None else body, headers=self.H)

    def test_page_is_self_contained_and_phone_ready(self):
        response = self.client.get("/m/eval/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.mimetype, "text/html")
        html = response.get_data(as_text=True)
        for text in ("<style>", "<script>", 'name="viewport"', 'prefers-color-scheme:dark',
                     "Next un-audited", "Save, then next", "showModal()", "new Image()"):
            self.assertIn(text, html)
        self.assertNotIn('<script src=', html)
        self.assertNotIn('rel="stylesheet"', html)

    def test_priority_order_is_stable_and_reasons_overlap(self):
        response = self.client.get("/m/eval/api/items")
        items = response.get_json()
        self.assertEqual([i["id"] for i in items], [5, 7, 4, 3, 2, 1, 6])
        self.assertEqual(set(items[0]), {"id", "split", "reasons", "audited"})
        self.assertIn("REF:", items[0]["reasons"][0])
        self.assertEqual(len(items[2]["reasons"]), 2)  # disagreement AND caption errors
        self.assertIn("disagree", items[2]["reasons"][0])
        self.assertEqual(items[-1]["split"], "test")
        self.assertFalse(any(i["audited"] for i in items))
        self.assertEqual(response.headers["Cache-Control"], "no-store")

    def test_priority_only_drops_unflagged_photos(self):
        items = self.client.get("/m/eval/api/items?only=priority").get_json()
        self.assertEqual([i["id"] for i in items], [5, 7, 4, 3, 2])

    def test_run_filter_changes_priorities_and_item_runs(self):
        items = self.client.get("/m/eval/api/items?runs=v2").get_json()
        self.assertEqual([i["id"] for i in items], [7, 3, 2, 1, 4, 5, 6])
        self.assertFalse(any("disagree" in reason for i in items for reason in i["reasons"]))
        item = self.client.get("/m/eval/api/item/1?runs=v2,v2").get_json()
        self.assertEqual(list(item["runs"]), ["v2"])

    def test_bad_run_filters_cannot_read_arbitrary_paths(self):
        for query in ("../labels", "/tmp", "missing", "baseline,../labels", "", "empty", "ungraded"):
            for route in ("items", "item/1"):
                with self.subTest(query=query, route=route):
                    response = self.client.get("/m/eval/api/" + route, query_string={"runs": query})
                    self.assertEqual(response.status_code, 400)
                    self.assertIn("error", response.get_json())
        self.assertEqual(self.client.get("/m/eval/api/items?only=bogus").status_code, 400)

    def test_item_shape_factual_output_only(self):
        item = self.client.get("/m/eval/api/item/1").get_json()
        self.assertEqual(set(item), {"id", "split", "image", "label", "runs", "audit"})
        self.assertEqual(item["image"], "/m/eval/img/1")
        self.assertEqual(item["label"], self.read("labels/1.json"))
        self.assertEqual(set(item["runs"]), {"baseline", "v2"})
        for run, data in item["runs"].items():
            self.assertEqual(set(data), {"output", "grade"})
            self.assertEqual(set(data["output"]), set(eval_audit.FACTUAL))
            self.assertEqual(data["output"]["people_count"], 0)
            self.assertEqual(data["grade"], self.read(f"grades/{run}/1.json"))
        self.assertIsNone(item["audit"])

    def test_item_missing_label_output_or_grade_is_explicit(self):
        (self.root / "labels/1.json").unlink()
        (self.root / "runs/baseline/1.json").unlink()
        item = self.client.get("/m/eval/api/item/1").get_json()
        self.assertIsNone(item["label"])
        self.assertIsNone(item["runs"]["baseline"]["output"])
        self.assertIsNotNone(item["runs"]["baseline"]["grade"])
        item = self.client.get("/m/eval/api/item/6").get_json()
        self.assertIsNone(item["runs"]["baseline"]["grade"])

    def test_unknown_item_is_json_404(self):
        response = self.client.get("/m/eval/api/item/999")
        self.assertEqual(response.status_code, 404)
        self.assertIn("error", response.get_json())

    def test_empty_eval_is_usable(self):
        (self.root / "set.json").unlink()
        self.assertEqual(self.client.get("/m/eval/").status_code, 200)
        self.assertEqual(self.client.get("/m/eval/api/items").get_json(), [])
        self.assertEqual(self.client.get("/m/eval/api/item/1").status_code, 404)

    def test_image_serves_jpeg_and_missing_images_are_404(self):
        with self.client.get("/m/eval/img/1") as response:
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.mimetype, "image/jpeg")
            self.assertEqual(Image.open(io.BytesIO(response.data)).size, (8, 6))
            self.assertIn("max-age=3600", response.headers["Cache-Control"])
        for id in (2, 999):
            self.assertEqual(self.client.get(f"/m/eval/img/{id}").status_code, 404)

    def test_image_rejects_non_integer_paths(self):
        for value in ("-1", "1.jpg", "1.0", "nope", "../set.json", "%2e%2e%2fset.json", "1/../../set.json"):
            with self.subTest(value=value):
                self.assertEqual(self.client.get("/m/eval/img/" + value).status_code, 404)

    def test_post_requires_header_and_json(self):
        for headers in ({}, {"X-Culling-Bay": "0"}):
            self.assertEqual(self.client.post("/m/eval/api/audit/1", json=self.body,
                                              headers=headers).status_code, 403)
        self.assertEqual(self.client.post("/m/eval/api/audit/1", data=json.dumps(self.body),
                                          headers=self.H).status_code, 403)
        self.assertFalse((self.root / "audits").exists())

    def test_post_malformed_json_is_400(self):
        response = self.client.post("/m/eval/api/audit/1", data="{bad", content_type="application/json", headers=self.H)
        self.assertEqual(response.status_code, 400)
        self.assertIn("error", response.get_json())

    def test_post_validates_all_fields(self):
        bad = [[], "wrong", {}, {"reference": []}, {"reference": "maybe"},
               dict(self.body, extra="x"), dict(self.body, audited_at="yesterday"),
               dict(self.body, corrections=[]), dict(self.body, corrections={"tags": []}),
               *[dict(self.body, corrections={"people_count": x}) for x in (-1, True, 1.5, "2", None)],
               *[dict(self.body, corrections={key: 1}) for key in ("caption", "activity", "note")],
               dict(self.body, grades=[]), dict(self.body, grades={"baseline": True}),
               dict(self.body, grades={"baseline": "unsure"}), dict(self.body, grades={"missing": "agree"}),
               dict(self.body, grades={"../labels": "disagree"}), dict(self.body, note=[])]
        for body in bad:
            with self.subTest(body=body):
                response = self.post(body)
                self.assertEqual(response.status_code, 400)
                self.assertIn("error", response.get_json())
        self.assertFalse((self.root / "audits").exists())

    def test_post_rejects_null_body(self):
        response = self.client.post("/m/eval/api/audit/1", data="null", content_type="application/json", headers=self.H)
        self.assertEqual(response.status_code, 400)

    def test_post_unknown_id_or_grade(self):
        self.assertEqual(self.post(id=999).status_code, 404)
        self.assertEqual(self.post(id=6).status_code, 400)  # output exists but isn't graded
        self.assertFalse((self.root / "audits").exists())

    def test_save_round_trip_and_overwrite_without_changing_sources(self):
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        response = self.post()
        self.assertEqual(response.status_code, 200)
        saved = response.get_json()
        self.assertEqual({k: v for k, v in saved.items() if k != "audited_at"}, self.body)
        self.assertIsNotNone(datetime.fromisoformat(saved["audited_at"]).tzinfo)
        self.assertEqual(self.read("audits/1.json"), saved)
        self.assertEqual(self.client.get("/m/eval/api/item/1").get_json()["audit"], saved)
        self.assertTrue(next(i for i in self.client.get("/m/eval/api/items").get_json() if i["id"] == 1)["audited"])
        for value in ("right", "unsure"):
            self.assertEqual(self.post({"reference": value}).status_code, 200)
            self.assertEqual(self.read("audits/1.json")["reference"], value)
        self.assertEqual(self.read("audits/1.json")["corrections"], {})
        self.assertEqual({p: p.read_bytes() for p in before}, before)

    def test_atomic_replace_has_complete_json_and_preserves_old_file_until_replace(self):
        self.post({"reference": "right"})
        old = self.read("audits/1.json")
        replace = os.replace
        seen = []

        def inspect(src, dst):
            self.assertEqual(Path(src).parent, Path(dst).parent)
            self.assertNotEqual(src, dst)
            self.assertEqual(self.read("audits/1.json"), old)
            self.assertEqual(json.loads(Path(src).read_text())["reference"], "wrong")
            seen.append(src)
            replace(src, dst)

        with patch.object(eval_audit.os, "replace", side_effect=inspect):
            self.assertEqual(self.post().status_code, 200)
        self.assertEqual(len(seen), 1)
        self.assertEqual(list((self.root / "audits").iterdir()), [self.root / "audits/1.json"])

    def test_failed_atomic_replace_keeps_previous_audit_and_cleans_temp(self):
        self.post({"reference": "right"})
        old = self.read("audits/1.json")
        with patch.object(eval_audit.os, "replace", side_effect=OSError("synthetic failure")):
            response = self.post()
        self.assertEqual(response.status_code, 500)
        self.assertIn("Could not write", response.get_json()["error"])
        self.assertEqual(self.read("audits/1.json"), old)
        self.assertEqual(list((self.root / "audits").iterdir()), [self.root / "audits/1.json"])

    def test_concurrent_saves_use_separate_temp_files(self):
        def save(n):
            with self.app.test_client() as client:
                return client.post("/m/eval/api/audit/1", json=dict(self.body, note=str(n)), headers=self.H).status_code
        with ThreadPoolExecutor(max_workers=4) as pool:
            self.assertEqual(list(pool.map(save, range(12))), [200] * 12)
        self.assertIn(self.read("audits/1.json")["note"], [str(n) for n in range(12)])
        self.assertEqual(list((self.root / "audits").iterdir()), [self.root / "audits/1.json"])


class AuditScoring(SyntheticEval):
    def setUp(self):
        super().setUp()
        self.entries = [{"id": i, "split": "test" if i == 6 else "dev"} for i in range(1, 7)]
        self.write("set.json", self.entries)
        for e in self.entries:
            i = e["id"]
            self.write(f"labels/{i}.json", {"id": i, "confidence": "low" if i == 5 else "high"})
            for run, bad_ids in (("baseline", (1, 2, 5, 6)), ("v2", (1, 3, 5))):
                self.write(f"grades/{run}/{i}.json", grade(i, bad=i in bad_ids))

    def audits(self):
        for i, ref, grades in [(1, "wrong", {"baseline": "agree", "v2": "agree"}),
                               (2, "right", {"baseline": "disagree"}),
                               (3, "unsure", {"v2": "disagree"}),
                               (4, "right", {"baseline": "agree", "v2": "agree"}),
                               (5, "wrong", {}), (6, "unsure", {"baseline": "disagree"})]:
            self.write(f"audits/{i}.json", {"reference": ref, "grades": grades})

    def data(self, run, drop=False):
        return score.load_grades(run, self.entries, self.root, drop_disputed=drop)

    def cli(self, *args):
        output = io.StringIO()
        with patch.object(score, "EVAL", self.root), contextlib.redirect_stdout(output):
            score.main(list(args))
        return output.getvalue(), self.read("report.json")

    def test_no_audits_keeps_default_output_and_report_shape(self):
        expected = {r: score.score_run(self.data(r)) for r in ("baseline", "v2")}
        comparison = score.compare(self.data("baseline"), self.data("v2"))
        text, report = self.cli("baseline", "v2")
        self.assertEqual(text, score.render(expected, comparison) + f"\nwrote {self.root / 'report.json'}\n")
        self.assertEqual(report["runs"], expected)
        self.assertNotIn("audit", text)
        self.assertNotIn("excluded_disputed", report["runs"]["baseline"]["dev"])

    def test_audit_summary_per_run_without_changing_default_metrics(self):
        original = {r: score.score_run(self.data(r)) for r in ("baseline", "v2")}
        self.audits()
        text, report = self.cli("baseline", "v2")
        self.assertIn("audit [baseline]: audited 6, reference ruled wrong 2, grades disputed 2", text)
        self.assertIn("audit [v2]: audited 6, reference ruled wrong 2, grades disputed 1", text)
        for run in original:
            result = dict(report["runs"][run])
            result.pop("audit")
            self.assertEqual(result, original[run])

    def test_drop_disputed_excludes_from_every_metric_and_low_confidence_rate(self):
        self.audits()
        a, b = self.data("baseline", True), self.data("v2", True)
        self.assertEqual(set(a["dev"]["rows"]), {3, 4})
        self.assertEqual(set(b["dev"]["rows"]), {2, 4})
        self.assertEqual(a["test"]["rows"], {})
        self.assertEqual(set(b["test"]["rows"]), {6})
        for run, data in (("baseline", a), ("v2", b)):
            result = score.score_run(data)
            dev = result["dev"]
            self.assertEqual((dev["graded"], dev["scored"], dev["excluded_disputed"]), (5, 2, 3))
            self.assertEqual(dev["low_confidence"], {"n": 0, "primary_rate": None})
            self.assertEqual(dev["ungraded"], 0)
            for key, _ in score.METRICS:
                expected = 0 if key == "primary" or key.startswith(("err:", "visible_text_")) else 1
                with self.subTest(run=run, metric=key):
                    self.assertEqual(dev["metrics"][key], {"value": expected, "lo": expected, "hi": expected, "n": 2})

    def test_cli_drop_disputed_and_paired_union_of_disputes(self):
        self.audits()
        text, report = self.cli("baseline", "v2", "--drop-disputed")
        self.assertIn("excluded by audit, n", text)
        self.assertIn("audited 6", text)
        self.assertEqual(report["runs"]["baseline"]["dev"]["scored"], 2)
        self.assertEqual(report["paired"]["dev"]["n"], 1)  # only photo 4 survives both runs
        self.assertEqual(report["paired"]["dev"]["both_clean"], 1)
        self.assertEqual(report["paired"]["test"], {"n": 0})

    def test_unsure_alone_does_not_exclude_and_all_disputed_is_defined(self):
        for e in self.entries:
            self.write(f"audits/{e['id']}.json", {"reference": "unsure"})
        self.assertEqual(score.score_run(self.data("baseline", True))["dev"]["scored"], 4)
        for e in self.entries:
            self.write(f"audits/{e['id']}.json", {"reference": "wrong"})
        text, report = self.cli("--drop-disputed", "baseline", "v2")
        self.assertIn("no photos scored in both", text)
        self.assertEqual(report["runs"]["baseline"]["dev"]["metrics"], {})
        self.assertEqual(report["runs"]["baseline"]["dev"]["graded"], 5)

    def test_summary_counts_only_valid_grades_for_that_run(self):
        self.audits()
        (self.root / "grades/v2/1.json").unlink()
        self.write("grades/v2/2.json", {"id": 2})
        result = score.score_run(self.data("v2", True))
        self.assertEqual(result["audit"], {"audited": 4, "reference_wrong": 1, "grades_disputed": 1})
        self.assertEqual(result["dev"]["ungraded"], 1)
        self.assertEqual(len(result["dev"]["malformed"]), 1)

    def test_unreadable_or_invalid_audits_are_reported_and_ignored(self):
        for i, value in ((1, []), (2, {"reference": "maybe"}), (3, {"reference": "right", "grades": []}),
                         (4, {"reference": "right", "grades": {"baseline": "maybe"}})):
            self.write(f"audits/{i}.json", value)
        (self.root / "audits/5.json").write_text("{bad")
        with contextlib.redirect_stderr(io.StringIO()) as err:
            data = self.data("baseline", True)
        self.assertEqual(err.getvalue().count("MALFORMED AUDIT"), 5)
        self.assertEqual(set(data["dev"]["rows"]), {1, 2, 3, 4})
        self.assertNotIn("audit", data)


if __name__ == "__main__":
    unittest.main()
