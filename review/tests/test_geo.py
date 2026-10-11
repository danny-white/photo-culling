"""photo_cull.Places: the offline nearest-town lookup behind Culling Bay's places. Needs the
GeoNames files in trial_out/geo (see photo_cull.py geotag --help). Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
GEO = ROOT / "trial_out" / "geo"


@unittest.skipUnless((GEO / "cities1000.txt").exists(), "needs the GeoNames files in trial_out/geo")
class PlacesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import photo_cull as pc
        cls.places = pc.Places(GEO)

    def test_known_points(self):
        self.assertTrue(self.places.name(19.4286, -99.1660).endswith("Mexico City, Mexico"))   # an iPhone frame, Feb 2026
        self.assertTrue(self.places.name(20.8283, -156.9197).endswith("Hawaii, United States"))  # Lanai City
        self.assertTrue(self.places.name(48.8584, 2.2945).endswith("France"))                    # the Eiffel Tower

    def test_across_the_dateline(self):
        # nearest by great circle, so a point just east of 180 degrees still finds Fiji
        self.assertTrue(self.places.name(-16.8, -179.99).endswith("Fiji"))


if __name__ == "__main__":
    unittest.main()
