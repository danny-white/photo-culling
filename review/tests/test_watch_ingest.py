"""ops/watch_ingest.sh, run for real against a temp library, temp markers and log, a stub Python
that records its calls and acts like photo_cull.py, and a stub msmtp on PATH. Nothing here touches
the live checkout, the NAS or Ollama, and no email leaves the machine. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import os
import re
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import photo_cull as pc  # noqa: E402

SCRIPT = ROOT / "ops" / "watch_ingest.sh"

# Stands in for `./venv/bin/python`: the watcher calls `$PY photo_cull.py <command> ...` and
# `$PY review/previews.py ...`. Every call is appended to calls.log. `folder-state` answers from
# folder-state.tsv (folder, files_on_disk, db_rows, pending, retryable, unreadable; a folder not
# listed is clean); exit codes come from rc.<command> or, for run, rc.run.<folder name>.
STUB_PY = r"""#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls.log"
[ "$1" = photo_cull.py ] && shift
cmd=$(basename "$1" .py); shift
case "$cmd" in
  folder-state)
    retry_only=0; folders=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --db) shift ;;
        --retryable-only) retry_only=1 ;;
        --print-extensions) cat "$STUB_DIR/extensions.txt"; exit 0 ;;
        *) folders+=("$1") ;;
      esac
      shift
    done
    [ -e "$STUB_DIR/folder-state.fail" ] && exit 1
    # folder-state.fail-folder: the per-folder counts fail, the list of retryable folders does not
    [ -e "$STUB_DIR/folder-state.fail-folder" ] && [ "$retry_only" = 0 ] && exit 1
    if [ "$retry_only" = 1 ]; then
      [ -f "$STUB_DIR/folder-state.tsv" ] && awk -F'\t' '$5 > 0 { print $1 }' "$STUB_DIR/folder-state.tsv"
    else
      for f in "${folders[@]}"; do
        line=
        [ -f "$STUB_DIR/folder-state.tsv" ] && line=$(awk -F'\t' -v f="$f" '$1 == f' "$STUB_DIR/folder-state.tsv")
        # a folder the test said nothing about is clean, unless folder-state.strict asks for silence
        if [ -n "$line" ]; then echo "$line"
        elif [ ! -e "$STUB_DIR/folder-state.strict" ]; then printf '%s\t0\t0\t0\t0\t0\n' "$f"; fi
      done
    fi
    exit 0 ;;
  run)
    folder=$(basename "$1")
    [ -f "$STUB_DIR/rc.run.$folder" ] && exit "$(cat "$STUB_DIR/rc.run.$folder")"
    # photos "tagged" by this run: run.ok rows of status ok go into the DB
    [ -f "$STUB_DIR/run.ok" ] && for _ in $(seq "$(cat "$STUB_DIR/run.ok")"); do
      sqlite3 "$DB" "INSERT INTO images VALUES('ok')"
    done
    # what the run did to the folder's rows: after-run.tsv becomes the folder-state answer
    [ -f "$STUB_DIR/after-run.tsv" ] && cp "$STUB_DIR/after-run.tsv" "$STUB_DIR/folder-state.tsv"
    ;;
esac
[ -f "$STUB_DIR/rc.$cmd" ] && exit "$(cat "$STUB_DIR/rc.$cmd")"
exit 0
"""

# Logs every find the watcher runs, then runs the real one.
STUB_FIND = r"""#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/find.log"
exec /usr/bin/find "$@"
"""

STUB_MSMTP = r"""#!/usr/bin/env bash
{ echo "ARGS: $*"; cat; echo "-----"; } >> "$STUB_DIR/mail.log"
[ -f "$STUB_DIR/rc.msmtp" ] && exit "$(cat "$STUB_DIR/rc.msmtp")"
exit 0
"""


class WatcherCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.lib = self.root / "lib"
        self.markers = self.root / "markers"
        self.log = self.root / "watch.log"
        self.db = self.root / "t.db"
        self.stub = self.root / "stub"
        self.bin = self.root / "bin"
        for d in (self.lib, self.stub, self.bin):
            d.mkdir()
        self.py = self.stub / "py"
        self.write_exec(self.py, STUB_PY)
        self.write_exec(self.bin / "msmtp", STUB_MSMTP)
        self.write_exec(self.bin / "find", STUB_FIND)
        # what `folder-state --print-extensions` says: photo_cull's own list
        (self.stub / "extensions.txt").write_text("".join(e + "\n" for e in sorted(pc.ALL_EXTENSIONS)))
        con = sqlite3.connect(self.db)
        con.execute("CREATE TABLE images(status TEXT)")
        con.commit()
        con.close()
        self.now = int(time.time())
        self.states = {}

    # --- fixtures
    @staticmethod
    def write_exec(path: Path, text: str):
        path.write_text(text)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def folder(self, date, n=3, age=6 * 3600, dir_age=None, ext=".ARW"):
        """A shoot folder lib/YYYY/date with n photos last written `age` seconds ago (camera dates
        can be years older: pass a big age) and the folder itself changed `dir_age` ago."""
        d = self.lib / date[:4] / date
        d.mkdir(parents=True, exist_ok=True)
        for i in range(n):
            self.add_file(d, f"IMG_{i:04d}{ext}", age + i * 60)
        self.touch_dir(d, age if dir_age is None else dir_age)
        return d

    def add_file(self, d, name, age, size=10):
        p = d / name
        p.write_bytes(b"x" * size)
        t = self.now - age
        os.utime(p, (t, t))
        return p

    def touch_dir(self, d, age):
        t = self.now - age
        os.utime(d, (t, t))

    def signature(self, d):
        """The marker a finished folder should hold: its own mtime, and the newest mtime and count
        of the files photo_cull.py would register."""
        photos = [p for p in d.rglob("*") if p.is_file() and not p.name.startswith(".")
                  and p.suffix.lower() in pc.ALL_EXTENSIONS]
        return "v2 %d %d %d %d" % (int(d.stat().st_mtime), max(int(p.stat().st_mtime) for p in photos), len(photos),
                                   sum(p.stat().st_size for p in photos))

    def set_state(self, d, disk, rows, pending=0, retryable=0, unreadable=0):
        self.states[str(d)] = (disk, rows, pending, retryable, unreadable)
        lines = ["\t".join([f, *map(str, v)]) for f, v in self.states.items()]
        (self.stub / "folder-state.tsv").write_text("\n".join(lines) + "\n")

    def set_after_run(self, d, disk, rows, pending=0, retryable=0, unreadable=0):
        """What folder-state will say once `run` has been called (the run's effect on the rows)."""
        after = dict(self.states)
        after[str(d)] = (disk, rows, pending, retryable, unreadable)
        lines = ["\t".join([f, *map(str, v)]) for f, v in after.items()]
        (self.stub / "after-run.tsv").write_text("\n".join(lines) + "\n")

    def step_names(self):
        """The photo_cull commands called, in order, as `run`, `export`, `folder-state` ..."""
        return [re.sub(r"^photo_cull\.py ", "", c).split()[0] for c in self.calls()]

    def marker(self, d):
        return self.markers / (d.name + ".done")

    def set_marker(self, d, text):
        self.markers.mkdir(exist_ok=True)
        self.marker(d).write_text(text + "\n")

    def marker_text(self, d):
        m = self.marker(d)
        return m.read_text().strip() if m.exists() else None

    # --- running it
    def poll(self, **env_over):
        env = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOME": str(self.root),
            "STUB_DIR": str(self.stub),
            "PROJ": str(self.root),
            "DB": str(self.db),
            "LIBRARY_ROOT": str(self.lib),
            "INBOX": str(self.root / "inbox"),
            "MARKERS": str(self.markers),
            "LOG": str(self.log),
            "PY": str(self.py),
            "CHECK_MOUNT": "0",
            "NOTIFY_EMAIL": "nobody@example.invalid",
        }
        env.update({k: str(v) for k, v in env_over.items()})
        return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=120)

    def calls(self):
        f = self.stub / "calls.log"
        return f.read_text().splitlines() if f.exists() else []

    def clear_calls(self):
        (self.stub / "calls.log").unlink(missing_ok=True)
        (self.stub / "find.log").unlink(missing_ok=True)

    def finds(self):
        f = self.stub / "find.log"
        return f.read_text().splitlines() if f.exists() else []

    def mails(self):
        f = self.stub / "mail.log"
        return f.read_text().split("-----\n")[:-1] if f.exists() else []

    def set_db(self, status, n=1):
        con = sqlite3.connect(self.db)
        con.executemany("INSERT INTO images VALUES(?)", [(status,)] * n)
        con.commit()
        con.close()

    def age_stamp(self, name, seconds):
        t = time.time() - seconds
        os.utime(self.markers / name, (t, t))

    def runs(self):
        """Folders `run` was called for, in order."""
        return [Path(m.group(1)).name for c in self.calls() if (m := re.match(r"photo_cull\.py run (\S+) ", c))]

    def log_text(self):
        return self.log.read_text() if self.log.exists() else ""

    def log_lines(self, prefix):
        return [re.sub(r"^\[[^\]]+\] ", "", ln) for ln in self.log_text().splitlines()
                if re.sub(r"^\[[^\]]+\] ", "", ln).startswith(prefix)]


class NewAndBusyFolders(WatcherCase):
    def test_a_new_folder_is_processed_and_marked(self):
        d = self.folder("2026-10-01")
        r = self.poll()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.runs(), ["2026-10-01"])
        self.assertIn(f"photo_cull.py run {d} --db {self.db} --retry-failed", self.calls())
        self.assertEqual(self.marker_text(d), self.signature(d))
        self.assertEqual(self.log_lines("processing "), [f"processing {d}"])
        self.assertEqual(self.log_lines("done: "), [f"done: {d} -> {self.root}/inbox/pending.tsv"])
        # the follow-up steps run in order, then the export, then the check that it is finished
        names = [re.sub(r"^photo_cull\.py ", "", c).split()[0] for c in self.calls()]
        self.assertEqual(names, ["folder-state", "folder-state", "run", "embed", "embed-images", "geotag", "shotinfo",
                                 "daysum", "review/previews.py", "export", "folder-state"])

    def test_a_marked_folder_is_left_alone(self):
        d = self.folder("2026-10-01")
        self.poll()
        self.clear_calls()
        r = self.poll()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.runs(), [])
        self.assertEqual(len(self.log_lines("processing ")), 1)         # still just the first time

    def test_a_folder_changed_a_moment_ago_is_busy(self):
        d = self.folder("2026-10-01", dir_age=60)                       # files are old, the copy is not
        self.poll()
        self.assertEqual(self.runs(), [])
        self.assertIsNone(self.marker_text(d))

    def test_a_file_written_a_moment_ago_makes_it_busy(self):
        d = self.folder("2026-10-01", dir_age=3600)
        self.add_file(d, "fresh.ARW", 120)
        self.touch_dir(d, 3600)
        self.poll()
        self.assertEqual(self.runs(), [])

    def test_busy_for_a_whole_window_then_picked_up(self):
        d = self.folder("2026-10-01", dir_age=14 * 60)
        self.poll()
        self.assertEqual(self.runs(), [])
        self.touch_dir(d, 16 * 60)                                      # 15 minutes have gone by
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])

    def test_stable_minutes_can_be_changed(self):
        self.folder("2026-10-01", dir_age=600)
        self.poll(STABLE_MINUTES=5)
        self.assertEqual(self.runs(), ["2026-10-01"])

    def test_empty_folders_and_other_top_level_folders_are_skipped(self):
        (self.lib / "2024" / "2024-04-26").mkdir(parents=True)
        other = self.lib / "screenshots" / "2026-01-01"
        other.mkdir(parents=True)
        (other / "a.png").write_bytes(b"x")
        self.poll()
        self.assertEqual(self.runs(), [])

    def test_folders_are_processed_oldest_first(self):
        self.folder("2026-10-02")
        self.folder("2025-03-01")
        self.folder("2026-01-05")
        self.poll()
        self.assertEqual(self.runs(), ["2025-03-01", "2026-01-05", "2026-10-02"])


class LateFiles(WatcherCase):
    def test_an_old_dated_file_copied_in_later_is_reprocessed(self):
        # The 2026-06-27 case: the copy was still running when the folder was first looked at, and
        # the files keep their June dates, so only the folder's own mtime moves.
        d = self.folder("2026-06-27", n=3, age=140 * 86400)
        self.poll()
        first = self.marker_text(d)
        self.assertEqual(self.runs(), ["2026-06-27"])
        self.add_file(d, "IMG_0099.ARW", 140 * 86400 + 5)               # older than the rest
        self.touch_dir(d, 20 * 60)                                      # copied 20 minutes ago
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), ["2026-06-27"])
        self.assertNotEqual(self.marker_text(d), first)
        self.assertEqual(self.marker_text(d), self.signature(d))
        self.assertEqual(self.marker_text(d).split()[3], "4")
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), [])

    def test_a_late_file_that_is_still_being_copied_waits(self):
        d = self.folder("2026-06-27", n=3, age=140 * 86400)
        self.poll()
        self.add_file(d, "IMG_0099.ARW", 140 * 86400)
        self.touch_dir(d, 60)                                           # copied a minute ago
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), [])

    def test_a_removed_file_changes_the_signature_too(self):
        d = self.folder("2026-06-27", n=3)
        self.poll()
        (d / "IMG_0001.ARW").unlink()
        self.touch_dir(d, 3600)
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), ["2026-06-27"])


class RetryBackoff(WatcherCase):
    def test_retryable_rows_leave_the_folder_unmarked_and_it_is_revisited(self):
        d = self.folder("2026-09-29")
        self.set_state(d, 3, 3, retryable=2)
        self.poll()
        self.assertEqual(self.runs(), ["2026-09-29"])
        self.assertIsNone(self.marker_text(d))
        self.assertEqual(self.log_lines("retry pending for "), [f"retry pending for {d}: 2 photos"])
        self.assertEqual(self.log_lines("done: "), [])
        # next poll: tried again (one try per poll)
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), ["2026-09-29"])
        self.assertIsNone(self.marker_text(d))
        # the tries run out (the rows become unreadable): now it is finished
        self.set_state(d, 3, 3, retryable=0, unreadable=2)
        self.clear_calls()
        self.poll()
        self.assertEqual(self.marker_text(d), self.signature(d))
        self.assertEqual(len(self.log_lines("done: ")), 1)
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), [])

    def test_pending_rows_also_hold_the_marker_back(self):
        d = self.folder("2026-09-29")
        self.set_state(d, 3, 3, pending=1)
        self.poll()
        self.assertIsNone(self.marker_text(d))
        self.assertEqual(self.log_lines("retry pending for "), [f"retry pending for {d}: 1 photos"])

    def test_unreadable_rows_do_not_block_the_marker(self):
        d = self.folder("2024-04-14")
        self.set_state(d, 3, 3, unreadable=3)
        self.poll()
        self.assertEqual(self.marker_text(d), self.signature(d))

    def test_a_finished_folder_is_revisited_when_it_has_retryable_rows_again(self):
        d = self.folder("2026-09-29")
        self.poll()
        self.assertEqual(self.marker_text(d), self.signature(d))
        self.set_state(d, 3, 3, retryable=1)                            # signature unchanged
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), ["2026-09-29"])

    def test_retryable_rows_in_a_busy_folder_wait(self):
        d = self.folder("2026-09-29", dir_age=60)
        self.set_state(d, 3, 3, retryable=1)
        self.poll()
        self.assertEqual(self.runs(), [])

    def test_retryable_rows_elsewhere_do_not_pull_in_other_folders(self):
        a = self.folder("2026-09-29")
        b = self.folder("2026-09-30")
        self.poll()
        self.set_state(a, 3, 3, retryable=1)
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), ["2026-09-29"])

    def test_export_failure_leaves_it_unmarked(self):
        d = self.folder("2026-10-01")
        (self.stub / "rc.export").write_text("1")
        self.poll()
        self.assertIsNone(self.marker_text(d))
        self.assertEqual(self.log_lines("export FAILED for "), [f"export FAILED for {d} -- leaving unmarked, will retry next poll"])

    def test_unreadable_state_leaves_it_unmarked(self):
        d = self.folder("2026-10-01")
        (self.stub / "folder-state.fail").write_text("")
        self.poll()
        self.assertIsNone(self.marker_text(d))
        self.assertTrue(self.log_lines("retry pending for "))


class RunExitCodes(WatcherCase):
    def test_exit_3_means_ollama_is_down_and_ends_the_poll(self):
        a = self.folder("2026-10-01")
        b = self.folder("2026-10-02")
        (self.stub / "rc.run").write_text("3")
        r = self.poll()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.runs(), ["2026-10-01"])                   # the second folder is not tried
        self.assertEqual(self.log_lines("run deferred"), ["run deferred: Ollama not answering"])
        self.assertNotIn("FAILED", self.log_text())
        self.assertIsNone(self.marker_text(a))
        self.assertIsNone(self.marker_text(b))
        # nothing after the run was attempted
        self.assertFalse([c for c in self.calls() if " embed " in c or " export " in c])
        # Ollama is back: the next poll does both
        (self.stub / "rc.run").unlink()
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01", "2026-10-02"])

    def test_any_other_failure_skips_that_folder_and_goes_on(self):
        a = self.folder("2026-10-01")
        b = self.folder("2026-10-02")
        (self.stub / "rc.run.2026-10-01").write_text("1")
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01", "2026-10-02"])
        self.assertEqual(self.log_lines("run FAILED"), [f"run FAILED for {a} -- leaving unmarked, will retry next poll"])
        self.assertIsNone(self.marker_text(a))
        self.assertIsNotNone(self.marker_text(b))


class OldMarkers(WatcherCase):
    def newest(self, d):
        return max(int(p.stat().st_mtime) for p in d.rglob("*") if p.is_file())

    def state_calls(self):
        return [c for c in self.calls() if c.startswith("photo_cull.py folder-state")
                and "--retryable-only" not in c and "--print-extensions" not in c]

    def test_an_old_marker_is_upgraded_without_processing_when_the_counts_match(self):
        d = self.folder("2026-02-02", n=4)
        self.set_marker(d, f"{self.newest(d)}.0000000000")              # the old format, as on disk today
        self.set_state(d, 4, 4)
        self.poll()
        self.assertEqual(self.runs(), [])
        self.assertEqual(self.marker_text(d), self.signature(d))
        self.assertEqual(len(self.log_lines("marker upgraded for ")), 1)
        self.assertEqual(self.log_lines("done: "), [])

    def test_an_old_marker_is_reprocessed_when_the_counts_differ(self):
        d = self.folder("2026-06-27", n=21)
        self.set_marker(d, f"{self.newest(d)}.0000000000")
        self.set_state(d, 21, 12)                                       # 21 on disk, 12 in the DB
        self.poll()
        self.assertEqual(self.runs(), ["2026-06-27"])
        self.assertEqual(self.marker_text(d), self.signature(d))

    def test_an_old_marker_is_reprocessed_when_the_newest_file_is_not_the_one_it_names(self):
        d = self.folder("2026-02-02", n=4)
        self.set_marker(d, f"{self.newest(d) - 500}.0000000000")
        self.set_state(d, 4, 4)
        self.poll()
        self.assertEqual(self.runs(), ["2026-02-02"])

    def test_an_old_marker_with_retryable_or_pending_rows_is_processed(self):
        a = self.folder("2026-02-02")
        b = self.folder("2026-02-03")
        for d in (a, b):
            self.set_marker(d, str(self.newest(d)))
        self.set_state(a, 3, 3, retryable=2)
        self.set_state(b, 3, 3, pending=1)
        self.poll()
        self.assertEqual(self.runs(), ["2026-02-02", "2026-02-03"])

    def test_many_old_markers_are_checked_with_one_folder_state_call(self):
        ds = [self.folder(f"2026-03-{day:02d}") for day in range(1, 9)]
        for d in ds:
            self.set_marker(d, f"{self.newest(d)}.0000000000")
            self.set_state(d, 3, 3)
        self.poll()
        self.assertEqual(self.runs(), [])
        calls = self.state_calls()
        self.assertEqual(len(calls), 1)
        for d in ds:
            self.assertIn(str(d), calls[0])
        self.assertTrue(all(self.marker_text(d) == self.signature(d) for d in ds))

    def test_a_busy_old_marker_folder_is_left_alone(self):
        d = self.folder("2026-02-02", dir_age=60)
        self.set_marker(d, str(self.newest(d)))
        self.set_state(d, 3, 3)
        self.poll()
        self.assertEqual(self.marker_text(d), str(self.newest(d)))
        self.assertEqual(self.runs(), [])

    def test_if_folder_state_fails_nothing_is_reprocessed_and_markers_stay(self):
        ds = [self.folder(f"2026-03-{day:02d}") for day in range(1, 4)]
        for d in ds:
            self.set_marker(d, str(self.newest(d)))
        (self.stub / "folder-state.fail").write_text("")
        self.poll()
        self.assertEqual(self.runs(), [])                               # no mass reprocess
        for d in ds:
            self.assertEqual(self.marker_text(d), str(self.newest(d)))
        self.assertTrue(self.log_lines("old markers not checked"))
        # it works again next poll
        (self.stub / "folder-state.fail").unlink()
        for d in ds:
            self.set_state(d, 3, 3)
        self.poll()
        self.assertEqual(self.runs(), [])
        self.assertTrue(all(self.marker_text(d) == self.signature(d) for d in ds))

    def test_a_folder_missing_from_the_answer_is_not_reprocessed(self):
        a = self.folder("2026-03-01")
        b = self.folder("2026-03-02")
        for d in (a, b):
            self.set_marker(d, str(self.newest(d)))
        self.set_state(a, 3, 3)                                         # nothing about b
        (self.stub / "folder-state.strict").write_text("")
        self.poll()
        self.assertEqual(self.runs(), [])
        self.assertEqual(self.marker_text(a), self.signature(a))
        self.assertEqual(self.marker_text(b), str(self.newest(b)))


class JunkFiles(WatcherCase):
    """What a Mac, Finder and Lightroom leave in a shoot folder (.DS_Store, ._ files, .xmp
    sidecars, videos) is not something the ingest registers, so it must not send a finished folder
    back to Lightroom. A new photo must."""
    JUNK = (".DS_Store", "._IMG_0000.ARW", "IMG_0000.xmp", "clip.MOV", "clip.mp4", "grade.lua", "edit.psd", "notes")

    def finished(self, **kw):
        d = self.folder("2026-10-01", **kw)
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])
        self.clear_calls()
        return d

    def test_junk_added_to_a_finished_folder_does_not_reprocess_it(self):
        d = self.finished()
        before = self.marker_text(d)
        for name in self.JUNK:
            self.add_file(d, name, 1800)                 # newer than the photos, old enough not to be busy
        self.touch_dir(d, 1200)                          # the folder's own mtime moved
        r = self.poll()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.runs(), [])
        self.assertEqual(len(self.log_lines("processing ")), 1)
        # only the folder's mtime in the marker moved; the photo count and newest photo did not
        self.assertEqual(self.marker_text(d), self.signature(d))
        self.assertNotEqual(self.marker_text(d), before)
        self.assertEqual(self.marker_text(d).split()[2:], before.split()[2:])
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), [])

    def test_a_sidecar_written_in_place_changes_nothing(self):
        d = self.finished()
        x = self.add_file(d, "IMG_0000.xmp", 7200)
        self.touch_dir(d, 7200)
        self.poll()
        before = self.marker_text(d)
        t = self.now - 1200
        os.utime(x, (t, t))                              # Lightroom rewrote it; the folder's mtime did not move
        self.poll()
        self.assertEqual(self.marker_text(d), before)
        self.assertEqual(len(self.log_lines("processing ")), 1)

    def test_the_marker_counts_only_photos(self):
        d = self.folder("2026-10-01", n=3)
        for name in self.JUNK:
            self.add_file(d, name, 600 * 6)
        self.add_file(d, "late.xmp", 3600)              # newer than every photo
        self.touch_dir(d, 3600)
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])
        parts = self.marker_text(d).split()
        self.assertEqual(parts[0], "v2")
        self.assertEqual(parts[3], "3")                  # three photos, not 12 files
        newest_photo = max(int(p.stat().st_mtime) for p in d.glob("IMG_000?.ARW") if not p.name.startswith("."))
        self.assertEqual(int(parts[2]), newest_photo)    # not the sidecar's time

    def test_a_new_photo_does_reprocess_it(self):
        for name, ext in (("late.arw", "lower case"), ("late.JPG", "a jpeg"), ("late.Cr3", "mixed case"),
                          ("late.heic", "a heic")):
            with self.subTest(ext):
                self.setUp()
                d = self.finished()
                for junk in self.JUNK:
                    self.add_file(d, junk, 3000)
                self.add_file(d, name, 6 * 3600 + 5)       # an old camera date, like a late card copy
                self.touch_dir(d, 1200)
                self.poll()
                self.assertEqual(self.runs(), ["2026-10-01"])
                self.assertEqual(self.marker_text(d).split()[3], "4")

    def test_a_removed_photo_does_reprocess_it(self):
        d = self.finished()
        (d / "IMG_0001.ARW").unlink()
        self.touch_dir(d, 1200)
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])

    def test_a_new_newest_photo_reprocesses_even_with_the_same_count(self):
        d = self.finished()
        t = self.now - 1500
        os.utime(d / "IMG_0001.ARW", (t, t))             # a photo written again, newer than all
        self.age_stamp(".last-full-scan", 25 * 3600)     # (the folder's mtime didn't move: see IdleCost)
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])

    def test_a_fresh_junk_file_still_makes_the_folder_busy(self):
        d = self.folder("2026-10-01")
        self.add_file(d, ".DS_Store", 90)                # Finder just wrote it
        self.touch_dir(d, 3600)
        self.poll()
        self.assertEqual(self.runs(), [])
        self.touch_dir(d, 3600)
        os.utime(d / ".DS_Store", (self.now - 1200, self.now - 1200))
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])

    def test_a_folder_with_no_photos_is_skipped(self):
        d = self.lib / "2026" / "2026-10-05"
        d.mkdir(parents=True)
        for name in self.JUNK:
            self.add_file(d, name, 7200)
        self.touch_dir(d, 7200)
        self.poll()
        self.assertEqual(self.runs(), [])
        # the folder's mtime is noted, so later polls skip it by a stat instead of a find
        self.assertEqual(self.marker_text(d), f"v2 {int(d.stat().st_mtime)} 0 0 0")
        self.clear_calls()
        self.poll()
        self.assertEqual(self.finds(), [])
        # until a photo is copied in
        self.add_file(d, "IMG_0001.ARW", 6 * 3600)
        self.touch_dir(d, 1200)
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-05"])
        self.assertEqual(self.marker_text(d).split()[3], "1")

    def test_a_folder_with_no_photos_but_failed_rows_is_still_run(self):
        d = self.lib / "2026" / "2026-10-05"
        d.mkdir(parents=True)
        self.add_file(d, "IMG_0000.xmp", 7200)
        self.touch_dir(d, 7200)
        self.set_state(d, 0, 2, retryable=2)             # rows for photos that are gone
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-05"])

    def test_a_dry_run_does_not_note_the_mtime_of_a_folder_with_no_photos(self):
        d = self.lib / "2026" / "2026-10-05"
        d.mkdir(parents=True)
        self.touch_dir(d, 7200)
        self.markers.mkdir()
        self.poll(DRY_RUN=1)
        self.assertIsNone(self.marker_text(d))

    def test_junk_newer_than_the_photos_does_not_stop_an_old_marker_upgrading(self):
        # The 55 real folders whose newest file is a sidecar or video: the old marker holds that time.
        d = self.folder("2026-02-02", n=4)
        x = self.add_file(d, "IMG_0000.xmp", 3 * 3600)
        self.touch_dir(d, 3 * 3600)
        self.set_marker(d, f"{int(x.stat().st_mtime)}.0000000000")
        self.set_state(d, 4, 4)
        self.poll()
        self.assertEqual(self.runs(), [])
        self.assertEqual(self.marker_text(d), self.signature(d))

    def test_an_old_marker_naming_the_newest_photo_upgrades_when_only_junk_is_newer(self):
        d = self.folder("2026-02-02", n=4)
        newest_photo = max(int(p.stat().st_mtime) for p in d.glob("*.ARW"))
        self.add_file(d, "IMG_0000.xmp", 3 * 3600)       # written after the folder was marked
        self.touch_dir(d, 3 * 3600)
        self.set_marker(d, f"{newest_photo}.0000000000")
        self.set_state(d, 4, 4)
        self.poll()
        self.assertEqual(self.runs(), [])
        self.assertEqual(self.marker_text(d), self.signature(d))

    def test_the_extension_list_comes_from_photo_cull_not_from_the_script(self):
        text = SCRIPT.read_text().lower()
        for ext in pc.ALL_EXTENSIONS:
            self.assertNotIn(ext, text, f"{ext} is hard-coded in watch_ingest.sh; read it with --print-extensions")
        self.assertIn("--print-extensions", text)

    def test_no_extensions_means_no_poll(self):
        self.folder("2026-10-01")
        (self.stub / "extensions.txt").write_text("")
        r = self.poll()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.runs(), [])
        self.assertTrue(self.log_lines("poll skipped"))


class IdleCost(WatcherCase):
    """An idle poll looks at each folder's own mtime and nothing else."""

    def three_finished(self):
        ds = [self.folder(f"2026-10-0{i}") for i in (1, 2, 3)]
        self.poll()
        self.assertEqual(len(self.runs()), 3)
        self.clear_calls()
        return ds

    def test_unchanged_folders_get_no_find_and_no_python_call(self):
        self.three_finished()
        r = self.poll()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.finds(), [])
        # the only Python calls are the two that cover the whole poll: the extension list and the
        # folders with failed photos; none is about a folder
        self.assertEqual(len(self.calls()), 2)
        self.assertTrue(any("--print-extensions" in c for c in self.calls()))
        self.assertTrue(any("--retryable-only" in c for c in self.calls()))
        self.assertEqual(self.runs(), [])

    def test_only_the_changed_folder_gets_a_find(self):
        ds = self.three_finished()
        self.add_file(ds[1], "late.ARW", 6 * 3600)
        self.touch_dir(ds[1], 1200)
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-02"])
        self.assertEqual(len(self.finds()), 2)           # one to look, one just before the run
        self.assertTrue(all(str(ds[1]) in f for f in self.finds()))
        self.assertEqual(len([c for c in self.calls() if c.startswith("photo_cull.py folder-state")
                              and "--retryable-only" not in c and "--print-extensions" not in c]), 1)

    def test_a_folder_with_a_changed_mtime_but_the_same_photos_gets_a_find_and_no_run(self):
        ds = self.three_finished()
        self.add_file(ds[0], ".DS_Store", 3000)
        self.touch_dir(ds[0], 1200)
        self.poll()
        self.assertEqual(self.runs(), [])
        self.assertEqual(len(self.finds()), 1)
        self.assertEqual(self.marker_text(ds[0]), self.signature(ds[0]))

    def test_the_daily_full_pass_looks_at_every_folder(self):
        ds = self.three_finished()
        self.assertTrue((self.markers / ".last-full-scan").exists())     # the first poll did the first pass
        self.poll()
        self.assertEqual(self.finds(), [])                               # a fresh stamp: no pass
        # a photo rewritten in place with a newer time; the folder's own mtime did not move
        t = self.now - 1500
        os.utime(ds[2] / "IMG_0002.ARW", (t, t))
        self.age_stamp(".last-full-scan", 23 * 3600)
        self.poll()
        self.assertEqual(self.runs(), [])                                # under 24 hours: still no pass
        self.age_stamp(".last-full-scan", 25 * 3600)
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-03"])                    # found, and only that one
        self.assertGreaterEqual(len(self.finds()), 3)                    # every folder was looked at
        age = time.time() - (self.markers / ".last-full-scan").stat().st_mtime
        self.assertLess(age, 120)                                        # and the stamp renewed
        self.clear_calls()
        self.poll()
        self.assertEqual(self.finds(), [])

    def test_the_first_poll_is_a_full_pass(self):
        self.folder("2026-10-01")
        self.poll()
        self.assertTrue((self.markers / ".last-full-scan").exists())

    def test_a_dry_run_leaves_the_stamps_alone(self):
        self.three_finished()
        self.age_stamp(".last-full-scan", 25 * 3600)
        before = (self.markers / ".last-full-scan").stat().st_mtime
        self.poll(DRY_RUN=1)
        self.assertEqual((self.markers / ".last-full-scan").stat().st_mtime, before)


class Heartbeat(WatcherCase):
    POLL = re.compile(r"^poll: (\d+) folders, (\d+) changed, (\d+) processed, (\d+)s$")

    def beats(self):
        return [self.POLL.match(ln).groups() for ln in self.log_lines("poll: ")]

    def test_a_poll_that_processed_something_logs_a_parseable_line(self):
        self.folder("2026-10-01")
        self.folder("2026-10-02")
        self.poll()
        (b,) = self.beats()
        self.assertEqual(b[:3], ("2", "2", "2"))

    def test_an_idle_poll_stays_quiet_inside_the_hour_then_logs_once(self):
        for i in (1, 2, 3):
            self.folder(f"2026-10-0{i}")
        self.poll()                                      # processed: logs
        self.poll()                                      # idle, inside the hour: nothing
        self.poll()
        self.assertEqual(len(self.beats()), 1)
        self.age_stamp(".last-heartbeat", 61 * 60)
        self.poll()
        self.assertEqual(len(self.beats()), 2)
        self.assertEqual(self.beats()[1][:3], ("3", "0", "0"))           # three folders, none changed
        self.poll()
        self.assertEqual(len(self.beats()), 2)

    def test_a_poll_that_processes_something_always_logs(self):
        d = self.folder("2026-10-01")
        self.poll()
        self.add_file(d, "late.ARW", 6 * 3600)
        self.touch_dir(d, 1200)
        self.poll()                                      # the stamp is minutes old, but a folder was processed
        self.assertEqual(len(self.beats()), 2)
        self.assertEqual(self.beats()[1][:3], ("1", "1", "1"))

    def test_the_count_of_changed_folders(self):
        a = self.folder("2026-10-01")
        self.folder("2026-10-02")
        self.poll()
        (self.markers / ".last-heartbeat").unlink()
        self.add_file(a, ".DS_Store", 3000)              # a change that needs a look but no run
        self.touch_dir(a, 1200)
        self.poll()
        self.assertEqual(self.beats()[-1][:3], ("2", "1", "0"))

    def test_the_line_is_logged_after_the_work_and_never_looks_like_a_failure(self):
        self.folder("2026-10-01")
        self.poll()
        lines = self.log_lines("")
        self.assertTrue(lines[-1].startswith("poll: "))
        self.assertNotIn("FAILED", lines[-1])

    def test_no_heartbeat_when_the_poll_aborts(self):
        self.folder("2026-10-01")
        (self.root / "inbox").mkdir()
        self.poll(CHECK_MOUNT=1)
        self.assertEqual(self.beats(), [])

    def test_dry_run_prints_one_line_and_keeps_no_stamp(self):
        self.folder("2026-10-01")
        r = self.poll(DRY_RUN=1)
        self.assertRegex(r.stdout, r"DRY RUN: poll: 1 folders, 1 changed, 1 to process, \d+s")
        self.assertFalse(self.markers.exists())


class BatchEmail(WatcherCase):
    def test_one_email_when_a_poll_finishes_folders_and_nothing_is_pending(self):
        a = self.folder("2026-10-01")
        b = self.folder("2026-10-02")
        (self.stub / "run.ok").write_text("5")           # each run tags 5 photos
        self.set_state(a, 5, 5, unreadable=2)
        self.set_state(b, 5, 5, unreadable=1)
        self.poll()
        (mail,) = self.mails()
        self.assertIn("ARGS: nobody@example.invalid", mail)
        self.assertIn("Subject: Photo cull: batch complete (10 processed)", mail)
        self.assertIn("To: nobody@example.invalid", mail)
        self.assertIn("2 folder(s) done, 10 photo(s) processed", mail)
        self.assertIn("  2026-10-01", mail)
        self.assertIn("  2026-10-02", mail)
        self.assertIn("Photos waiting for a retry: 0", mail)
        self.assertIn("Originals that can't be read: 3", mail)
        self.assertIn("Sync AI Cull Data", mail)
        self.assertEqual(self.log_lines("sent batch-complete email"), ["sent batch-complete email (10 processed)"])

    def test_it_fires_once_not_on_the_next_idle_poll(self):
        self.folder("2026-10-01")
        self.poll()
        self.poll()
        self.poll()
        self.assertEqual(len(self.mails()), 1)

    def test_an_idle_poll_sends_nothing(self):
        self.poll()
        self.assertEqual(self.mails(), [])

    def test_nothing_is_sent_while_photos_are_still_pending(self):
        self.set_db("pending", 3)
        self.folder("2026-10-01")
        self.poll()
        self.assertEqual(self.mails(), [])
        # the queue drains; the poll that finishes the next folder sends the email, for that folder only
        con = sqlite3.connect(self.db)
        con.execute("DELETE FROM images WHERE status='pending'")
        con.commit()
        con.close()
        self.folder("2026-10-02")
        self.poll()
        (mail,) = self.mails()
        self.assertIn("1 folder(s) done", mail)
        self.assertIn("  2026-10-02", mail)
        self.assertNotIn("  2026-10-01", mail)

    def test_a_folder_that_is_waiting_for_a_retry_is_not_finished_so_no_email(self):
        d = self.folder("2026-10-01")
        self.set_state(d, 3, 3, retryable=2)
        self.poll()
        self.assertEqual(self.mails(), [])
        self.set_state(d, 3, 3, retryable=0, unreadable=2)
        self.poll()
        (mail,) = self.mails()
        self.assertIn("Originals that can't be read: 2", mail)

    def test_the_retry_count_is_in_the_body_when_another_folder_is_waiting(self):
        a = self.folder("2026-10-01")
        b = self.folder("2026-10-02")
        self.set_state(a, 3, 3, retryable=4)
        self.poll()
        (mail,) = self.mails()
        self.assertIn("1 folder(s) done", mail)
        self.assertIn("Photos waiting for a retry: 4", mail)

    def test_a_deferred_poll_with_ollama_down_sends_nothing(self):
        self.folder("2026-10-01")
        (self.stub / "rc.run").write_text("3")
        self.poll()
        self.assertEqual(self.mails(), [])

    def test_a_failed_send_is_logged(self):
        self.folder("2026-10-01")
        (self.stub / "rc.msmtp").write_text("1")
        self.poll()
        self.assertEqual(len(self.log_lines("msmtp send FAILED")), 1)
        self.assertEqual(len(self.mails()), 1)

    def test_a_dry_run_sends_nothing(self):
        self.folder("2026-10-01")
        self.poll(DRY_RUN=1)
        self.assertEqual(self.mails(), [])


class ReplacedInPlace(WatcherCase):
    """A photo replaced by a different file of the same name and camera date (DAN-126: restoring
    the empty originals) changes neither the photo count nor the newest photo, only the bytes."""

    def replace(self, d, name="IMG_0001.ARW", size=25):
        p = d / name
        st = p.stat()
        p.write_bytes(b"y" * size)
        os.utime(p, (st.st_mtime, st.st_mtime))          # the same camera date
        return p

    def test_the_marker_holds_the_total_bytes_of_the_photos_only(self):
        d = self.folder("2026-10-01", n=3)               # 3 x 10 bytes
        self.add_file(d, "IMG_0000.xmp", 7200, size=999)
        self.add_file(d, ".DS_Store", 7200, size=999)
        self.touch_dir(d, 7200)
        self.poll()
        self.assertEqual(self.marker_text(d).split()[3:], ["3", "30"])
        self.assertEqual(self.marker_text(d), self.signature(d))

    def test_a_replaced_photo_is_reprocessed_when_the_folder_mtime_moves(self):
        d = self.folder("2026-10-01", n=3)
        self.poll()
        self.clear_calls()
        self.replace(d)
        self.touch_dir(d, 1200)                          # a Finder replace usually does move it
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])
        self.assertEqual(self.marker_text(d).split()[3:], ["3", "45"])

    def test_a_replaced_photo_with_an_unmoved_folder_mtime_is_found_by_the_daily_pass(self):
        d = self.folder("2026-10-01", n=3)
        self.poll()
        before = d.stat().st_mtime
        self.replace(d)
        os.utime(d, (before, before))                    # an overwrite in place leaves the folder's mtime alone
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), [])
        self.age_stamp(".last-full-scan", 25 * 3600)
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])

    def test_a_marker_without_the_byte_total_is_upgraded_not_reprocessed(self):
        d = self.folder("2026-10-01", n=3)
        sig = self.signature(d).split()
        self.set_marker(d, " ".join(sig[:4]))            # v2 <dir mtime> <newest> <count>
        self.poll()
        self.assertEqual(self.runs(), [])
        self.assertEqual(self.marker_text(d), self.signature(d))
        self.assertEqual(self.log_lines("processing "), [])

    def test_a_three_field_marker_with_an_older_folder_mtime_is_upgraded_too(self):
        d = self.folder("2026-10-01", n=3)
        sig = self.signature(d).split()
        self.set_marker(d, f"v2 {int(sig[1]) - 5000} {sig[2]} {sig[3]}")
        self.poll()
        self.assertEqual(self.runs(), [])
        self.assertEqual(self.marker_text(d), self.signature(d))

    def test_a_three_field_marker_naming_other_photos_is_reprocessed(self):
        d = self.folder("2026-10-01", n=3)
        sig = self.signature(d).split()
        self.set_marker(d, f"v2 {sig[1]} {sig[2]} 2")    # one photo fewer than there are
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])

    def test_a_three_field_marker_with_retryable_rows_is_a_retry_only_visit(self):
        d = self.folder("2026-10-01", n=3)
        sig = self.signature(d).split()
        self.set_marker(d, " ".join(sig[:4]))
        self.set_state(d, 3, 3, retryable=1)
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])
        self.assertNotIn("export", self.step_names())


class RetryOnly(WatcherCase):
    """A visit whose only reason is failed photos with tries left runs the retries and sends the
    folder to Lightroom again only if a photo was recovered."""
    STEPS = ("embed", "embed-images", "geotag", "shotinfo", "daysum", "review/previews.py", "export")

    def finished_with_retries(self, rows=3, retryable=2):
        """A finished folder (current marker) that then gets failed rows again."""
        d = self.folder("2026-10-01", n=rows)
        self.poll()
        self.set_state(d, rows, rows, retryable=retryable)
        self.clear_calls()
        return d

    def test_nothing_recovered_means_no_steps_and_no_export(self):
        d = self.finished_with_retries()
        self.set_after_run(d, 3, 3, retryable=2)
        before = self.marker_text(d)
        self.poll()
        names = self.step_names()
        self.assertEqual(self.runs(), ["2026-10-01"])
        self.assertIn(f"photo_cull.py run {d} --db {self.db} --retry-failed", self.calls())
        self.assertFalse([n for n in names if n in self.STEPS], names)
        self.assertEqual(self.log_lines("retry pending for "),
                         [f"retry pending for {d}: 2 photos (none recovered this time)"])
        self.assertEqual(self.log_lines("done: ")[1:], [])               # no second done line
        self.assertEqual(self.marker_text(d), before)
        self.assertEqual(len(self.mails()), 1)                           # only the first visit's

    def test_a_recovered_photo_runs_the_steps_and_the_export(self):
        d = self.finished_with_retries()
        self.set_after_run(d, 3, 3, retryable=1)                        # one more is ok now
        self.poll()
        names = self.step_names()
        for step in self.STEPS:
            self.assertIn(step, names)
        self.assertEqual(self.log_lines("retry pending for "), [f"retry pending for {d}: 1 photos"])

    def test_retries_running_out_without_a_recovery_finish_the_folder_without_an_export(self):
        d = self.finished_with_retries(retryable=1)
        self.set_after_run(d, 3, 3, retryable=0, unreadable=1)          # the last try failed too
        self.poll()
        self.assertNotIn("export", self.step_names())
        self.assertEqual(len(self.log_lines("done: ")), 2)               # the first visit's and this one
        self.assertEqual(self.marker_text(d), self.signature(d))
        self.assertEqual(self.log_lines("retry pending for "), [])
        self.clear_calls()
        self.poll()
        self.assertEqual(self.runs(), [])

    def test_a_recovery_that_also_runs_out_the_retries_exports_and_finishes(self):
        d = self.finished_with_retries(retryable=2)
        self.set_after_run(d, 3, 3, retryable=0, unreadable=1)          # one recovered, one given up
        self.poll()
        self.assertIn("export", self.step_names())
        self.assertEqual(len(self.log_lines("done: ")), 2)

    def test_a_new_folder_is_always_a_full_visit(self):
        d = self.folder("2026-10-01")
        self.set_state(d, 3, 3, retryable=2)
        self.set_after_run(d, 3, 3, retryable=2)                        # nothing will be recovered
        self.poll()
        self.assertIn("export", self.step_names())

    def test_a_changed_folder_is_a_full_visit_even_if_nothing_is_recovered(self):
        d = self.finished_with_retries()
        self.set_after_run(d, 4, 4, retryable=2)
        self.add_file(d, "late.ARW", 6 * 3600)                          # a new photo as well
        self.touch_dir(d, 1200)
        self.poll()
        self.assertIn("export", self.step_names())

    def test_an_unfinished_new_folder_is_retry_only_from_its_second_visit(self):
        d = self.folder("2026-10-01")
        self.set_state(d, 3, 3, retryable=2)
        self.poll()                                                     # first visit: everything
        self.assertIn("export", self.step_names())
        visited = (self.markers / "2026-10-01.visited")
        self.assertEqual(visited.read_text().strip(), self.signature(d))
        self.assertIsNone(self.marker_text(d))
        self.clear_calls()
        self.set_after_run(d, 3, 3, retryable=2)
        self.poll()                                                     # second: nothing recovered
        self.assertEqual(self.runs(), ["2026-10-01"])
        self.assertNotIn("export", self.step_names())
        self.assertEqual(self.log_lines("retry pending for ")[-1], f"retry pending for {d}: 2 photos (none recovered this time)")
        self.clear_calls()
        self.set_after_run(d, 3, 3, retryable=1)
        self.poll()                                                     # third: one recovered
        self.assertIn("export", self.step_names())
        self.clear_calls()
        self.set_after_run(d, 3, 3, retryable=0, unreadable=1)
        self.poll()                                                     # fourth: tries run out
        self.assertNotIn("export", self.step_names())
        self.assertEqual(self.marker_text(d), self.signature(d))
        self.assertFalse(visited.exists())                              # settled: nothing left to remember
        self.assertEqual(len(self.log_lines("done: ")), 1)

    def test_an_unfinished_folder_that_gains_a_photo_is_a_full_visit_again(self):
        d = self.folder("2026-10-01")
        self.set_state(d, 3, 3, retryable=2)
        self.poll()
        self.add_file(d, "late.ARW", 6 * 3600)
        self.touch_dir(d, 1200)
        self.clear_calls()
        self.set_after_run(d, 4, 4, retryable=2)
        self.poll()
        self.assertIn("export", self.step_names())

    def test_a_dir_mtime_only_change_with_retryable_rows_is_retry_only(self):
        d = self.finished_with_retries()
        self.add_file(d, ".DS_Store", 3000)
        self.touch_dir(d, 1200)
        self.set_after_run(d, 3, 3, retryable=2)
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])
        self.assertNotIn("export", self.step_names())

    def test_if_the_counts_cannot_be_read_it_is_a_full_visit(self):
        d = self.finished_with_retries()
        (self.stub / "folder-state.fail-folder").write_text("")
        self.poll()
        self.assertEqual(self.runs(), ["2026-10-01"])
        self.assertIn("export", self.step_names())                      # can't tell, so do everything
        self.assertEqual(self.log_lines("retry pending for "),
                         [f"retry pending for {d}: could not read the folder's state; will look again next poll"])

    def test_old_markers_with_equal_counts_and_retryable_rows_are_retry_only(self):
        # The first live poll: 2011-12-22 and the like have failed photos, all registered.
        old = self.folder("2026-02-02", n=4)
        newest = max(int(p.stat().st_mtime) for p in old.iterdir())
        self.set_marker(old, f"{newest}.0000000000")
        self.set_state(old, 4, 4, retryable=1)
        self.set_after_run(old, 4, 4, retryable=1)
        self.poll()
        self.assertEqual(self.runs(), ["2026-02-02"])
        self.assertNotIn("export", self.step_names())
        self.assertEqual(self.log_lines("retry pending for "), [f"retry pending for {old}: 1 photos (none recovered this time)"])

    def test_old_markers_whose_counts_differ_get_the_full_visit(self):
        # 2026-06-27: 21 photos on disk, 12 rows.
        d = self.folder("2026-06-27", n=21)
        newest = max(int(p.stat().st_mtime) for p in d.iterdir())
        self.set_marker(d, f"{newest}.0000000000")
        self.set_state(d, 21, 12, retryable=7)
        self.set_after_run(d, 21, 21, retryable=7)
        self.poll()
        self.assertIn("export", self.step_names())

    def test_a_dry_run_says_which_kind_of_visit_each_folder_gets(self):
        retry = self.folder("2026-02-02", n=4)
        newest = max(int(p.stat().st_mtime) for p in retry.iterdir())
        self.set_marker(retry, f"{newest}.0000000000")
        self.set_state(retry, 4, 4, retryable=1)
        full = self.folder("2026-06-27", n=4)
        self.set_marker(full, f"{max(int(p.stat().st_mtime) for p in full.iterdir())}.0000000000")
        self.set_state(full, 4, 3, retryable=1)
        new = self.folder("2026-10-09")
        r = self.poll(DRY_RUN=1)
        out = r.stdout
        self.assertIn(f"would process {retry} (old marker still matches; failed photos with tries left): "
                      "retry-only visit, steps and export only if a photo is recovered", out)
        self.assertRegex(out, rf"would process {full} \(old marker, 4 photos on disk but 3 in the DB.*\): full visit, steps and export")
        self.assertIn(f"would process {new} (no marker): full visit, steps and export", out)


class DryRun(WatcherCase):
    def test_dry_run_logs_what_it_would_do_and_writes_nothing(self):
        new = self.folder("2026-10-01")
        old = self.folder("2026-02-02")
        same = self.folder("2026-02-03")
        late = self.folder("2026-02-04")
        self.set_marker(old, str(max(int(p.stat().st_mtime) for p in old.iterdir())))
        self.set_marker(same, self.signature(same))
        self.set_marker(late, self.signature(late))
        self.add_file(late, "more.ARW", 6 * 3600)
        self.touch_dir(late, 3600)
        self.set_state(old, 3, 3)
        before = {p.name: p.read_text() for p in self.markers.iterdir()}
        r = self.poll(DRY_RUN=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.runs(), [])                               # no step ran
        self.assertFalse([c for c in self.calls() if not c.startswith("photo_cull.py folder-state")])
        self.assertEqual({p.name: p.read_text() for p in self.markers.iterdir()}, before)
        self.assertIsNone(self.marker_text(new))
        self.assertIn(f"DRY RUN: would process {new} (no marker)", r.stdout)
        self.assertIn(f"DRY RUN: would process {late} (signature changed)", r.stdout)
        self.assertIn(f"DRY RUN: would upgrade the old marker for {old}", r.stdout)
        self.assertNotIn(str(same), r.stdout)
        self.assertIn("DRY RUN: would process", self.log_text())       # also in the log
        self.assertEqual(self.log_lines("processing "), [])
        self.assertFalse((self.root / "mail.log").exists())
        self.assertFalse((self.stub / "mail.log").exists())

    def test_dry_run_does_not_create_the_markers_folder(self):
        self.folder("2026-10-01")
        self.poll(DRY_RUN=1)
        self.assertFalse(self.markers.exists())


class Settings(WatcherCase):
    def test_the_mount_guards_still_stop_a_poll(self):
        self.folder("2026-10-01")
        (self.root / "inbox").mkdir()
        r = self.poll(CHECK_MOUNT=1)                                    # a plain folder is no mount
        self.assertEqual(r.returncode, 1)
        self.assertIn("ABORT: ", self.log_text())
        self.assertEqual(self.runs(), [])

    def test_live_paths_only_appear_as_defaults(self):
        text = SCRIPT.read_text()
        for live in ("/home/danny/photo-culling", "/mnt/passport/Pictures", "/mnt/Passport_AICullInbox",
                     "//mycloud/Passport/AICullInbox"):
            for ln in text.splitlines():
                if live in ln and not ln.lstrip().startswith("#"):
                    self.assertRegex(ln, r"^[A-Z_]+=\$\{[A-Z_]+:-", f"{live} outside a default: {ln}")


if __name__ == "__main__":
    unittest.main()
