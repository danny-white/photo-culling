"""Tests for review/stacks.py. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
import stacks  # noqa: E402

_ids = iter(range(1, 10_000))


def row(filename, ts, sharp=200.0, flag="ok", lum=100.0, camera="SONY ILCE-7RM3", phash="0" * 16, blown=0.0):
    return {"rowid": next(_ids), "filename": filename, "path": "/mnt/passport/Pictures/2026/2026-10-01/" + filename,
            "capture_ts": ts, "camera": camera, "sharpness": sharp, "exposure_flag": flag,
            "mean_lum": lum, "phash": phash, "blown_pct": blown}


class Constants(unittest.TestCase):
    def test_match_photo_cull(self):
        import photo_cull as pc
        self.assertEqual(stacks.BURST_GAP_S, pc.BURST_GAP_S)
        self.assertEqual(stacks.RAW_EXTENSIONS, pc.RAW_EXTENSIONS)
        self.assertEqual(stacks.BLOWN_PCT, pc.BLOWN_PCT_SEVERE)
        self.assertEqual(stacks.DARK_LUM, pc.MEAN_LUM_LOW)


class Pairing(unittest.TestCase):
    def test_raw_and_jpeg_are_one_frame(self):
        frames = stacks.pair_frames([row("DSC0001.JPG", 10), row("DSC0001.ARW", 10)])
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0]["filename"], "DSC0001.ARW")
        self.assertEqual([p["filename"] for p in frames[0]["partners"]], ["DSC0001.JPG"])

    def test_lone_jpeg_stands_alone(self):
        frames = stacks.pair_frames([row("IMG_1.JPG", 10), row("DSC0002.ARW", 11)])
        self.assertEqual([f["filename"] for f in frames], ["IMG_1.JPG", "DSC0002.ARW"])

    def test_a_pair_is_never_a_burst(self):
        s = stacks.build_stacks([row("DSC0001.ARW", 10), row("DSC0001.JPG", 10)])
        self.assertEqual(len(s), 1)
        self.assertEqual(s[0]["kind"], "single")
        self.assertEqual(s[0]["frames"][0]["partners"], ["DSC0001.JPG"])


class Bursts(unittest.TestCase):
    def test_gap_and_camera(self):
        frames = stacks.pair_frames([
            row("A.ARW", 0), row("B.ARW", 1.5), row("C.ARW", 3.4),   # 1.9 s apart: still one burst
            row("D.ARW", 6.0),                                        # 2.6 s: new burst
            row("E.ARW", 6.5, camera="OTHER"),                         # other camera: new
            row("F.ARW", None), row("G.ARW", None)])                   # no time: singles
        sizes = [len(g) for g in stacks.group_bursts(frames)]
        self.assertEqual(sizes, [3, 1, 1, 1, 1])

    def test_lead_is_sharpest_earliest_on_tie(self):
        g = [row("A.ARW", 0, sharp=300), row("B.ARW", 1, sharp=450), row("C.ARW", 2, sharp=450)]
        self.assertEqual(stacks.lead_of(g, False)["filename"], "B.ARW")


class Brackets(unittest.TestCase):
    # shaped like 2026-10-01 DSC05040-42: normal, dark, bright in the same second
    def bracket(self):
        return [row("N.ARW", 0, sharp=242, flag="ok", lum=102),
                row("D.ARW", 0, sharp=16, flag="under", lum=32),
                row("B.ARW", 0, sharp=411, flag="over", lum=183)]

    def test_detected(self):
        self.assertTrue(stacks.is_bracket(self.bracket()))

    def test_ordinary_burst_is_not(self):
        g = [row("A.ARW", 0, lum=94), row("B.ARW", 1, lum=95), row("C.ARW", 1, lum=93)]
        self.assertFalse(stacks.is_bracket(g))

    def test_lead_is_the_normal_exposure_not_the_sharpest(self):
        self.assertEqual(stacks.lead_of(self.bracket(), True)["filename"], "N.ARW")

    def test_no_badges_inside_a_bracket(self):
        s = stacks.build_stacks(self.bracket())[0]
        self.assertEqual(s["kind"], "bracket")
        self.assertEqual([f["badges"] for f in s["frames"]], [[], [], []])


class Badges(unittest.TestCase):
    def test_measured_badges(self):
        g = [row("A.ARW", 0, sharp=400), row("B.ARW", 1, sharp=120), row("C.ARW", 1, sharp=20),
             row("D.ARW", 1, flag="under", sharp=5, lum=20), row("E.ARW", 1, flag="over", blown=40),
             row("F.ARW", 1, sharp=180), row("G.ARW", 1, flag="over", lum=200, blown=3)]
        got = [stacks.badges_of(f, g, False) for f in g]
        # B: 120 < 35% of 400; F: 180 is not; G: a bright frame, but not severely blown
        self.assertEqual(got, [[], ["Softer"], ["Softer"], ["Dark"], ["Blown"], [], []])

    def test_a_single_frame_is_never_soft(self):
        f = row("A.ARW", 0, sharp=3)   # smooth sky or bokeh scores this low too
        self.assertEqual(stacks.badges_of(f, [f], False), [])


class Budget(unittest.TestCase):
    def test_pauses_are_capped(self):
        rows = [row("A.ARW", 0), row("B.ARW", 1800), row("C.ARW", 3600 * 5)]   # two long pauses
        self.assertAlmostEqual(stacks.shooting_hours(rows), 20 / 60)          # 10 + 10 minutes
        self.assertEqual(stacks.keep_budget(rows), 5)                         # 15 x 1/3 h, floored to 5

    def test_fifteen_an_hour(self):
        rows = [row(f"{i}.ARW", i * 60) for i in range(121)]                  # a frame a minute for 2 h
        self.assertEqual(stacks.keep_budget(rows), 30)

    def test_no_times(self):
        self.assertEqual(stacks.keep_budget([row("A.ARW", None)]), 5)


class Panorama(unittest.TestCase):
    @staticmethod
    def sweep(step, n=5, w=256, h=170):
        rng = np.random.default_rng(7)
        world = rng.random((h, w + step * n + 10))
        k = np.ones(5) / 5
        world = np.apply_along_axis(lambda r: np.convolve(r, k, "same"), 1, world)
        return [world[:, i * step:i * step + w] for i in range(n)]

    def test_phash_candidate(self):
        far = ["0000000000000000", "00000000ffffffff", "ffffffff00000000"]
        near = ["0000000000000000", "0000000000000003", "0000000000000007"]
        self.assertTrue(stacks.pano_candidate([row(f"{i}.ARW", i, phash=p) for i, p in enumerate(far)]))
        self.assertFalse(stacks.pano_candidate([row(f"{i}.ARW", i, phash=p) for i, p in enumerate(near)]))

    def test_steady_sweep_confirms(self):
        self.assertTrue(stacks.pano_confirmed(self.sweep(40)))

    def test_still_frames_do_not(self):
        frames = self.sweep(40)
        self.assertFalse(stacks.pano_confirmed([frames[0]] * 4))

    def test_back_and_forth_does_not(self):
        f = self.sweep(40)
        self.assertFalse(stacks.pano_confirmed([f[0], f[1], f[0], f[1]]))

    def test_vertical_sweep_confirms(self):
        self.assertTrue(stacks.pano_confirmed([g.T for g in self.sweep(30, w=170, h=256)]))


if __name__ == "__main__":
    unittest.main()
