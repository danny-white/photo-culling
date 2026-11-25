"""Shared pieces for the server tests: the NAS skip, annotations.db opened the way the server opens
it, and a photo_cull stand-in for tests that must not read the NAS."""
import os
import sqlite3
from pathlib import Path

NAS = "/mnt/passport"


def nas_problem(*paths) -> str | None:
    """Why a test that reads the photo library can't run here, or None if it can. Tells "the NAS is
    not mounted" from "that one file isn't there"."""
    if not os.path.ismount(NAS):
        return f"needs the NAS: {NAS} is not mounted"
    for p in paths:
        if not Path(p).exists():
            return f"needs the NAS: {p} is not there"
    return None


def require_nas(case, *paths) -> None:
    """Skip the running test, saying why, unless the NAS is mounted and holds these files."""
    problem = nas_problem(*paths)
    if problem:
        case.skipTest(problem)


def anno_connection(path) -> sqlite3.Connection:
    """annotations.db as server.anno() opens it: a 5 s timeout, busy_timeout and WAL, so the
    tests meet the same lock waits as production (test_helpers checks the two agree)."""
    con = sqlite3.connect(str(path), timeout=5.0)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=5000")
    con.execute("PRAGMA journal_mode=WAL")
    return con


class FakePC:
    """photo_cull, except that a photo's preview is a small grey picture (or raises load_error), so a
    test of the routes needs no NAS."""
    load_error: Exception | None = None

    def __getattr__(self, name):
        import photo_cull
        return getattr(photo_cull, name)

    def load_source(self, path):
        from PIL import Image
        if self.load_error:
            raise self.load_error
        return Image.new("RGB", (64, 48), "grey")
