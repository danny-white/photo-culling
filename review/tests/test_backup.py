"""ops/backup.sh (the nightly copy to the NAS and push to GitHub) and the pipeline-health alerts
that read its status file. Everything runs in temp directories: the script gets a temp PROJ with
small WAL databases, a temp DEST (CHECK_MOUNT=0), and a temp git repo whose origin is a temp bare
repo. No NAS, no GitHub, no systemd. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import fcntl
import json
import os
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest
from contextlib import closing
from datetime import date, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
sys.path.insert(0, str(ROOT))
SCRIPT = ROOT / "ops" / "backup.sh"
HAVE_TOOLS = all(subprocess.run(["which", t], capture_output=True).returncode == 0
                 for t in ("sqlite3", "git", "tar", "flock", "timeout", "mountpoint"))

GIT_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}


def git(repo, *args, check=True):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=check,
                          env={**os.environ, **GIT_ENV})


def commit(repo: Path, name: str, text: str) -> str:
    (repo / name).write_text(text)
    git(repo, "add", name)
    git(repo, "commit", "-q", "-m", f"add {name}")
    return git(repo, "rev-parse", "HEAD").stdout.strip()


def make_wal_db(path: Path, rows: list[str]) -> sqlite3.Connection:
    """A WAL database whose newest rows are only in the -wal file: the connection stays open, so
    SQLite has not checkpointed them into the main file. A cp of the .db alone would miss them."""
    con = sqlite3.connect(path)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("CREATE TABLE t (v TEXT)")
    con.commit()
    con.executemany("INSERT INTO t VALUES (?)", [(r,) for r in rows])
    con.commit()
    return con


def rows(path: Path) -> list[str]:
    with closing(sqlite3.connect(f"file:{path}?mode=ro", uri=True)) as con:
        return [r[0] for r in con.execute("SELECT v FROM t ORDER BY rowid")]


@unittest.skipUnless(HAVE_TOOLS, "needs sqlite3, git, tar, flock, timeout and mountpoint")
class BackupScript(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        t = Path(self.tmpdir.name)
        self.proj, self.dest, self.units, self.remote = t / "proj", t / "dest", t / "units", t / "remote.git"
        self.out = self.proj / "trial_out"
        self.status_file = self.out / "backup-status.json"
        self.log_file = self.out / "backup.log"
        for d in (self.out / "mobile", self.out / "ingest_markers", self.proj / "ops", self.units,
                  self.proj / "eval" / "labels", self.proj / "eval" / "grades", self.proj / "eval" / "runs",
                  self.proj / "eval" / "audits", self.proj / "eval" / "images"):
            d.mkdir(parents=True)
        self.anno = make_wal_db(self.out / "annotations.db", ["decision-1", "decision-2"])
        self.trial = make_wal_db(self.out / "trial.db", ["photo-1"])
        (self.out / "mobile" / "practice.json").write_text('{"done": ["p1"]}')
        (self.out / "mobile" / "pano.json").write_text("{}")
        (self.out / "ingest_markers" / "2026-10-01.done").write_text("1234.5")
        (self.out / "known-unreadable.txt").write_text("/mnt/passport/x.CR3\n")
        (self.proj / "eval" / "set.json").write_text("[1]")
        (self.proj / "eval" / "report.json").write_text("{}")
        (self.proj / "eval" / "labels" / "a.json").write_text('{"label": 1}')
        (self.proj / "eval" / "grades" / "g.json").write_text("{}")
        (self.proj / "eval" / "runs" / "r.json").write_text("{}")
        (self.proj / "eval" / "audits" / "u.json").write_text("{}")
        (self.proj / "eval" / "images" / "copy-of-a-library-photo.jpg").write_text("not backed up")
        (self.proj / "ops" / "photo-review.service").write_text("[Service]\nExecStart=/bin/true\n")
        (self.proj / "ops" / "culling-bay-backup.timer").write_text("[Timer]\n")
        (self.units / "loose-target.service").write_text("[Service]\nExecStart=/bin/false\n")
        (self.units / "photo-review.service").symlink_to(self.units / "loose-target.service")
        (self.units / "unrelated.service").write_text("[Service]\n")
        # a git repo whose origin is a bare repo; the .gitignore keeps trial_out out, as in the project
        git(self.proj, "init", "-q", "-b", "main")
        (self.proj / ".gitignore").write_text("trial_out/\n")
        git(self.proj, "add", ".gitignore")
        git(self.proj, "commit", "-q", "-m", "first")
        commit(self.proj, "app.py", "print('hello')\n")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.remote)], check=True, env={**os.environ, **GIT_ENV})
        git(self.proj, "remote", "add", "origin", str(self.remote))
        self.day = date.today().isoformat()

    def tearDown(self):
        self.anno.close()
        self.trial.close()
        self.tmpdir.cleanup()

    def run_backup(self, **env):
        base = {**os.environ, **GIT_ENV, "PROJ": str(self.proj), "DEST": str(self.dest),
                "CHECK_MOUNT": "0", "PUSH": "0", "UNIT_DIR": str(self.units), "MOUNT_WAIT": "0",
                "HOME": self.tmpdir.name}
        base.update({k: str(v) for k, v in env.items()})
        return subprocess.run([str(SCRIPT)], capture_output=True, text=True, env=base, timeout=120)

    def status(self) -> dict:
        return json.loads(self.status_file.read_text())

    def remote_tip(self, branch="main"):
        r = subprocess.run(["git", "--git-dir", str(self.remote), "rev-parse", "-q", "--verify", f"refs/heads/{branch}"],
                           capture_output=True, text=True, env={**os.environ, **GIT_ENV})
        return r.stdout.strip() or None

    # ------------------------------------------------------------------ the copy
    def test_files_land_and_restore(self):
        self.assertTrue((self.out / "annotations.db-wal").stat().st_size > 0, "the test needs rows that live only in the WAL")
        r = self.run_backup()
        self.assertEqual(r.returncode, 0, r.stderr)
        folder = self.dest / self.day
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["annotations.db", "state.tar.gz", "trial.db"])
        # restore: the copies open and hold the rows, including the ones that were only in the WAL
        self.assertEqual(rows(folder / "annotations.db"), ["decision-1", "decision-2"])
        self.assertEqual(rows(folder / "trial.db"), ["photo-1"])
        with tarfile.open(folder / "state.tar.gz") as tar:
            names = set(tar.getnames())
            for want in ("trial_out/mobile/practice.json", "trial_out/mobile/pano.json",
                         "trial_out/ingest_markers/2026-10-01.done", "trial_out/known-unreadable.txt",
                         "eval/set.json", "eval/report.json", "eval/labels/a.json", "eval/grades/g.json",
                         "eval/runs/r.json", "eval/audits/u.json",
                         "ops/photo-review.service", "ops/culling-bay-backup.timer",
                         "systemd-user/photo-review.service"):
                self.assertIn(want, names)
            self.assertNotIn("eval/images/copy-of-a-library-photo.jpg", names)
            self.assertNotIn("systemd-user/unrelated.service", names)
            # the live unit is stored as what it resolves to, not as a dangling symlink
            self.assertEqual(tar.extractfile("systemd-user/photo-review.service").read().decode(), "[Service]\nExecStart=/bin/false\n")
            self.assertEqual(tar.extractfile("trial_out/mobile/practice.json").read().decode(), '{"done": ["p1"]}')
        st = self.status()
        self.assertTrue(st["ok"])
        self.assertEqual((st["folder"], st["dest"]), (self.day, str(self.dest)))
        self.assertEqual([f["name"] for f in st["files"]], ["annotations.db", "trial.db", "state.tar.gz"])
        for f in st["files"]:
            self.assertEqual(f["bytes"], (folder / f["name"]).stat().st_size)
        self.assertEqual(st["last_ok_at"], st["at"])
        self.assertEqual(st["push"]["skipped"], True)
        self.assertNotIn("error", st)
        self.assertEqual(len(self.log_file.read_text().strip().splitlines()), 2)    # "in place" + the summary line
        self.assertIn(f"ok folder={self.day}", self.log_file.read_text())
        # no scratch left on either side
        self.assertFalse((self.out / ".backup-staging").exists())
        self.assertEqual([p.name for p in self.dest.iterdir()], [self.day])
        self.assertFalse(list(self.status_file.parent.glob("backup-status.json.tmp*")))

    def test_state_that_does_not_exist_yet_is_skipped(self):
        (self.out / "known-unreadable.txt").unlink()
        subprocess.run(["rm", "-rf", str(self.proj / "eval"), str(self.out / "mobile"), str(self.out / "ingest_markers")], check=True)
        r = self.run_backup()
        self.assertEqual(r.returncode, 0, r.stderr)
        with tarfile.open(self.dest / self.day / "state.tar.gz") as tar:
            names = tar.getnames()
        self.assertIn("ops/photo-review.service", names)
        self.assertFalse([n for n in names if n.startswith(("eval", "trial_out"))], names)

    def test_a_database_copy_that_fails_quick_check_fails_the_run(self):
        # Garbage in one page: SQLite's backup copies pages as they are, so only quick_check sees it.
        self.anno.close()
        for ext in ("-wal", "-shm"):
            (self.out / f"annotations.db{ext}").unlink(missing_ok=True)
        path = self.out / "annotations.db"
        path.unlink()
        with closing(sqlite3.connect(path)) as con:
            con.execute("CREATE TABLE t (v TEXT)")
            con.execute("CREATE INDEX ti ON t (v)")
            con.executemany("INSERT INTO t VALUES (?)", [(f"row {i}" * 20,) for i in range(2000)])
            con.commit()
        with open(path, "r+b") as f:
            f.seek(4096 * 3)
            f.write(b"\xff" * 4096)
        self.anno = sqlite3.connect(":memory:")                  # tearDown closes it
        r = self.run_backup()
        self.assertNotEqual(r.returncode, 0)
        st = self.status()
        self.assertFalse(st["ok"])
        self.assertIn("annotations.db", st["error"])
        self.assertIn("quick_check", st["error"])
        self.assertEqual(list(self.dest.glob("*")), [])           # nothing was published
        self.assertFalse((self.out / ".backup-staging").exists())

    def test_a_missing_database_fails_and_keeps_the_last_good_time(self):
        self.assertEqual(self.run_backup().returncode, 0)
        good = self.status()["last_ok_at"]
        self.assertTrue(good)
        (self.out / "trial.db").unlink()
        r = self.run_backup()
        self.assertNotEqual(r.returncode, 0)
        st = self.status()
        self.assertFalse(st["ok"])
        self.assertIn("trial.db is missing", st["error"])
        self.assertEqual(st["last_ok_at"], good)                  # the health check needs it to say how old the last good copy is
        self.assertIsNone(st["folder"])
        self.assertIn("FAILED", self.log_file.read_text())

    def test_a_second_run_the_same_day_replaces_the_folder(self):
        self.assertEqual(self.run_backup().returncode, 0)
        self.anno.execute("INSERT INTO t VALUES ('decision-3')")
        self.anno.commit()
        r = self.run_backup()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(rows(self.dest / self.day / "annotations.db"), ["decision-1", "decision-2", "decision-3"])
        self.assertEqual([p.name for p in self.dest.iterdir()], [self.day])     # no .incoming-/.old- left behind

    def test_prune_keeps_the_newest_dated_folders_and_leaves_other_names_alone(self):
        self.dest.mkdir()
        for i in range(1, 11):
            (self.dest / f"2020-01-{i:02d}").mkdir()
        for stray in ("notes", "2020-1-1", "2020-01-01.bak", "backup-2020-01-02"):
            (self.dest / stray).mkdir()
        (self.dest / "readme.txt").write_text("hi")
        old, fresh = self.dest / ".incoming-dead", self.dest / ".incoming-running"
        old.mkdir(), fresh.mkdir()
        three_days = (datetime.now() - timedelta(days=3)).timestamp()
        os.utime(old, (three_days, three_days))
        r = self.run_backup(KEEP=3)
        self.assertEqual(r.returncode, 0, r.stderr)
        names = sorted(p.name for p in self.dest.iterdir())
        dated = [n for n in names if len(n) == 10 and n[:4].isdigit() and n[4] == n[7] == "-"]
        self.assertEqual(dated, ["2020-01-09", "2020-01-10", self.day])
        for kept in ("notes", "2020-1-1", "2020-01-01.bak", "backup-2020-01-02", "readme.txt", ".incoming-running"):
            self.assertIn(kept, names)
        self.assertNotIn(".incoming-dead", names)          # a day old: cleaned up by this run

    def test_keep_must_be_a_positive_number(self):
        for bad in ("0", "-1", "two"):
            r = self.run_backup(KEEP=bad)
            self.assertNotEqual(r.returncode, 0, bad)
            self.assertIn("KEEP", self.status()["error"])
        self.assertFalse(self.dest.exists())

    def test_a_second_copy_running_at_once_does_nothing(self):
        with open(self.out / ".backup.lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            r = self.run_backup()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.status_file.exists())
        self.assertIn("already running", self.log_file.read_text())

    # ------------------------------------------------------------------ the mount guard
    def test_mount_guard_stops_a_run_when_the_share_is_not_mounted(self):
        not_a_mount = Path(self.tmpdir.name) / "nas"
        not_a_mount.mkdir()
        r = self.run_backup(CHECK_MOUNT=1, DEST_MOUNT=not_a_mount, DEST=not_a_mount / "backups")
        self.assertNotEqual(r.returncode, 0)
        st = self.status()
        self.assertFalse(st["ok"])
        self.assertIn("the NAS Drive share is not mounted", st["error"])
        self.assertEqual(list(not_a_mount.iterdir()), [])         # nothing was written into the empty directory
        self.assertFalse((self.out / ".backup-staging").exists())

    def test_mount_guard_checks_where_the_mount_comes_from(self):
        # "/" is a mount point on any machine; /proc/mounts does not list //nowhere/Drive on it
        r = self.run_backup(CHECK_MOUNT=1, DEST_MOUNT="/", DEST_SOURCE="//nowhere/Drive")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not from //nowhere/Drive", self.status()["error"])
        self.assertFalse(self.dest.exists())

    def test_mount_guard_lets_a_run_through_when_the_share_is_there(self):
        mounts = Path(self.tmpdir.name) / "mounts"
        mounts.write_text("//nowhere/Drive / cifs rw,relatime 0 0\n")
        r = self.run_backup(CHECK_MOUNT=1, DEST_MOUNT="/", DEST_SOURCE="//nowhere/Drive", MOUNTS_FILE=mounts)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.dest / self.day / "annotations.db").exists())

    def test_mount_guard_refuses_a_destination_off_the_mount(self):
        mounts = Path(self.tmpdir.name) / "mounts"
        mounts.write_text("//nowhere/Drive /proc cifs rw 0 0\n")
        r = self.run_backup(CHECK_MOUNT=1, DEST_MOUNT="/proc", DEST_SOURCE="//nowhere/Drive", MOUNTS_FILE=mounts)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("is not on the mount", self.status()["error"])
        self.assertFalse(self.dest.exists())

    # ------------------------------------------------------------------ the push
    def test_push_reaches_the_remote_and_only_that_branch(self):
        git(self.proj, "branch", "other")
        git(self.proj, "checkout", "-q", "other")
        commit(self.proj, "other.py", "x = 1\n")
        git(self.proj, "checkout", "-q", "main")
        tip = git(self.proj, "rev-parse", "main").stdout.strip()
        r = self.run_backup(PUSH=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.remote_tip(), tip)
        self.assertIsNone(self.remote_tip("other"))
        push = self.status()["push"]
        self.assertEqual((push["ok"], push["skipped"], push["ahead_before"]), (True, False, 2))
        self.assertIn("pushed 2 commit", push["message"])
        # nothing new: nothing to push, and that is fine
        r = self.run_backup(PUSH=1)
        self.assertEqual(r.returncode, 0)
        push = self.status()["push"]
        self.assertEqual((push["ok"], push["ahead_before"], push["message"]), (True, 0, "nothing to push"))
        # plain words that merely look like the scan's patterns do not block a push
        for text in ("no password needed here\n", "if parts.password == nil { }\n", "the task-description-for-the-whole-pipeline\n"):
            commit(self.proj, "notes.txt", text)
            self.assertEqual(self.run_backup(PUSH=1).returncode, 0)
            self.assertTrue(self.status()["push"]["ok"], text)
            self.assertEqual(self.remote_tip(), git(self.proj, "rev-parse", "main").stdout.strip())

    def test_a_secret_in_a_commit_blocks_the_push(self):
        self.run_backup(PUSH=1)                                    # the remote has main already
        before = self.remote_tip()
        self.assertEqual(before, git(self.proj, "rev-parse", "main").stdout.strip())
        # Built here, not written out, so this file does not trip the scan itself.
        secrets = {
            "a private key": "-----BEGIN " + "RSA PRIVATE KEY-----\nMIIE\n",
            "a GitHub token": "TOKEN = 'ghp_" + "a1B2c3D4" * 5 + "'\n",
            "a GitHub token (fine-grained)": "t = 'github_pat_" + "AbCd1234" * 4 + "'\n",
            "an sk- key": "OPENAI = 'sk-" + "Zy9x8W7v" * 3 + "'\n",
            "a Slack token": "slack: xoxb-" + "1234567890" + "-abcdef\n",
            "an AWS access key": "id = AKIA" + "ABCDEFGH12345678" + "\n",
            "a password": "DB_" + "PASSWORD" + " = hunter22\n",
            "a long quoted api_key": "api" + "_key = '" + "q" * 24 + "'\n",
        }
        for what, text in secrets.items():
            with self.subTest(what):
                name = "config.txt"
                commit(self.proj, name, "harmless\n")
                commit(self.proj, name, text)
                r = self.run_backup(PUSH=1)
                self.assertEqual(r.returncode, 0, "a blocked push does not fail the backup")
                st = self.status()
                self.assertTrue(st["ok"])
                self.assertFalse(st["push"]["ok"])
                self.assertFalse(st["push"]["skipped"])
                self.assertEqual(st["push"]["ahead_before"], 2)
                self.assertTrue(st["push"]["message"].startswith("push blocked: "), st["push"]["message"])
                self.assertIn(f"{name}: {what.split(' (')[0]}", st["push"]["message"])
                leaked = text.split("= ")[-1].strip(" '\n")
                for output in (self.status_file.read_text(), self.log_file.read_text(), r.stdout, r.stderr):
                    self.assertNotIn(leaked, output, "the secret must not be repeated anywhere")
                self.assertEqual(self.remote_tip(), before, "nothing went to the remote")
                git(self.proj, "reset", "-q", "--hard", before)

    def test_a_secret_removed_again_in_a_later_commit_still_blocks(self):
        self.run_backup(PUSH=1)
        before = self.remote_tip()
        commit(self.proj, "c.txt", "TOKEN = 'ghp_" + "a1B2c3D4" * 5 + "'\n")
        commit(self.proj, "c.txt", "TOKEN = ''\n")        # gone from the files, still in the history that would go public
        self.run_backup(PUSH=1)
        self.assertIn("push blocked", self.status()["push"]["message"])
        self.assertEqual(self.remote_tip(), before)

    def test_the_first_push_scans_the_whole_history(self):
        commit(self.proj, "old.txt", "TOKEN = 'ghp_" + "a1B2c3D4" * 5 + "'\n")
        commit(self.proj, "old.txt", "fine\n")
        self.assertIsNone(self.remote_tip())
        self.run_backup(PUSH=1)
        self.assertIn("push blocked: old.txt: a GitHub token", self.status()["push"]["message"])
        self.assertIsNone(self.remote_tip())

    def test_a_first_push_to_an_empty_remote_works(self):
        self.assertIsNone(self.remote_tip())
        self.run_backup(PUSH=1)
        push = self.status()["push"]
        self.assertEqual((push["ok"], push["ahead_before"]), (True, 2))
        self.assertEqual(self.remote_tip(), git(self.proj, "rev-parse", "main").stdout.strip())

    def test_a_diverged_remote_is_recorded_and_not_forced(self):
        self.run_backup(PUSH=1)
        other = Path(self.tmpdir.name) / "other-clone"
        subprocess.run(["git", "clone", "-q", str(self.remote), str(other)], check=True, env={**os.environ, **GIT_ENV})
        theirs = commit(other, "theirs.txt", "elsewhere\n")
        git(other, "push", "-q", "origin", "main")
        commit(self.proj, "mine.txt", "here\n")
        r = self.run_backup(PUSH=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        st = self.status()
        self.assertTrue(st["ok"])
        self.assertFalse(st["push"]["ok"])
        self.assertIn("diverged", st["push"]["message"])
        self.assertEqual(self.remote_tip(), theirs)

    def test_a_remote_that_cannot_be_reached_is_recorded(self):
        r = self.run_backup(PUSH=1, REMOTE=Path(self.tmpdir.name) / "no-such-repo.git")
        self.assertEqual(r.returncode, 0, r.stderr)
        st = self.status()
        self.assertTrue(st["ok"])
        self.assertFalse(st["push"]["ok"])
        self.assertIn("could not reach", st["push"]["message"])

    def test_pushing_can_be_turned_off(self):
        self.run_backup(PUSH=0)
        push = self.status()["push"]
        self.assertEqual((push["ok"], push["skipped"]), (None, True))
        self.assertIsNone(self.remote_tip())


# ---------------------------------------------------------------------- the health alerts
class BackupHealth(unittest.TestCase):
    """/m/api/pipeline-health reads the status file ops/backup.sh leaves. A tiny index database
    stands in for trial.db; the other alerts (Ollama, search model) are not what these look at."""

    @classmethod
    def setUpClass(cls):
        from flask import Flask
        import mobile
        import photo_cull as pc
        cls.tmp = tempfile.TemporaryDirectory()
        tmp = Path(cls.tmp.name)
        trial = tmp / "trial.db"
        with closing(sqlite3.connect(trial)) as con:
            con.executescript("""
                CREATE TABLE images (path TEXT, filename TEXT, status TEXT, processed_at TEXT, shot_checked TEXT, gps_checked TEXT,
                                     size INTEGER, attempts INTEGER, error_class TEXT, error_msg TEXT);
                CREATE TABLE embeddings (path TEXT, embed_version TEXT);
                CREATE TABLE day_summaries (folder TEXT);""")

        def db_ro():
            con = sqlite3.connect(f"file:{trial}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            return con

        def anno():
            con = sqlite3.connect(tmp / "annotations.db")
            con.row_factory = sqlite3.Row
            return con

        (tmp / "static").mkdir()
        cls.status_file = tmp / "backup-status.json"
        app = Flask(__name__)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=db_ro, anno=anno, pc=pc, cache_dir=tmp, static_dir=tmp / "static", state_dir=tmp / "state",
            inbox=tmp / "inbox", check_mount=False, ingest_log=tmp / "ingest.log",
            ollama_url="http://127.0.0.1:9", backup_status=cls.status_file,
            known_unreadable=tmp / "known-unreadable.txt"))
        cls.client = app.test_client()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.status_file.unlink(missing_ok=True)

    @staticmethod
    def ago(**kw) -> str:
        return (datetime.now().astimezone() - timedelta(**kw)).isoformat(timespec="seconds")

    def write(self, **fields):
        at = fields.pop("at", self.ago(hours=3))
        doc = {"at": at, "ok": True, "last_ok_at": at, "dest": "/mnt/nas_drive/backups/culling-bay",
               "folder": "2026-11-24", "files": [], "push": {"ok": True, "skipped": False, "ahead_before": 0,
                                                              "message": "nothing to push"}}
        doc.update(fields)
        self.status_file.write_text(json.dumps(doc))

    def health(self) -> tuple[dict, list[dict]]:
        d = self.client.get("/m/api/pipeline-health").get_json()
        mine = [a for a in d["alerts"] if a["title"].startswith(("No backup", "Backup is", "Last backup", "GitHub push", "Backup status"))]
        return d, mine

    def test_no_status_file_warns(self):
        d, alerts = self.health()
        self.assertEqual([(a["level"], a["title"]) for a in alerts], [("warn", "No backup yet")])
        self.assertTrue(alerts[0]["fix"])
        self.assertEqual(d["backup"], {"at": None, "ok": None, "last_ok_at": None, "folder": None, "push_ok": None})

    def test_a_fresh_good_backup_raises_nothing(self):
        self.write()
        d, alerts = self.health()
        self.assertEqual(alerts, [])
        self.assertEqual((d["backup"]["ok"], d["backup"]["folder"], d["backup"]["push_ok"]), (True, "2026-11-24", True))
        self.assertIsNotNone(d["backup"]["last_ok_at"])
        self.assertIsNotNone(d["backup"]["at"])

    def test_a_backup_one_day_old_is_fine_two_warns_four_is_bad(self):
        for days, want in ((1, None), (2, ("warn", "Backup is 2 days old")), (3, ("warn", "Backup is 3 days old")),
                           (4, ("bad", "Backup is 4 days old")), (9, ("bad", "Backup is 9 days old"))):
            with self.subTest(days=days):
                self.write(at=self.ago(days=days, hours=1))
                _, alerts = self.health()
                self.assertEqual([(a["level"], a["title"]) for a in alerts], [want] if want else [])
                for a in alerts:
                    self.assertTrue(a["fix"] and a["detail"])

    def test_a_failed_run_is_bad_and_says_why(self):
        self.write(at=self.ago(hours=2), ok=False, last_ok_at=self.ago(hours=26), folder=None,
                   error="the NAS Drive share is not mounted (/mnt/nas_drive)")
        d, alerts = self.health()
        self.assertEqual([(a["level"], a["title"]) for a in alerts],
                         [("bad", "Last backup failed: the NAS Drive share is not mounted (/mnt/nas_drive)")])
        self.assertEqual(d["status"], "bad")
        self.assertEqual(d["backup"]["ok"], False)
        self.assertIn("last good backup was on", alerts[0]["detail"])

    def test_a_failed_run_after_old_good_backups_raises_both(self):
        self.write(at=self.ago(hours=2), ok=False, last_ok_at=self.ago(days=3), error="trial.db is missing")
        _, alerts = self.health()
        self.assertEqual([a["title"] for a in alerts], ["Last backup failed: trial.db is missing", "Backup is 3 days old"])

    def test_a_failure_before_any_good_backup(self):
        self.write(ok=False, last_ok_at=None, folder=None, error="annotations.db is missing")
        _, alerts = self.health()
        self.assertEqual([a["title"] for a in alerts], ["Last backup failed: annotations.db is missing"])
        self.assertIn("No backup has worked yet", alerts[0]["detail"])

    def test_a_blocked_push_warns_with_the_reason(self):
        self.write(push={"ok": False, "skipped": False, "ahead_before": 2,
                         "message": "push blocked: config.py: a GitHub token"})
        d, alerts = self.health()
        self.assertEqual([(a["level"], a["title"]) for a in alerts],
                         [("warn", "GitHub push didn't go through: push blocked: config.py: a GitHub token")])
        self.assertEqual(d["backup"]["push_ok"], False)
        self.assertTrue(alerts[0]["fix"])

    def test_a_rejected_push_warns(self):
        self.write(push={"ok": False, "skipped": False, "ahead_before": 1, "message": "push rejected: Authentication failed"})
        _, alerts = self.health()
        self.assertEqual([a["title"] for a in alerts], ["GitHub push didn't go through: push rejected: Authentication failed"])

    def test_a_push_that_was_turned_off_is_not_an_alert(self):
        self.write(push={"ok": None, "skipped": True, "ahead_before": None, "message": "pushing is turned off (PUSH=0)"})
        _, alerts = self.health()
        self.assertEqual(alerts, [])

    def test_an_unreadable_status_file_warns_instead_of_breaking_the_page(self):
        self.status_file.write_text("{ not json")
        r = self.client.get("/m/api/pipeline-health")
        self.assertEqual(r.status_code, 200)
        self.assertIn("Backup status unreadable", [a["title"] for a in r.get_json()["alerts"]])

    def test_the_status_the_script_writes_is_what_the_health_check_reads(self):
        """backup.sh's own JSON (not a hand-made one) goes through the alert code."""
        if not HAVE_TOOLS:
            self.skipTest("needs sqlite3, git, tar, flock, timeout and mountpoint")
        with tempfile.TemporaryDirectory() as td:
            proj = Path(td) / "proj"
            (proj / "trial_out").mkdir(parents=True)
            for n in ("annotations.db", "trial.db"):
                make_wal_db(proj / "trial_out" / n, ["x"]).close()
            (proj / "trial_out" / "trial.db").unlink()          # a failing run, with a message that needs escaping
            env = {**os.environ, "PROJ": str(proj), "DEST": str(Path(td) / "d"), "CHECK_MOUNT": "0", "PUSH": "0",
                   "UNIT_DIR": td, "STATUS": str(self.status_file), "HOME": td}
            r = subprocess.run([str(SCRIPT)], env=env, capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
        d, alerts = self.health()
        self.assertEqual(d["backup"]["ok"], False)
        self.assertEqual([a["title"] for a in alerts][0], "Last backup failed: trial.db is missing (%s/trial_out/trial.db)" % proj)


if __name__ == "__main__":
    unittest.main()
