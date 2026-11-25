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
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
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
    [ -e "$STUB_DIR/folder-state.fail" ] && exit 1
    retry_only=0; folders=()
    while [ $# -gt 0 ]; do
      case "$1" in --db) shift ;; --retryable-only) retry_only=1 ;; *) folders+=("$1") ;; esac
      shift
    done
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
    ;;
esac
[ -f "$STUB_DIR/rc.$cmd" ] && exit "$(cat "$STUB_DIR/rc.$cmd")"
exit 0
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

    def add_file(self, d, name, age):
        p = d / name
        p.write_bytes(b"x" * 10)
        t = self.now - age
        os.utime(p, (t, t))
        return p

    def touch_dir(self, d, age):
        t = self.now - age
        os.utime(d, (t, t))

    def signature(self, d):
        files = [p for p in d.rglob("*") if p.is_file()]
        return "v2 %d %d %d" % (int(d.stat().st_mtime), max(int(p.stat().st_mtime) for p in files), len(files))

    def set_state(self, d, disk, rows, pending=0, retryable=0, unreadable=0):
        self.states[str(d)] = (disk, rows, pending, retryable, unreadable)
        lines = ["\t".join([f, *map(str, v)]) for f, v in self.states.items()]
        (self.stub / "folder-state.tsv").write_text("\n".join(lines) + "\n")

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
        self.assertEqual(names, ["folder-state", "run", "embed", "embed-images", "geotag", "shotinfo",
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
        self.assertTrue(self.marker_text(d).endswith(" 4"))
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
        return [c for c in self.calls() if c.startswith("photo_cull.py folder-state") and "--retryable-only" not in c]

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
