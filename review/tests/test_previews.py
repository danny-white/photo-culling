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
from review.tests.helpers import require_nas  # noqa: E402

TRIAL_DB = ROOT / "trial_out" / "trial.db"


class PreviewTest(unittest.TestCase):
    def test_names_match_what_the_server_has_always_used(self):
        p = "/mnt/passport/Pictures/2026/2026-10-01/DSC05040.ARW"
        want = "m-" + hashlib.md5(f"m:{p}:320".encode()).hexdigest() + ".jpg"
        self.assertEqual(previews.preview_path(Path("/c"), p, 320), Path("/c") / want)

    def test_sizes_match_the_phone_routes(self):
        import mobile
        self.assertEqual(previews.SIZES, mobile.IMG_EDGE)

    def test_threads_writing_the_same_preview_never_publish_a_broken_file(self):
        """Two requests for one uncached picture write it at once. Each writes its own temporary file and
        renames it into place, so nobody fails and a reader sees the old file or a whole new one."""
        import threading
        from PIL import Image
        im = Image.effect_noise((900, 600), 60).convert("RGB")      # noise: a JPEG big enough to take a while
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "m-x.jpg"
            errors, bad, reads, stop = [], [], [], threading.Event()

            def write():
                for _ in range(25):
                    try:
                        previews.write_atomic(im, dest)
                    except Exception as e:  # noqa: BLE001
                        errors.append(f"{type(e).__name__}: {e}")

            def read():
                while not stop.is_set():
                    try:
                        data = dest.read_bytes()
                    except FileNotFoundError:
                        continue                                    # not published yet
                    reads.append(1)
                    if not data.endswith(b"\xff\xd9"):               # a JPEG ends with its EOI marker
                        bad.append(len(data))
            reader = threading.Thread(target=read)
            reader.start()
            writers = [threading.Thread(target=write) for _ in range(4)]
            for t in writers:
                t.start()
            for t in writers:
                t.join(60)
            stop.set()
            reader.join(10)
            self.assertEqual(errors, [])
            self.assertEqual(bad, [], f"{len(bad)} of {len(reads)} reads saw a short file")
            self.assertGreater(len(reads), 0)
            with Image.open(dest) as out:
                out.load()
            self.assertEqual([f.name for f in Path(tmp).iterdir()], ["m-x.jpg"], "no temporary file left behind")

    @unittest.skipUnless(TRIAL_DB.exists(), "needs trial_out/trial.db")
    def test_make_writes_both_sizes_once(self):
        from PIL import Image
        con = sqlite3.connect(f"file:{TRIAL_DB}?mode=ro", uri=True)
        path = con.execute("SELECT path FROM images WHERE status='ok' AND lower(path) LIKE '%.arw' LIMIT 1").fetchone()[0]
        con.close()
        require_nas(self, path)
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
