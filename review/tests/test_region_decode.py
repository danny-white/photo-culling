"""The region-only decode against the full decode, on real ARWs from the library.

    ./venv/bin/python -m unittest review.tests.test_region_decode

Needs trial_out/trial.db and the NAS mounted; skipped otherwise. Takes a few seconds (it runs the
full decode for comparison).
"""
import sqlite3
import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
TRIAL_DB = ROOT / "trial_out" / "trial.db"
from review.tests.helpers import require_nas  # noqa: E402


def library_path(rowid):
    if not TRIAL_DB.exists():
        return None
    con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
    try:
        r = con.execute("SELECT path FROM images WHERE rowid=?", (rowid,)).fetchone()
    finally:
        con.close()
    return r[0] if r else None


class RegionDecode(unittest.TestCase):
    def compare(self, rowid, x, y):
        import rawpy
        import region_decode as rd
        path = library_path(rowid)
        if not path:
            self.skipTest(f"needs trial_out/trial.db with photo {rowid}")
        require_nas(self, path)
        with rawpy.imread(path) as raw:
            full = raw.postprocess(use_camera_wb=True)
        H, W = full.shape[:2]
        left, top, w, h = rd.crop_box(W, H, x, y, 600, 600)
        im, box = rd.decode_region(path, x, y, 600, 600)
        self.assertEqual(box, (left, top, w, h, W, H))
        ref = full[top:top + h, left:left + w].astype(np.int16)
        new = np.asarray(im).astype(np.int16)
        self.assertEqual(new.shape, ref.shape)
        return np.abs(new - ref).mean(), np.abs(ref.reshape(-1, 3).mean(0) - new.reshape(-1, 3).mean(0)).max()

    def test_a_daylight_frame_matches_the_full_decode(self):
        diff, colour = self.compare(35604, 0.5703, 0.5062)      # Rainier, landscape
        self.assertLess(diff, 2.5)
        self.assertLess(colour, 1.5)

    def test_a_portrait_frame_is_turned_upright_and_matches(self):
        diff, colour = self.compare(34241, 0.4708, 0.4922)      # snow tree, sensor turned 90°
        self.assertLess(diff, 2.5)
        self.assertLess(colour, 1.5)

    def test_a_noisy_frame_keeps_its_brightness_and_colour(self):
        diff, colour = self.compare(37428, 0.5, 0.5)            # cat eye, ISO 12800: grain differs
        self.assertLess(colour, 3)


if __name__ == "__main__":
    unittest.main()
