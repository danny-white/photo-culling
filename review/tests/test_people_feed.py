"""people.tsv: who is in which photo, written to the inbox for the Lightroom plug-in (PeopleFeed in
review/people.py, phase E of review/PEOPLE.md). A made-up library in a temp DB (review/tests/people_world.py);
the names are invented and the inbox is a temp directory. The plug-in's half is in lightroom-plugin/tests and
review/tests/test_round_trip.py. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "review"))
import people  # noqa: E402
from review.tests.people_world import World  # noqa: E402

H = {"X-Culling-Bay": "1"}


class FakeTimer:
    """threading.Timer that runs only when the test says: made lists every timer in order."""
    made: list = []

    def __init__(self, interval, function):
        self.interval, self.function, self.cancelled, self.started = interval, function, False, False
        self.daemon, self.name = False, ""
        FakeTimer.made.append(self)

    def start(self):
        self.started = True

    def cancel(self):
        self.cancelled = True

    def fire(self):
        self.function()


class FeedCase(unittest.TestCase):
    def setUp(self):
        self.w = World()
        self.addCleanup(self.w.close)
        self.inbox = self.w.dir / "inbox"
        self.inbox.mkdir()
        self.target = self.inbox / "people.tsv"

    # ---------------------------------------------------------------- helpers
    def key(self, person):
        return min(self.w.ids(person))

    def build(self, problem=None, debounce_s=0.05):
        """The index over three unnamed groups (alex, sam, robin) and a feed on it."""
        w = self.w
        w.write_groups({self.key(p): w.ids(p) for p in ("alex", "sam", "robin")})
        self.ix = w.index()
        self.feed = self.make_feed(self.ix, problem, debounce_s)
        return self.ix

    def make_feed(self, ix, problem=None, debounce_s=0.05):
        feed = people.PeopleFeed(ix, self.inbox, problem=problem, debounce_s=debounce_s)
        self.addCleanup(feed.close)
        return feed

    def read(self):
        """(the first line, {(folder, file): names field}) of people.tsv."""
        lines = self.target.read_text(encoding="utf-8").splitlines()
        rows = {}
        for line in lines[1:]:
            folder, fname, names = line.split("\t")           # exactly three fields, whatever the names hold
            rows[(folder, fname)] = names
        return lines[0], rows

    def keys_of(self, *persons):
        """(shoot folder, file) of every photo the world gave a face of one of these people."""
        paths = {f["photo"]: f["path"] for f in self.w.faces}
        return {(Path(paths[p]).parent.name, Path(paths[p]).name) for who in persons for p in self.w.photos(who)}

    def remembered(self):
        con = self.w.anno()
        try:
            return {r[0] for r in con.execute("SELECT path FROM people_lr")}
        finally:
            con.close()


class Content(FeedCase):
    def test_a_header_then_one_row_per_named_photo_by_folder_and_file(self):
        ix = self.build()
        ix.create("Alex", group=self.key("alex"))
        ix.create("Sam", group=self.key("sam"))
        self.assertTrue(self.feed.flush())
        header, rows = self.read()
        self.assertEqual(header, "#people v1")
        self.assertTrue(header.startswith("#"))                       # the plug-in's parsers skip these lines
        self.assertEqual(set(rows), self.keys_of("alex", "sam"))      # robin is nobody's yet: no rows
        self.assertEqual({v for k, v in rows.items() if k in self.keys_of("alex")}, {"Alex"})
        self.assertEqual({v for k, v in rows.items() if k in self.keys_of("sam")}, {"Sam"})
        body = self.target.read_text().splitlines()[1:]
        self.assertEqual(body, sorted(body))                          # in folder and file order
        self.assertEqual(body[0].split("\t")[0], "2026-01-01")        # the shoot folder's own name, as in pending.tsv
        self.assertRegex(body[0].split("\t")[1], r"^IMG_\d{5}\.ARW$")

    def test_a_photo_of_two_people_lists_both_names_sorted(self):
        photo, _ = self.w.together("2026/2026-01-01", ["sam", "alex"])
        ix = self.build()
        ix.create("Sam", group=self.key("sam"))
        ix.create("Alex", group=self.key("alex"))                     # named second, listed first
        self.feed.flush()
        path = next(f["path"] for f in self.w.faces if f["photo"] == photo)
        _, rows = self.read()
        self.assertEqual(rows[(Path(path).parent.name, Path(path).name)], "Alex|Sam")

    def test_names_sort_without_regard_to_case(self):
        photo, _ = self.w.together("2026/2026-01-01", ["sam", "alex"])
        ix = self.build()
        ix.create("sam", group=self.key("sam"))
        ix.create("Alex", group=self.key("alex"))
        self.feed.flush()
        path = next(f["path"] for f in self.w.faces if f["photo"] == photo)
        self.assertEqual(self.read()[1][(Path(path).parent.name, Path(path).name)], "Alex|sam")

    def test_faces_the_server_filed_count_and_suggestions_do_not(self):
        w = self.w
        ix = self.build()
        pid, _ = ix.create("Alex", faces=w.ids("alex")[:3])           # three confirmed, the other 15 filed by the group rule
        st = ix.state()
        self.assertEqual(int((st.res.how[st.faces[pid]] == 2).sum()), 15)
        mine = w.add_lookalikes("alex", 4, "2026/2026-01-06")         # about 0.45 alike: "Is this Alex?"
        w.add_group(mine)
        st = ix.state()
        self.assertEqual(len(ix.suggestions_of(st, pid)["faces"]), 4)
        self.feed.flush()
        _, rows = self.read()
        self.assertEqual(set(rows), self.keys_of("alex"))             # 18 photos, none of the four suggested ones
        self.assertEqual(len(rows), 18)

    def test_pipes_tabs_and_line_breaks_in_a_name_are_replaced(self):
        ix = self.build()
        ix.create("Al|ex\tB\nC", group=self.key("alex"))
        self.feed.flush()
        _, rows = self.read()                                         # read() insists on three fields a line
        self.assertEqual(set(rows.values()), {"Al/ex B C"})
        self.assertEqual((people.lr_name("a|b\tc\r\nd"), people.lr_key("/x/y/2026-01-01/IMG_1.ARW")),
                         ("a/b c  d", ("2026-01-01", "IMG_1.ARW")))

    def test_no_people_is_a_file_with_only_the_header(self):
        self.build()
        self.assertTrue(self.feed.flush())
        self.assertEqual(self.target.read_text(), "#people v1\n")

    def test_the_text_is_the_same_for_the_same_state(self):
        ix = self.build()
        ix.create("Alex", group=self.key("alex"))
        st = ix.state()
        self.assertEqual(self.feed.text(st), self.feed.text(st))


class Removals(FeedCase):
    def test_a_deleted_person_leaves_empty_rows_so_the_keyword_can_come_off(self):
        ix = self.build()
        alex, _ = ix.create("Alex", group=self.key("alex"))
        ix.create("Sam", group=self.key("sam"))
        self.feed.flush()
        ix.delete(alex)
        self.feed.flush()
        _, rows = self.read()
        self.assertEqual(set(rows), self.keys_of("alex", "sam"))      # still a row for every Alex photo ...
        self.assertEqual({v for k, v in rows.items() if k in self.keys_of("alex")}, {""})       # ... with no name
        self.assertEqual({v for k, v in rows.items() if k in self.keys_of("sam")}, {"Sam"})
        self.assertIn("\t\n", self.target.read_text())                # the empty field is there, not a short row

    def test_taking_one_face_off_empties_that_photos_row_only(self):
        w = self.w
        ix = self.build()
        alex, _ = ix.create("Alex", group=self.key("alex"))
        self.feed.flush()
        face = w.ids("alex")[4]
        ix.act([face], "not", alex)
        self.feed.flush()
        _, rows = self.read()
        gone = next(f for f in w.faces if f["id"] == face)
        self.assertEqual(rows[(Path(gone["path"]).parent.name, Path(gone["path"]).name)], "")
        self.assertEqual(sum(1 for v in rows.values() if v == "Alex"), 17)

    def test_a_renamed_person_is_written_under_the_new_name(self):
        ix = self.build()
        alex, _ = ix.create("Alex", group=self.key("alex"))
        ix.update(alex, name="Alexandra")
        self.feed.flush()
        self.assertEqual(set(self.read()[1].values()), {"Alexandra"})

    def test_a_merge_moves_everything_to_the_name_that_is_left(self):
        ix = self.build()
        alex, _ = ix.create("Alex", group=self.key("alex"))
        sam, _ = ix.create("Sam", group=self.key("sam"))
        ix.merge(sam, alex)
        self.feed.flush()
        _, rows = self.read()
        self.assertEqual(set(rows.values()), {"Alex"})
        self.assertEqual(set(rows), self.keys_of("alex", "sam"))

    def test_the_photos_stay_remembered_after_a_restart(self):
        ix = self.build()
        alex, _ = ix.create("Alex", group=self.key("alex"))
        self.feed.flush()
        ix.delete(alex)
        again = self.make_feed(self.w.index())                        # a new server process: nothing in memory
        again.flush()
        self.assertEqual(set(self.read()[1].values()), {""})
        self.assertEqual(set(self.read()[1]), self.keys_of("alex"))
        self.assertEqual(len(self.remembered()), 18)

    def test_a_photo_named_and_unnamed_before_any_write_never_gets_a_row(self):
        ix = self.build()
        alex, _ = ix.create("Alex", group=self.key("alex"))
        ix.delete(alex)                                               # inside one debounce window: nothing was written
        self.feed.flush()
        self.assertEqual(self.read()[1], {})
        self.assertEqual(self.remembered(), set())


class Debounce(FeedCase):
    def test_touches_within_the_window_make_one_write_at_the_end(self):
        ix = self.build(debounce_s=10.0)
        ix.create("Alex", group=self.key("alex"))
        FakeTimer.made = []
        with mock.patch.object(people.threading, "Timer", FakeTimer):
            for _ in range(5):
                self.feed.touch()
        live = [t for t in FakeTimer.made if not t.cancelled]
        self.assertEqual((len(FakeTimer.made), len(live)), (5, 1))     # each touch cancels the one before
        self.assertEqual(live[0].interval, 10.0)
        self.assertTrue(live[0].started)
        self.assertEqual(self.feed.writes, 0)
        self.assertFalse(self.target.exists())
        live[0].fire()
        self.assertEqual(self.feed.writes, 1)
        self.assertEqual(set(self.read()[1]), self.keys_of("alex"))
        self.assertTrue(self.feed.wait(1))

    def test_label_writes_touch_it_and_only_the_last_timer_survives(self):
        ix = self.build(debounce_s=10.0)
        ix.state()                                                    # built: its first build is a touch of its own
        ix.on_change = self.feed.touch
        FakeTimer.made = []
        with mock.patch.object(people.threading, "Timer", FakeTimer):
            alex, _ = ix.create("Alex", group=self.key("alex"))
            ix.update(alex, name="Alexandra")
            ix.add(alex, faces=[self.w.ids("casey")[0]])
        self.assertEqual([t.cancelled for t in FakeTimer.made], [True, True, False])
        self.assertEqual(self.feed.writes, 0)
        FakeTimer.made[-1].fire()
        self.assertEqual(self.feed.writes, 1)
        self.assertEqual(set(self.read()[1].values()), {"Alexandra"})

    def test_a_real_timer_writes_on_its_own_thread(self):
        ix = self.build(debounce_s=0.05)
        ix.on_change = self.feed.touch
        alex, _ = ix.create("Alex", group=self.key("alex"))
        self.assertFalse(self.target.exists())                        # not in the caller's thread
        self.assertTrue(self.feed.wait(5))
        self.assertEqual(self.feed.writes, 1)
        self.assertEqual(set(self.read()[1]), self.keys_of("alex"))
        ix.delete(alex)
        self.assertTrue(self.feed.wait(5))
        self.assertEqual(self.feed.writes, 2)
        self.assertEqual(set(self.read()[1].values()), {""})

    def test_a_new_grouping_run_touches_it_and_one_that_changes_nothing_new_does_not(self):
        w = self.w
        ix = self.build()
        calls = []
        ix.on_change = lambda: calls.append(1)
        ix.state()
        self.assertEqual(len(calls), 1)                               # the first build
        ix.state()
        self.assertEqual(len(calls), 1)                               # same run: nothing rebuilt
        st = ix.state()
        w.write_groups({k: st.base.ids[v].tolist() for k, v in st.base.group_faces.items()})   # a new run
        ix.state()
        self.assertEqual(len(calls), 2)

    def test_faces_filed_after_a_new_grouping_run_reach_the_file(self):
        w = self.w
        ix = self.build()
        ix.on_change = self.feed.touch
        ix.create("Alex", group=self.key("alex"))
        self.assertTrue(self.feed.wait(5))
        face = w.add_face("alex", "2026/2026-01-02")                  # a new photo of Alex's, found by the backfill
        w.commit()
        st = ix.state()
        groups = {k: st.base.ids[v].tolist() for k, v in st.base.group_faces.items()}
        groups[self.key("alex")].append(face)
        w.write_groups(groups)                                        # the new grouping run
        self.assertEqual(len(self.read()[1]), 18)                     # not until the server looks again
        ix.state()
        self.assertTrue(self.feed.wait(5))
        _, rows = self.read()
        new = next(f for f in w.faces if f["id"] == face)
        self.assertEqual(rows[(Path(new["path"]).parent.name, Path(new["path"]).name)], "Alex")
        self.assertEqual(len(rows), 19)

    def test_a_listener_that_raises_does_not_undo_a_label_write(self):
        ix = self.build()
        ix.on_change = mock.Mock(side_effect=RuntimeError("boom"))
        with self.assertLogs("people", "WARNING"):
            pid, _ = ix.create("Alex", group=self.key("alex"))
        self.assertEqual(ix.state().people[pid]["name"], "Alex")

    def test_close_drops_a_waiting_write(self):
        ix = self.build(debounce_s=0.2)
        ix.create("Alex", group=self.key("alex"))
        self.feed.touch()
        self.feed.close()
        self.assertTrue(self.feed.wait(1))
        self.feed.touch()                                              # refused once closed
        self.assertTrue(self.feed.wait(1))
        self.assertFalse(self.target.exists())


class Writing(FeedCase):
    def test_the_file_is_swapped_in_whole_from_a_temp_file_beside_it(self):
        ix = self.build()
        ix.create("Alex", group=self.key("alex"))
        self.feed.flush()
        before = self.target.read_text()
        ix.create("Sam", group=self.key("sam"))
        real, seen = os.replace, {}

        def replace(src, dst):
            seen.update(src=Path(src), dst=Path(dst), old=self.target.read_text(), new=Path(src).read_text())
            return real(src, dst)
        with mock.patch.object(people.os, "replace", replace):
            self.feed.flush()
        self.assertEqual(seen["src"].parent, self.inbox)               # same directory: the rename can't cross a mount
        self.assertEqual(seen["dst"], self.target)
        self.assertEqual(seen["old"], before)                          # until the swap the reader sees the old file
        self.assertIn("Sam", seen["new"])                              # and the temp file already holds all of the new
        self.assertNotEqual(seen["new"], before)
        self.assertFalse(seen["src"].exists())
        self.assertEqual(self.target.read_text(), seen["new"])

    def test_a_failed_swap_leaves_the_old_file_and_no_temp_file(self):
        ix = self.build()
        ix.create("Alex", group=self.key("alex"))
        self.feed.flush()
        before = self.target.read_text()
        ix.create("Sam", group=self.key("sam"))
        with mock.patch.object(people.os, "replace", side_effect=OSError("share went away")):
            with self.assertRaises(OSError):
                self.feed.flush()
        self.assertEqual(self.target.read_text(), before)
        self.assertEqual([p.name for p in self.inbox.iterdir()], ["people.tsv"])
        self.assertEqual(self.feed.writes, 1)

    def test_a_write_that_fails_on_the_timer_thread_is_logged_and_the_next_touch_tries_again(self):
        ix = self.build()
        ix.create("Alex", group=self.key("alex"))
        with mock.patch.object(people.os, "replace", side_effect=OSError("share went away")):
            with self.assertLogs("people", "WARNING") as logs:
                self.feed.touch()
                self.assertTrue(self.feed.wait(5))
        self.assertIn("not written", logs.output[0])
        self.assertFalse(self.target.exists())
        self.feed.touch()
        self.assertTrue(self.feed.wait(5))
        self.assertTrue(self.target.exists())


class Unmounted(FeedCase):
    def test_nothing_is_written_while_the_inbox_is_not_mounted_and_it_is_logged(self):
        state = {"why": f"{self.inbox} is not mounted"}
        ix = self.build(problem=lambda: state["why"])
        ix.create("Alex", group=self.key("alex"))
        with self.assertLogs("people", "WARNING") as logs:
            self.assertFalse(self.feed.flush())
        self.assertIn("is not mounted", logs.output[0])
        self.assertFalse(self.target.exists())
        self.assertEqual([p.name for p in self.inbox.iterdir()], [])   # not even a temp file
        self.assertEqual(self.feed.writes, 0)

    def test_the_next_change_after_the_mount_is_back_writes_everything(self):
        state = {"why": "not mounted"}
        ix = self.build(problem=lambda: state["why"])
        ix.on_change = self.feed.touch
        alex, _ = ix.create("Alex", group=self.key("alex"))
        with self.assertLogs("people", "WARNING"):
            self.assertTrue(self.feed.wait(5))
        self.assertFalse(self.target.exists())
        state["why"] = None
        ix.create("Sam", group=self.key("sam"))                        # the next change
        self.assertTrue(self.feed.wait(5))
        _, rows = self.read()
        self.assertEqual(set(rows), self.keys_of("alex", "sam"))
        self.assertEqual({v for k, v in rows.items() if k in self.keys_of("alex")}, {"Alex"})

    def test_photos_named_while_it_was_away_are_still_remembered_for_their_removal_rows(self):
        state = {"why": "not mounted"}
        ix = self.build(problem=lambda: state["why"])
        alex, _ = ix.create("Alex", group=self.key("alex"))
        with self.assertLogs("people", "WARNING"):
            self.feed.flush()
        self.assertEqual(len(self.remembered()), 18)
        ix.delete(alex)                                                # taken off again before it was ever written
        state["why"] = None
        self.assertTrue(self.feed.flush())
        self.assertEqual(set(self.read()[1].values()), {""})           # ... so the plug-in is told, in case it did see a file


class Server(FeedCase):
    def named(self, c, name, person):
        r = c.post("/m/api/people", json={"name": name, "group": self.key(person)}, headers=H)
        self.assertEqual(r.status_code, 201, r.get_json())
        return r.get_json()["id"]

    def setUp(self):
        super().setUp()
        self.w.write_groups({self.key(p): self.w.ids(p) for p in ("alex", "sam", "robin")})

    def test_it_writes_once_at_start_what_the_labels_already_say(self):
        self.w.index().create("Alex", group=self.key("alex"))          # named in an earlier run of the server
        self.w.client(people_feed_s=0.05)
        feed = self.w.bp.people_feed
        self.addCleanup(feed.close)
        self.assertTrue(feed.wait(5))
        self.assertEqual(feed.writes, 1)
        self.assertEqual(set(self.read()[1]), self.keys_of("alex"))

    def test_naming_and_removing_through_the_routes_rewrites_it(self):
        c = self.w.client(people_feed_s=0.05)
        feed = self.w.bp.people_feed
        self.addCleanup(feed.close)
        self.assertTrue(feed.wait(5))                                  # the start-up write: no people yet
        self.assertEqual(self.read()[1], {})
        sam = self.named(c, "Sam", "sam")
        self.assertTrue(feed.wait(5))
        self.assertEqual(set(self.read()[1].values()), {"Sam"})
        self.assertEqual(c.post(f"/m/api/people/{sam}/delete", json={}, headers=H).status_code, 200)
        self.assertTrue(feed.wait(5))
        _, rows = self.read()
        self.assertEqual((set(rows), set(rows.values())), (self.keys_of("sam"), {""}))

    def test_a_server_that_is_not_asked_for_the_feed_writes_nothing(self):
        c = self.w.client()
        self.assertFalse(hasattr(self.w.bp, "people_feed"))
        self.named(c, "Alex", "alex")
        self.assertEqual(list(self.inbox.iterdir()), [])

    def test_an_unmounted_inbox_is_refused_by_the_servers_own_check(self):
        c = self.w.client(people_feed_s=0.05, check_mount=True)
        feed = self.w.bp.people_feed
        self.addCleanup(feed.close)
        with self.assertLogs("people", "WARNING") as logs:
            self.assertTrue(feed.wait(5))
        self.assertIn("is not mounted", logs.output[0])                # tmp dir is not a mount
        self.assertEqual(list(self.inbox.iterdir()), [])
        self.assertEqual(c.get("/m/api/people").status_code, 200)       # and the app goes on


if __name__ == "__main__":
    unittest.main()
