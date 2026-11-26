"""photo_cull's `faces` step: the alignment maths and NMS, `cmd_faces` with a stubbed detector and
recognizer (resumable, --force, errors), and one run of the real models on a synthetic picture.
A temp DB and small synthetic pictures: the library on the NAS is never read. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import contextlib
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import photo_cull as pc  # noqa: E402

F = pc.Faces


def transform(points, scale, degrees, shift):
    """`points` moved by a similarity: scaled, rotated about the origin, then shifted."""
    a = np.radians(degrees)
    R = np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]])
    return scale * np.asarray(points, np.float64) @ R.T + np.asarray(shift, np.float64)


class Alignment(unittest.TestCase):
    def test_the_template_maps_onto_itself(self):
        M = F.similarity(pc.ARC_DST.astype(np.float64), pc.ARC_DST.astype(np.float64))
        np.testing.assert_allclose(M, [[1, 0, 0], [0, 1, 0]], atol=1e-6)

    def test_a_known_transform_is_recovered(self):
        dst = pc.ARC_DST.astype(np.float64)
        src = transform(dst, 2.5, 30, (140, -20))          # where a face's landmarks sit in a photo
        M = F.similarity(src, dst)                          # ... and the map that brings them to the template
        np.testing.assert_allclose(src @ M[:, :2].T + M[:, 2], dst, atol=1e-6)
        self.assertAlmostEqual(float(np.linalg.det(M[:, :2])), 1 / 2.5 ** 2, places=6)   # scale 0.4, no reflection

    def test_noisy_landmarks_still_give_a_proper_rotation(self):
        rng = np.random.default_rng(1)
        src = transform(pc.ARC_DST, 1.7, -15, (30, 40)) + rng.normal(0, 0.8, (5, 2))
        M = F.similarity(src, pc.ARC_DST.astype(np.float64))
        self.assertGreater(np.linalg.det(M[:, :2]), 0)

    def test_aligning_with_the_template_as_landmarks_changes_nothing(self):
        rng = np.random.default_rng(2)
        im = Image.fromarray(rng.integers(0, 256, (112, 112, 3), dtype=np.uint8))
        out = F.align(im, pc.ARC_DST)
        self.assertEqual(out.size, (112, 112))
        self.assertLessEqual(int(np.abs(np.asarray(out, int) - np.asarray(im, int)).max()), 1)

    def test_a_rotated_and_scaled_face_lands_on_the_template(self):
        # white dots at the landmarks of a face 2x the template's size, tilted 20 degrees, in a black picture
        src = transform(pc.ARC_DST, 2.0, 20, (90, 60))
        arr = np.zeros((300, 300, 3), np.uint8)
        yy, xx = np.mgrid[:300, :300]
        for x, y in src:
            arr[(xx - x) ** 2 + (yy - y) ** 2 <= 36] = 255
        out = np.asarray(F.align(Image.fromarray(arr), src), np.float64)[..., 0]
        for x, y in pc.ARC_DST:
            x0, y0 = int(x) - 8, int(y) - 8
            win = out[y0:y0 + 17, x0:x0 + 17]
            gy, gx = np.mgrid[y0:y0 + 17, x0:x0 + 17]
            cx, cy = (win * gx).sum() / win.sum(), (win * gy).sum() / win.sum()   # centre of the dot's light
            self.assertLess(abs(cx - x), 1.0)
            self.assertLess(abs(cy - y), 1.0)

    def test_eye_distance_and_sharpness(self):
        kps = np.array([[10, 20], [13, 24], [0, 0], [0, 0], [0, 0]], np.float64)
        self.assertAlmostEqual(F.eye_px(kps), 5.0)
        flat = Image.new("RGB", (112, 112), (90, 90, 90))
        rng = np.random.default_rng(3)
        noisy = Image.fromarray(rng.integers(0, 256, (112, 112, 3), dtype=np.uint8))
        self.assertEqual(F.sharpness(flat), 0.0)
        self.assertGreater(F.sharpness(noisy), 1000)


class Nms(unittest.TestCase):
    def test_a_lower_score_box_on_top_of_a_better_one_is_dropped(self):
        boxes = np.array([[0, 0, 10, 10], [1, 1, 11, 11], [50, 50, 60, 60]], float)
        keep = F._nms(boxes, np.array([0.6, 0.9, 0.7]))
        self.assertEqual(sorted(keep.tolist()), [1, 2])      # the 0.9 box wins over the 0.6 one; the far one stays
        self.assertEqual(keep[0], 1)                          # best first

    def test_disjoint_boxes_all_stay(self):
        boxes = np.array([[0, 0, 10, 10], [20, 0, 30, 10], [0, 20, 10, 30]], float)
        self.assertEqual(sorted(F._nms(boxes, np.array([0.5, 0.6, 0.7])).tolist()), [0, 1, 2])

    def test_boxes_overlapping_less_than_the_threshold_both_stay(self):
        boxes = np.array([[0, 0, 10, 10], [8, 0, 18, 10]], float)         # IoU 2/18
        self.assertEqual(len(F._nms(boxes, np.array([0.9, 0.8]))), 2)
        boxes = np.array([[0, 0, 10, 10], [3, 0, 13, 10]], float)         # IoU 7/13
        self.assertEqual(F._nms(boxes, np.array([0.9, 0.8])).tolist(), [0])


# Where the stubbed detector finds faces, by picture size: boxes in pixels. (200, 100) has two, the
# second hanging over the picture's right edge; (160, 120) has none.
FACE_BOXES = {(200, 100): [(20, 10, 80, 70), (140, 10, 210, 80)], (160, 120): [], (120, 160): [(30, 40, 90, 110)]}
SIZES = {"a.jpg": (200, 100), "b.jpg": (160, 120), "c.jpg": (120, 160)}


class FacesCommand(unittest.TestCase):
    """cmd_faces on a temp DB of three photos, with the models stubbed: a.jpg has two faces, b.jpg
    none and c.jpg one."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.db = self.root / "t.db"
        self.lib = self.root / "lib"
        self.day1, self.day2 = self.lib / "2026-01-01", self.lib / "2026-01-02"
        self.loaded = []                 # file names load_source was asked to open
        self.load_errors = {}            # file name -> exception to raise
        self.hot = 0                     # which dimension the stubbed recognizer lights up
        self.during = None               # called with the photo's name while it is being detected
        model_dir = self.root / "models"
        for part in ("detection", "recognition"):
            (model_dir / part).mkdir(parents=True)
            (model_dir / part / "model.onnx").write_bytes(b"")
        conn = pc.connect(self.db)
        for day in (self.day1, self.day2):
            for name in SIZES:
                p = day / name
                conn.execute("INSERT INTO images(path, filename, status) VALUES(?,?, 'ok')", (str(p), name))
        conn.execute("INSERT INTO images(path, filename, status) VALUES(?,?, 'error')",
                     (str(self.day1 / "broken.jpg"), "broken.jpg"))
        conn.commit()
        conn.close()
        test = self

        def fake_load(path):
            test.loaded.append(str(path))
            if path.name in test.load_errors:
                raise test.load_errors[path.name]
            im = Image.new("RGB", SIZES[path.name], (120, 120, 120))
            im.info["name"] = path.name      # readers run ahead of the detector: the picture carries its own name
            return im

        def fake_detect(self, im, scales=None):
            px = FACE_BOXES[im.size]
            if test.during:
                test.during(im.info["name"])
            boxes = np.array(px, np.float64).reshape(-1, 4)
            kps = np.array([pc.ARC_DST / 112 * (b[2] - b[0]) + [b[0], b[1]] for b in px], np.float64).reshape(-1, 5, 2)
            return boxes, kps, np.array([0.9 - 0.1 * i for i in range(len(px))]), [len(px), len(px)]

        def fake_embed(self, faces):
            v = np.zeros((len(faces), 512), np.float32)
            for i in range(len(faces)):
                v[i, (test.hot + i) % 512] = 1.0
            return v

        for p in (mock.patch.object(pc, "load_source", fake_load), mock.patch.object(pc, "FACE_DIR", model_dir),
                  mock.patch.object(pc.Faces, "detect", fake_detect), mock.patch.object(pc.Faces, "embed", fake_embed)):
            p.start()
            self.addCleanup(p.stop)

    def faces(self, order="id"):
        conn = pc.connect(self.db)
        try:
            return [dict(r) for r in conn.execute(f"SELECT * FROM faces ORDER BY {order}")]
        finally:
            conn.close()

    def checked(self):
        conn = pc.connect(self.db)
        try:
            return {(Path(r["path"]).parent.name, Path(r["path"]).name, r["face_version"]): r["faces"]
                    for r in conn.execute("SELECT * FROM faces_checked")}
        finally:
            conn.close()

    def cli(self, *argv):
        """Run photo_cull's CLI in-process. Returns (exit code, stdout)."""
        out = io.StringIO()
        code = 0
        with contextlib.redirect_stdout(out):
            try:
                args = pc.build_parser().parse_args(["faces", "--db", str(self.db), *[str(a) for a in argv]])
                args.func(args)
            except SystemExit as e:
                code = e.code if isinstance(e.code, int) else 1
                if isinstance(e.code, str):
                    out.write(e.code)
        return code, out.getvalue()

    def test_a_run_writes_the_faces_with_fractional_boxes(self):
        code, out = self.cli("--folder", self.day1)
        self.assertEqual(code, 0, out)
        rows = self.faces()
        self.assertEqual([Path(r["path"]).name for r in rows], ["c.jpg", "a.jpg", "a.jpg"])   # newest first
        for r in rows:
            self.assertTrue(all(0.0 <= r[k] <= 1.0 for k in ("x0", "y0", "x1", "y1")), r)
            self.assertLess(r["x0"], r["x1"])
            self.assertLess(r["y0"], r["y1"])
            self.assertEqual(r["face_version"], pc.FACE_VERSION)
            self.assertTrue(r["created_at"])
            kps = json.loads(r["kps"])
            self.assertEqual(len(kps), 5)
            self.assertTrue(all(len(pt) == 2 and 0 <= pt[0] <= 1 and 0 <= pt[1] <= 1 for pt in kps))
        c, a1, a2 = rows
        self.assertEqual((c["x0"], c["y0"], c["x1"], c["y1"]), (30 / 120, 40 / 160, 90 / 120, 110 / 160))
        self.assertEqual((a1["x0"], a1["x1"]), (20 / 200, 80 / 200))
        self.assertEqual((a2["x0"], a2["x1"]), (140 / 200, 1.0))        # the box hung over the edge: clipped
        self.assertAlmostEqual(a2["box_px"], 70.0)                       # ... its width is not
        self.assertAlmostEqual(a1["score"], 0.9)
        self.assertAlmostEqual(a1["eye_px"], float(np.linalg.norm(pc.ARC_DST[1] - pc.ARC_DST[0])) * 60 / 112, places=4)
        self.assertGreaterEqual(a1["sharp"], 0)
        for r in rows:
            v = pc.unpack_vector(r["vector"])
            self.assertEqual(v.shape, (512,))
            self.assertAlmostEqual(float(np.linalg.norm(v)), 1.0, places=5)
        self.assertEqual(sorted({Path(p).parent.name for p in self.loaded}), ["2026-01-01"])   # --folder limits the run

    def test_a_photo_without_faces_is_checked_too(self):
        self.cli("--folder", self.day1)
        self.assertEqual(self.checked(), {("2026-01-01", "a.jpg", pc.FACE_VERSION): 2,
                                          ("2026-01-01", "b.jpg", pc.FACE_VERSION): 0,
                                          ("2026-01-01", "c.jpg", pc.FACE_VERSION): 1})   # not broken.jpg: it is not ok

    def test_a_second_run_does_nothing(self):
        self.cli()
        before = self.faces()
        self.loaded.clear()
        code, out = self.cli()
        self.assertEqual(code, 0)
        self.assertIn("Nothing to check", out)
        self.assertEqual(self.loaded, [])                 # not even opened
        self.assertEqual(self.faces(), before)            # same rows, same ids

    def test_a_killed_run_resumes_with_the_photos_left(self):
        self.cli("--limit", "2")
        self.assertEqual(len(self.checked()), 2)
        self.loaded.clear()
        self.cli()
        self.assertEqual(len(self.checked()), 6)
        self.assertEqual(len(self.loaded), 4)             # only the four not yet checked
        self.assertEqual(len(self.faces()), 6)            # 2 days x (2 + 0 + 1)

    def test_limit_takes_the_newest_photos(self):
        self.cli("--limit", "1")
        self.assertEqual(list(self.checked()), [("2026-01-02", "c.jpg", pc.FACE_VERSION)])

    def test_force_replaces_a_photos_rows(self):
        self.cli("--folder", self.day1)
        with contextlib.closing(sqlite3.connect(self.db)) as con:    # a row from another face model, which --force must not touch
            con.execute("INSERT INTO faces(path, face_version, x0, y0, x1, y1) VALUES(?, 'old-model', 0, 0, 1, 1)",
                        (str(self.day1 / "a.jpg"),))
            con.commit()
        old = [r for r in self.faces() if r["face_version"] == pc.FACE_VERSION]
        self.hot = 100
        code, out = self.cli("--folder", self.day1, "--force")
        self.assertEqual(code, 0, out)
        rows = [r for r in self.faces() if r["face_version"] == pc.FACE_VERSION]
        self.assertEqual(len(rows), len(old))                                   # replaced, not doubled
        self.assertEqual(sorted(int(np.argmax(pc.unpack_vector(r["vector"]))) for r in rows), [100, 100, 101])
        self.assertEqual([r["face_version"] for r in self.faces()].count("old-model"), 1)
        self.assertEqual(len(self.checked()), 3)                                # still one checked row a photo
        self.assertEqual(len(self.loaded), 6)                                   # all three opened again

    def test_without_force_a_checked_photo_is_left_alone_even_if_asked_for_again(self):
        self.cli("--folder", self.day1)
        before = self.faces()
        self.hot = 100
        self.cli("--folder", self.day1)
        self.assertEqual(self.faces(), before)

    def test_a_photo_another_run_checked_meanwhile_keeps_that_runs_ids(self):
        first = []

        def other_run(name):          # the watcher's run gets to a.jpg first
            if name == "a.jpg" and not first:
                first.append(name)
                con = pc.connect(self.db)
                p = str(self.day1 / "a.jpg")
                con.execute("INSERT INTO faces(path, face_version, x0, y0, x1, y1) VALUES(?,?,0,0,1,1)", (p, pc.FACE_VERSION))
                con.execute("INSERT INTO faces_checked VALUES(?,?,1,'now')", (p, pc.FACE_VERSION))
                con.commit()
                con.close()
        self.during = other_run
        code, out = self.cli("--folder", self.day1)
        self.assertEqual(code, 0, out)
        mine = [r for r in self.faces() if Path(r["path"]).name == "a.jpg"]
        self.assertEqual(len(mine), 1)                                    # not 1 + 2
        self.assertEqual((mine[0]["x0"], mine[0]["x1"]), (0.0, 1.0))
        self.assertEqual(self.checked()[("2026-01-01", "a.jpg", pc.FACE_VERSION)], 1)

    def test_a_photo_that_cannot_be_read_is_not_checked_and_the_run_fails(self):
        self.load_errors["b.jpg"] = pc.LoadError("Input/output error")
        code, out = self.cli("--folder", self.day1)
        self.assertEqual(code, 1)
        self.assertIn("b.jpg", out)
        self.assertIn("ERROR Input/output error", out)
        self.assertEqual(sorted(k[1] for k in self.checked()), ["a.jpg", "c.jpg"])      # the rest went through
        self.assertEqual(len(self.faces()), 3)
        # the next run retries just that one
        self.load_errors.clear()
        self.loaded.clear()
        code, out = self.cli("--folder", self.day1)
        self.assertEqual(code, 0, out)
        self.assertEqual([Path(p).name for p in self.loaded], ["b.jpg"])
        self.assertEqual(self.checked()[("2026-01-01", "b.jpg", pc.FACE_VERSION)], 0)

    def test_a_detector_error_is_counted_like_a_read_error(self):
        def boom(name):
            if name == "c.jpg":
                raise RuntimeError("onnx exploded")
        self.during = boom
        code, out = self.cli("--folder", self.day1)
        self.assertEqual(code, 1)
        self.assertIn("onnx exploded", out)
        self.assertEqual(sorted(k[1] for k in self.checked()), ["a.jpg", "b.jpg"])

    def test_progress_line_reports_ms_per_photo_faces_and_eta(self):
        code, out = self.cli("--folder", self.day1)
        self.assertRegex(out, r"\[3/3\] checked  \(\d+ms/photo, 3 faces so far, ETA \d+m\d\ds\)")
        self.assertIn("Done: 3 ok / 0 error, 3 faces", out)

    def test_missing_models_exit_with_the_download_address(self):
        with tempfile.TemporaryDirectory() as empty, mock.patch.object(pc, "FACE_DIR", Path(empty)):
            code, out = self.cli()
        self.assertEqual(code, 1)
        self.assertIn("https://huggingface.co/immich-app/buffalo_l", out)
        self.assertEqual(self.loaded, [])

    def test_a_missing_database_exits(self):
        self.db.unlink()
        code, out = self.cli()
        self.assertEqual(code, 1)
        self.assertIn("No database", out)

    def test_faces_find_returns_the_columns_of_a_row(self):
        found = pc.Faces().find(Image.new("RGB", (200, 100)))
        self.assertEqual(len(found), 2)
        self.assertEqual(set(found[0]), {"box", "kps", "score", "sharp", "eye_px", "box_px", "vector"})


MODELS = pc.FACE_DIR / "detection" / "model.onnx"


@unittest.skipUnless(MODELS.exists() and (pc.FACE_DIR / "recognition" / "model.onnx").exists(),
                     f"needs the face models in {pc.FACE_DIR}")
class RealModels(unittest.TestCase):
    """The real SCRFD and ArcFace sessions on a synthetic picture: shapes, not faces found."""

    def test_detect_and_embed_end_to_end(self):
        fc = pc.Faces(threads=2)
        im = Image.new("RGB", (640, 480), (128, 128, 128))
        boxes, kps, scores, per_scale = fc.detect(im)
        n = len(scores)
        self.assertEqual(boxes.shape, (n, 4))
        self.assertEqual(kps.shape, (n, 5, 2))
        self.assertEqual(len(per_scale), 2)
        found = fc.find(im)
        self.assertEqual(len(found), n)
        for f in found:
            self.assertEqual(f["vector"].shape, (512,))
            self.assertAlmostEqual(float(np.linalg.norm(f["vector"])), 1.0, places=4)
            self.assertTrue(all(0.0 <= v <= 1.0 for v in f["box"]))
        # the recognition session runs on a 112 px picture whether or not the detector found a face
        v = fc.embed([Image.new("RGB", (112, 112), (128, 128, 128)), Image.new("RGB", (112, 112), (30, 60, 90))])
        self.assertEqual(v.shape, (2, 512))
        np.testing.assert_allclose(np.linalg.norm(v, axis=1), 1.0, atol=1e-4)
        self.assertEqual(fc.embed([]).shape, (0, 512))


if __name__ == "__main__":
    unittest.main()
