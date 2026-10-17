"""review/previews.py: same file names as the server, and both sizes from one read."""
import hashlib
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
import previews  # noqa: E402

TRIAL_DB = ROOT / "trial_out" / "trial.db"


class PreviewTest(unittest.TestCase):
    def test_names_match_what_the_server_has_always_used(self):
        p = "/mnt/passport/Pictures/2026/2026-10-01/DSC05040.ARW"
        want = "m-" + hashlib.md5(f"m:{p}:320".encode()).hexdigest() + ".jpg"
        self.assertEqual(previews.preview_path(Path("/c"), p, 320), Path("/c") / want)

    def test_sizes_match_the_phone_routes(self):
        import mobile
        self.assertEqual(previews.SIZES, mobile.IMG_EDGE)

    @unittest.skipUnless(TRIAL_DB.exists(), "needs trial_out/trial.db")
    def test_make_writes_both_sizes_once(self):
        from PIL import Image
        con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
        path = con.execute("SELECT path FROM images WHERE status='ok' AND lower(path) LIKE '%.arw' LIMIT 1").fetchone()[0]
        con.close()
        if not Path(path).exists():
            self.skipTest("the NAS is not mounted")
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            self.assertEqual(previews.make(path, cache), "made")
            self.assertEqual(previews.make(path, cache), "had")
            for edge in (320, 1616):
                with Image.open(previews.preview_path(cache, path, edge)) as im:
                    self.assertEqual(max(im.size), edge)
            self.assertEqual(sorted(f.suffix for f in cache.iterdir()), [".jpg", ".jpg"])   # no .tmp left
            self.assertEqual(previews.make("/nope/missing.ARW", cache), "unreadable")


if __name__ == "__main__":
    unittest.main()
