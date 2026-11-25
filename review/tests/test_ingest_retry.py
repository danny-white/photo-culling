"""photo_cull's retry rules: empty files, the Ollama preflight and mid-run loss, the one in-run
retry, `run --retry-failed`, and `folder-state`. A temp DB, temp folders and a fake Ollama client:
the real model is never called. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import contextlib
import io
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import httpx
import ollama
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import photo_cull as pc  # noqa: E402


class FakeClient:
    """Stands in for ollama.Client. `list_error` makes the preflight fail."""
    list_error = None

    def __init__(self, *a, **kw):
        self.timeout = kw.get("timeout")

    def list(self):
        if FakeClient.list_error:
            raise FakeClient.list_error
        return {"models": []}


class Fixture(unittest.TestCase):
    """A temp library (two shoot folders), a temp DB, and a scripted analyze_vlm."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.db = self.root / "t.db"
        self.a = self.root / "lib" / "2026" / "2026-01-01"
        self.b = self.root / "lib" / "2026" / "2026-01-02"
        for d in (self.a, self.b):
            d.mkdir(parents=True)
        FakeClient.list_error = None
        self.calls = []                  # file names the model was asked about, in order
        self.script = []                 # per model call: an exception to raise, or None for success
        self.loaded = []                 # file names load_source was asked to open

        def fake_load(path):
            self.loaded.append(path.name)
            return Image.new("RGB", (64, 64), (120, 120, 120))

        def fake_analyze(client, work, fast, prompt=None, model=None):
            self.calls.append(self.current)
            step = self.script.pop(0) if self.script else None
            if step is not None:
                raise step
            return pc.coerce_vlm({"caption": "a grey square"}), "fake-model"

        # process_one has no file name for analyze_vlm, so note it from load_source
        orig_load = fake_load

        def load_and_note(path):
            self.current = path.name
            return orig_load(path)

        patches = [
            mock.patch.object(pc, "load_source", load_and_note),
            mock.patch.object(pc, "analyze_vlm", fake_analyze),
            mock.patch.object(pc, "read_exif", lambda p: {"capture_ts": None, "camera": None, "lens": None}),
            mock.patch.object(pc, "harness_version", lambda: "test"),
            mock.patch.object(ollama, "Client", FakeClient),
            mock.patch.object(pc.time, "sleep"),
        ]
        self.sleep = patches[-1].start()
        self.addCleanup(patches[-1].stop)
        for p in patches[:-1]:
            p.start()
            self.addCleanup(p.stop)

    # helpers
    def put(self, folder, name, size=10):
        p = folder / name
        p.write_bytes(b"x" * size)
        return p

    def cli(self, *argv):
        """Run photo_cull's CLI in-process. Returns (exit code, stdout, stderr)."""
        out, err = io.StringIO(), io.StringIO()
        code = 0
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                args = pc.build_parser().parse_args([str(a) for a in argv])
                args.func(args)
            except SystemExit as e:
                code = e.code if isinstance(e.code, int) else 1
                if isinstance(e.code, str):
                    err.write(e.code)
        return code, out.getvalue(), err.getvalue()

    def run_cli(self, *folders, extra=()):
        return self.cli("run", *folders, "--db", self.db, *extra)

    def register(self, *folders):
        conn = pc.connect(self.db)
        for f in folders:
            pc.register_targets(conn, f, recursive=True)
        conn.close()

    def set_row(self, path, **fields):
        conn = pc.connect(self.db)
        pc.upsert_result(conn, str(path), fields)
        conn.close()

    def rows(self):
        conn = pc.connect(self.db)
        try:
            return {Path(r["path"]).name: dict(r) for r in conn.execute("SELECT * FROM images")}
        finally:
            conn.close()


class EmptyFiles(Fixture):
    def test_empty_file_is_an_error_without_loading_or_calling_the_model(self):
        self.put(self.a, "full.ARW")
        self.put(self.a, "empty.ARW", size=0)
        code, out, _ = self.run_cli(self.a)
        self.assertEqual(code, 0)
        rows = self.rows()
        self.assertEqual(rows["full.ARW"]["status"], "ok")
        e = rows["empty.ARW"]
        self.assertEqual((e["status"], e["error_class"], e["attempts"]), ("error", "empty", 1))
        self.assertIn("empty (0 bytes)", e["error_msg"])
        self.assertTrue(e["last_attempt_at"])
        self.assertEqual(self.loaded, ["full.ARW"])      # the empty file was never opened
        self.assertEqual(self.calls, ["full.ARW"])        # and never reached the model

    def test_empty_file_is_never_retried(self):
        self.put(self.a, "empty.ARW", size=0)
        self.run_cli(self.a)
        code, out, _ = self.run_cli(self.a, extra=["--retry-failed"])
        self.assertIn("Nothing to do", out)
        self.assertEqual(self.rows()["empty.ARW"]["attempts"], 1)

    def test_old_zero_byte_io_rows_are_not_retryable_either(self):
        # How the 32 empty originals were recorded in August: class io, size 0, one attempt.
        p = self.put(self.a, "old.CR3", size=0)
        self.register(self.a)
        self.set_row(p, status="error", error_class="io", error_msg="Input/output error", attempts=1)
        code, out, _ = self.run_cli(self.a, extra=["--retry-failed"])
        self.assertIn("Nothing to do", out)
        self.assertEqual(self.rows()["old.CR3"]["error_class"], "io")
        _, state, _ = self.cli("folder-state", "--db", self.db, self.a)
        self.assertEqual(state.rstrip("\n").split("\t")[1:], ["1", "1", "0", "0", "1"])
        # --redrive still visits every error row; it now says plainly why this one can't be read.
        self.run_cli(self.a, extra=["--redrive"])
        self.assertEqual(self.rows()["old.CR3"]["error_class"], "empty")


class OllamaDown(Fixture):
    def test_preflight_failure_exits_3_and_changes_no_rows(self):
        for n in ("1.ARW", "2.ARW"):
            self.put(self.a, n)
        self.register(self.a)
        before = self.rows()
        FakeClient.list_error = ConnectionError("Failed to connect to Ollama.")
        code, out, err = self.run_cli(self.a)
        self.assertEqual(code, 3)
        self.assertIn("Ollama isn't answering", err)
        self.assertEqual(len(err.strip().splitlines()), 1)           # one line
        self.assertEqual(self.rows(), before)
        self.assertEqual(self.calls, [])

    def test_preflight_is_skipped_when_there_is_nothing_to_do(self):
        FakeClient.list_error = ConnectionError("down")
        code, out, _ = self.run_cli(self.a)                           # an empty folder
        self.assertEqual(code, 0)
        self.assertIn("Nothing to do", out)

    def test_connect_failure_mid_run_leaves_the_rest_pending(self):
        for n in ("1.ARW", "2.ARW", "3.ARW"):
            self.put(self.a, n)
        # what ollama-python raises when the connection is refused
        self.script = [None, ConnectionError("Failed to connect to Ollama.")]
        code, out, err = self.run_cli(self.a)
        self.assertEqual(code, 3)
        self.assertIn("Ollama stopped answering; 2 photos left pending", err)
        rows = self.rows()
        self.assertEqual(rows["1.ARW"]["status"], "ok")
        for n in ("2.ARW", "3.ARW"):
            self.assertEqual(rows[n]["status"], "pending")
            self.assertFalse(rows[n]["attempts"])                     # no attempt recorded
            self.assertIsNone(rows[n]["last_attempt_at"])
        self.assertIsNone(rows["2.ARW"]["error_class"])
        # The next run, with Ollama back, finishes them.
        code, _, _ = self.run_cli(self.a)
        self.assertEqual(code, 0)
        self.assertEqual({r["status"] for r in self.rows().values()}, {"ok"})

    def test_httpx_connect_error_counts_as_down_but_a_timeout_does_not(self):
        self.assertTrue(pc.is_connect_error(httpx.ConnectError("refused")))
        self.assertTrue(pc.is_connect_error(ConnectionRefusedError()))
        self.assertTrue(pc.is_connect_error(ConnectionError("Failed to connect to Ollama.")))
        self.assertFalse(pc.is_connect_error(httpx.ConnectTimeout("slow")))
        self.assertFalse(pc.is_connect_error(httpx.ReadTimeout("slow")))
        self.assertFalse(pc.is_connect_error(ConnectionResetError()))
        self.assertFalse(pc.is_connect_error(ollama.ResponseError("boom", 500)))


class InlineRetry(Fixture):
    def one_photo(self):
        self.put(self.a, "1.ARW")

    def test_a_timeout_is_retried_once_after_a_pause(self):
        self.one_photo()
        self.script = [httpx.ReadTimeout("timed out")]
        code, _, _ = self.run_cli(self.a)
        self.assertEqual(code, 0)
        self.assertEqual(len(self.calls), 2)
        self.sleep.assert_called_once_with(pc.TRANSIENT_WAIT_S)
        row = self.rows()["1.ARW"]
        self.assertEqual((row["status"], row["attempts"]), ("ok", 1))   # one attempt, not two

    def test_a_dropped_connection_and_a_5xx_are_retried_too(self):
        self.put(self.a, "1.ARW")
        self.put(self.a, "2.ARW")
        self.script = [httpx.RemoteProtocolError("Server disconnected without sending a response."), None,
                       ollama.ResponseError("internal error", 503), None]
        self.run_cli(self.a)
        self.assertEqual(self.calls, ["1.ARW", "1.ARW", "2.ARW", "2.ARW"])
        self.assertEqual({r["status"] for r in self.rows().values()}, {"ok"})

    def test_two_failures_in_a_row_record_the_error(self):
        self.one_photo()
        self.script = [httpx.ReadTimeout("timed out"), httpx.ReadTimeout("timed out")]
        self.run_cli(self.a)
        self.assertEqual(len(self.calls), 2)
        row = self.rows()["1.ARW"]
        self.assertEqual((row["status"], row["error_class"], row["attempts"]), ("error", "timeout", 1))

    def test_a_retry_that_finds_ollama_gone_is_not_recorded(self):
        self.one_photo()
        self.script = [httpx.ReadTimeout("timed out"), ConnectionError("Failed to connect to Ollama.")]
        code, _, err = self.run_cli(self.a)
        self.assertEqual(code, 3)
        row = self.rows()["1.ARW"]
        self.assertEqual(row["status"], "pending")
        self.assertFalse(row["attempts"])

    def test_other_errors_are_not_retried(self):
        self.one_photo()
        self.script = [ValueError("bad json")]
        self.run_cli(self.a)
        self.assertEqual(len(self.calls), 1)
        self.sleep.assert_not_called()
        self.assertEqual(self.rows()["1.ARW"]["error_class"], "json_parse")

    def test_a_4xx_and_an_oom_are_not_transient(self):
        self.assertFalse(pc.is_transient_model_error(ollama.ResponseError("model not found", 404)))
        self.assertFalse(pc.is_transient_model_error(ollama.ResponseError("CUDA error: out of memory", 500)))
        self.assertTrue(pc.is_transient_model_error(ollama.ResponseError("runner stopped", 502)))


class RetryFailed(Fixture):
    def seed(self):
        """Folder a: one retryable, one at the cap, one empty, one class-empty. Folder b: one retryable."""
        self.put(self.a, "retry.ARW")
        self.put(self.a, "capped.ARW")
        self.put(self.a, "zero.ARW", size=0)
        self.put(self.a, "empty.ARW")
        self.put(self.a, "done.ARW")
        self.put(self.b, "other.ARW")
        self.register(self.a, self.b)
        err = dict(status="error", error_class="model", error_msg="Server disconnected")
        self.set_row(self.a / "retry.ARW", attempts=1, **err)
        self.set_row(self.a / "capped.ARW", attempts=pc.MAX_ATTEMPTS, **err)
        self.set_row(self.a / "zero.ARW", attempts=1, **{**err, "error_class": "io"})
        self.set_row(self.a / "empty.ARW", attempts=1, **{**err, "error_class": "empty"})
        self.set_row(self.a / "done.ARW", status="ok", attempts=1)
        self.set_row(self.b / "other.ARW", attempts=1, **err)

    def statuses(self):
        return {n: (r["status"], r["attempts"]) for n, r in self.rows().items()}

    def test_plain_run_leaves_error_rows_alone(self):
        self.seed()
        code, out, _ = self.run_cli(self.a)
        self.assertIn("Nothing to do", out)
        self.assertEqual(self.calls, [])

    def test_retry_failed_takes_only_retryable_rows_under_the_named_folder(self):
        self.seed()
        code, out, _ = self.run_cli(self.a, extra=["--retry-failed"])
        self.assertEqual(code, 0)
        self.assertEqual(self.calls, ["retry.ARW"])
        s = self.statuses()
        self.assertEqual(s["retry.ARW"], ("ok", 2))                    # tried again, attempts counted
        self.assertTrue(self.rows()["retry.ARW"]["last_attempt_at"])
        self.assertEqual(s["capped.ARW"], ("error", pc.MAX_ATTEMPTS))  # out of tries
        self.assertEqual(s["zero.ARW"], ("error", 1))                  # empty
        self.assertEqual(s["empty.ARW"], ("error", 1))
        self.assertEqual(s["other.ARW"], ("error", 1))                 # another folder: not named

    def test_retry_failed_also_does_pending_rows_anywhere(self):
        self.seed()
        self.put(self.b, "new.ARW")
        self.register(self.b)
        self.run_cli(self.a, extra=["--retry-failed"])
        self.assertEqual(sorted(self.calls), ["new.ARW", "retry.ARW"])

    def test_the_attempts_cap_stops_retries(self):
        self.put(self.a, "bad.ARW")
        self.script = [ValueError("bad json")] * 10                    # json_parse every time
        self.run_cli(self.a)                                           # try 1
        for want in (2, 3, 4):
            self.run_cli(self.a, extra=["--retry-failed"])
            self.assertEqual(self.rows()["bad.ARW"]["attempts"], want)
        calls = len(self.calls)
        code, out, _ = self.run_cli(self.a, extra=["--retry-failed"])
        self.assertIn("Nothing to do", out)
        self.assertEqual(len(self.calls), calls)
        self.assertEqual(pc.MAX_ATTEMPTS, 4)

    def test_redrive_still_takes_every_error_row_but_empty_ones_stay_errors(self):
        self.seed()
        self.run_cli(self.a, extra=["--redrive"])
        s = self.statuses()
        self.assertEqual(s["other.ARW"], ("ok", 2))                    # another folder: redrive is DB-wide
        self.assertEqual(s["capped.ARW"], ("ok", pc.MAX_ATTEMPTS + 1))
        self.assertEqual(s["zero.ARW"][0], "error")
        self.assertEqual(self.rows()["zero.ARW"]["error_class"], "empty")

    def test_null_attempts_and_error_class_still_count_as_retryable(self):
        self.put(self.a, "n.ARW")
        self.register(self.a)
        conn = pc.connect(self.db)
        conn.execute("UPDATE images SET status='error', attempts=NULL, error_class=NULL")
        conn.commit()
        conn.close()
        self.run_cli(self.a, extra=["--retry-failed"])
        self.assertEqual(self.rows()["n.ARW"]["status"], "ok")

    def test_folder_names_with_like_characters_do_not_leak(self):
        odd = self.root / "lib" / "2026" / "2026_01%01"
        twin = self.root / "lib" / "2026" / "2026x01y01"
        odd.mkdir()
        twin.mkdir()
        self.put(odd, "a.ARW")
        self.put(twin, "b.ARW")
        self.register(odd, twin)
        self.set_row(odd / "a.ARW", status="error", error_class="model", attempts=1)
        self.set_row(twin / "b.ARW", status="error", error_class="model", attempts=1)
        self.run_cli(odd, extra=["--retry-failed"])
        self.assertEqual(self.calls, ["a.ARW"])


class FolderState(Fixture):
    def lines(self, *argv):
        code, out, err = self.cli("folder-state", "--db", self.db, *argv)
        self.assertEqual(code, 0, err)
        return [ln.split("\t") for ln in out.splitlines()]

    def test_counts(self):
        for n in ("ok.ARW", "retry.ARW", "capped.ARW", "zero.ARW", "pend.ARW"):
            self.put(self.a, n, size=0 if n == "zero.ARW" else 10)
        self.put(self.a, ".hidden.ARW")                  # dotfile: not registered, not counted
        self.put(self.a, "notes.txt")                    # not a photo type
        (self.a / "sub").mkdir()
        self.put(self.a / "sub", "deep.JPG")             # recursive
        self.put(self.b, "b.ARW")
        self.register(self.a, self.b)
        err = dict(status="error", error_class="model")
        self.set_row(self.a / "ok.ARW", status="ok", attempts=1)
        self.set_row(self.a / "retry.ARW", attempts=2, **err)
        self.set_row(self.a / "capped.ARW", attempts=4, **err)
        self.set_row(self.a / "zero.ARW", attempts=1, **{**err, "error_class": "io"})
        self.set_row(self.a / "sub" / "deep.JPG", status="ok", attempts=1)
        # a.ARW is on disk but unregistered: add a file after registering
        self.put(self.a, "late.ARW")
        got = self.lines(self.a, str(self.b) + "/", self.root / "lib" / "2026" / "nope")
        self.assertEqual(got[0], [str(self.a), "7", "6", "1", "1", "2"])
        #                         folder      disk  rows pend retry unreadable
        self.assertEqual(got[1], [str(self.b), "1", "1", "1", "0", "0"])
        self.assertEqual(got[2], [str(self.root / "lib" / "2026" / "nope"), "0", "0", "0", "0", "0"])

    def test_a_parent_folder_counts_its_subfolders(self):
        self.put(self.a, "1.ARW")
        self.put(self.b, "2.ARW")
        self.register(self.a, self.b)
        got = self.lines(self.root / "lib" / "2026", self.a)
        self.assertEqual(got[0][1:3], ["2", "2"])
        self.assertEqual(got[1][1:3], ["1", "1"])

    def test_junk_files_are_not_counted(self):
        # What a Mac, Finder and Lightroom leave in a shoot folder: never registered, so never counted.
        self.put(self.a, "1.ARW")
        self.put(self.a, "2.arw")                        # case does not matter
        for junk in (".DS_Store", "._1.ARW", "1.xmp", "clip.MOV", "clip.mp4", "script.lua", "x.psd", "readme"):
            self.put(self.a, junk)
        self.register(self.a)
        self.assertEqual(self.lines(self.a), [[str(self.a), "2", "2", "2", "0", "0"]])

    def test_print_extensions_is_what_a_run_registers(self):
        code, out, _ = self.cli("folder-state", "--print-extensions")        # needs no DB
        self.assertEqual(code, 0)
        self.assertEqual(out.split(), sorted(pc.ALL_EXTENSIONS))
        self.assertTrue(all(e.startswith(".") and e == e.lower() for e in out.split()))

    def test_needs_a_folder(self):
        pc.connect(self.db).close()
        code, _, err = self.cli("folder-state", "--db", self.db)
        self.assertEqual(code, 1)
        self.assertIn("at least one FOLDER", err)

    def test_missing_db(self):
        code, _, err = self.cli("folder-state", "--db", self.root / "none.db", self.a)
        self.assertEqual(code, 1)
        self.assertIn("No database", err)

    def test_retryable_only(self):
        self.put(self.a, "r.ARW")
        self.put(self.a / "..", "stray.ARW")             # lib/2026/stray.ARW, shallower than a shoot
        (self.a / "sub").mkdir()
        self.put(self.a / "sub", "s.ARW")
        self.put(self.b, "z.ARW", size=0)
        self.register(self.a, self.b, self.root / "lib" / "2026")
        err = dict(status="error", error_class="model", attempts=1)
        self.set_row(self.a / "r.ARW", **err)
        self.set_row(self.a / "sub" / "s.ARW", **err)
        self.set_row(self.root / "lib" / "2026" / "stray.ARW", **err)
        self.set_row(self.b / "z.ARW", **{**err, "error_class": "io"})
        # under a root: the shoot folder (two levels down), once, whatever sits below it
        lib = self.root / "lib"
        self.assertEqual(self.lines("--retryable-only", lib),
                         [[str(lib / "2026")], [str(self.a)]])
        # a root with nothing under it prints nothing
        self.assertEqual(self.lines("--retryable-only", self.root / "elsewhere"), [])
        # with no root: the folder that holds each file
        self.assertEqual(self.lines("--retryable-only"),
                         [[str(self.root / "lib" / "2026")], [str(self.a)], [str(self.a / "sub")]])

    def test_opens_the_db_read_only_and_does_not_migrate(self):
        # A DB from before last_attempt_at: folder-state must read it without adding the column.
        conn = sqlite3.connect(self.db)
        conn.execute("CREATE TABLE images(path TEXT PRIMARY KEY, filename TEXT, mtime REAL, size INTEGER, "
                     "status TEXT, attempts INTEGER, error_class TEXT)")
        conn.execute("INSERT INTO images VALUES(?,?,?,?,?,?,?)",
                     (str(self.a / "x.ARW"), "x.ARW", 0, 10, "error", 1, "model"))
        conn.commit()
        conn.close()
        self.put(self.a, "x.ARW")
        self.assertEqual(self.lines(self.a), [[str(self.a), "1", "1", "0", "1", "0"]])
        conn = sqlite3.connect(self.db)
        cols = [r[1] for r in conn.execute("PRAGMA table_info(images)")]
        conn.close()
        self.assertNotIn("last_attempt_at", cols)

    def test_fast_for_a_big_library(self):
        import time
        conn = pc.connect(self.db)
        conn.executemany("INSERT INTO images(path, filename, size, status, attempts, error_class) "
                         "VALUES(?,?,?,?,?,?)",
                         [(f"/lib/{2000 + i % 30}/{2000 + i % 30}-01-{i % 400:03d}/{i}.ARW", f"{i}.ARW",
                           10, "ok" if i % 50 else "error", 1, "model") for i in range(43000)])
        conn.commit()
        conn.close()
        folders = [self.root / "nothing" / str(i) for i in range(400)]
        t0 = time.time()
        got = self.lines(*folders)
        self.assertEqual(len(got), 400)
        self.assertLess(time.time() - t0, 5)


class Migration(Fixture):
    def test_last_attempt_at_is_added_to_an_old_db(self):
        pc.connect(self.db).close()
        conn = sqlite3.connect(self.db)
        conn.execute("ALTER TABLE images DROP COLUMN last_attempt_at")      # a DB from before this column
        conn.commit()
        conn.close()
        pc.connect(self.db).close()
        pc.connect(self.db).close()                      # idempotent
        conn = sqlite3.connect(self.db)
        cols = [r[1] for r in conn.execute("PRAGMA table_info(images)")]
        conn.close()
        self.assertEqual(cols.count("last_attempt_at"), 1)

    def test_fresh_db_has_the_column(self):
        conn = pc.connect(self.db)
        cols = [r[1] for r in conn.execute("PRAGMA table_info(images)")]
        conn.close()
        self.assertEqual(cols.count("last_attempt_at"), 1)


if __name__ == "__main__":
    unittest.main()
