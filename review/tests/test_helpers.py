"""The test helpers themselves: annotations.db opens as it does in production, and the NAS skip says why."""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
from review.tests import helpers  # noqa: E402


class AnnotationsConnection(unittest.TestCase):
    def pragmas(self, con):
        return (con.execute("PRAGMA journal_mode").fetchone()[0], con.execute("PRAGMA busy_timeout").fetchone()[0],
                con.row_factory is not None)

    def test_the_tests_open_it_the_way_the_server_does(self):
        import server
        with tempfile.TemporaryDirectory() as tmp:
            with patch.dict(server.CFG, {"annotations": Path(tmp) / "server.db"}):
                prod = server.anno()
            mine = helpers.anno_connection(Path(tmp) / "tests.db")
            try:
                self.assertEqual(self.pragmas(mine), self.pragmas(prod))
                self.assertEqual(self.pragmas(mine), ("wal", 5000, True))
            finally:
                prod.close()
                mine.close()

    def test_a_writer_waits_for_another_writer_instead_of_failing(self):
        import threading
        import time
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "a.db"
            setup = helpers.anno_connection(path)
            setup.execute("CREATE TABLE t(x)")
            setup.commit()
            setup.close()
            holding = threading.Event()

            def hold():                                     # a write transaction open for 0.3 s
                con = helpers.anno_connection(path)
                con.execute("BEGIN IMMEDIATE")
                con.execute("INSERT INTO t VALUES (1)")
                holding.set()
                time.sleep(0.3)
                con.commit()
                con.close()
            holder = threading.Thread(target=hold)
            holder.start()
            holding.wait(5)
            second = helpers.anno_connection(path)
            t = time.monotonic()
            with second:
                second.execute("INSERT INTO t VALUES (2)")  # waits for the first commit, doesn't fail
            self.assertGreater(time.monotonic() - t, 0.15)
            holder.join(5)
            self.assertEqual(second.execute("SELECT COUNT(*) FROM t").fetchone()[0], 2)
            second.close()


class NasSkip(unittest.TestCase):
    def test_not_mounted(self):
        with patch("os.path.ismount", return_value=False):
            self.assertEqual(helpers.nas_problem(), "needs the NAS: /mnt/passport is not mounted")
            self.assertIn("is not mounted", helpers.nas_problem("/mnt/passport/Pictures/x.ARW"))

    def test_mounted_but_the_file_is_missing(self):
        with patch("os.path.ismount", return_value=True), tempfile.NamedTemporaryFile() as there:
            self.assertIsNone(helpers.nas_problem(there.name))
            self.assertEqual(helpers.nas_problem(there.name, "/nope/DSC1.ARW"), "needs the NAS: /nope/DSC1.ARW is not there")

    def test_require_nas_skips_with_the_reason(self):
        class Case:
            reason = None

            def skipTest(self, reason):
                self.reason = reason
        case = Case()
        with patch("os.path.ismount", return_value=False):
            helpers.require_nas(case, "/x")
        self.assertEqual(case.reason, "needs the NAS: /mnt/passport is not mounted")


if __name__ == "__main__":
    unittest.main()
