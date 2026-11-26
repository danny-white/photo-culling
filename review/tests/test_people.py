"""People: `photo_cull.py faces-group`, the rules in review/people.py, the label writes, the /m/api routes and
the search by name. A made-up library of random 512-d "people" in a temp DB (review/tests/people_world.py);
nothing here reads the real library or any real person. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import sqlite3
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "review"))
import people  # noqa: E402
import photo_cull as pc  # noqa: E402
from review.tests.helpers import FakePC  # noqa: E402
from review.tests.people_world import D, NOISE, World, mix, unit  # noqa: E402


# ======================================================================= faces-group
class FaceGroups(unittest.TestCase):
    def setUp(self):
        self.w = World()
        self.addCleanup(self.w.close)

    def meta(self):
        con = sqlite3.connect(self.w.db)
        try:
            return dict(con.execute("SELECT k, v FROM face_groups_meta").fetchall())
        finally:
            con.close()

    def test_each_person_is_one_group_across_days(self):
        code, out = self.w.group()
        self.assertEqual(code, 0, out)
        keys = {p: {self.w.group_of(f) for f in self.w.ids(p)} for p in ("alex", "sam", "robin")}
        for p, k in keys.items():
            self.assertEqual(len(k), 1, f"{p} is in {k}")
        self.assertEqual(len(set().union(*keys.values())), 3)               # three people, three groups
        self.assertEqual(keys["alex"], {min(self.w.ids("alex"))})           # a group's key is its smallest face id
        self.assertEqual(keys["sam"], {min(self.w.ids("sam"))})

    def test_one_face_in_a_day_alone_and_unlike_anyone_is_in_no_group(self):
        self.w.group()
        self.assertIsNone(self.w.group_of(self.w.ids("casey")[0]))

    def test_every_face_gets_a_row_and_the_meta_says_what_was_seen(self):
        self.w.group()
        con = sqlite3.connect(self.w.db)
        self.assertEqual(con.execute("SELECT COUNT(*) FROM face_groups").fetchone()[0], len(self.w.faces))
        con.close()
        m = self.meta()
        self.assertEqual((m["faces_count"], m["faces_max_id"], m["version"]),
                         (str(len(self.w.faces)), str(self.w.faces[-1]["id"]), "g1"))
        self.assertRegex(m["computed_at"], r"^\d{4}-\d\d-\d\dT[\d:.]+\+00:00$")

    def test_people_photographed_together_never_join(self):
        """Two look-alikes (their day-clusters' means are 0.45+ alike, so across days they would join) who
        are in one folder together: the same-folder rule keeps them apart. sis2 is only ever seen with sis1."""
        w = World(days={})
        self.addCleanup(w.close)
        base = w.person("sis1")
        other = unit(np.random.default_rng(9).normal(size=D))
        other = unit(other - (other @ base) * base)
        w.centre["sis2"] = unit(0.55 * base + np.sqrt(1 - 0.55 ** 2) * other)
        for folder, who in {"2026/2026-02-01": {"sis1": 6, "sis2": 6}, "2026/2026-02-02": {"sis1": 7}}.items():
            for person, n in who.items():
                for _ in range(n):
                    w.add_face(person, folder)
        w.commit()
        mean = lambda person, folder: unit(np.mean([w.vector(f) for f in w.ids(person, folder)], axis=0))
        self.assertGreaterEqual(float(mean("sis2", "2026/2026-02-01") @ mean("sis1", "2026/2026-02-02")), 0.45)
        # ^ the premise: were it not for the rule, the two would join across the two days
        code, out = w.group()
        self.assertEqual(code, 0, out)
        g1 = {w.group_of(f) for f in w.ids("sis1")}
        g2 = {w.group_of(f) for f in w.ids("sis2")}
        self.assertEqual((len(g1), len(g2)), (1, 1))
        self.assertNotEqual(g1, g2)

    def test_loose_faces_join_the_nearest_group_or_stay_out(self):
        w = self.w
        lone = w.add_face("alex", "2026/2026-01-05")                       # alone in its folder: a day-cluster of one
        weak = w.add_face("sam", "2026/2026-01-01", score=0.5)             # not a good face
        blurry = w.add_face("robin", "2026/2026-01-02", sharp=10.0)        # not a good face either
        stranger = w.add_face(None, "2026/2026-01-03", score=0.5)          # nobody the library knows
        stranger_good = w.add_face(None, "2026/2026-01-05")
        w.group()
        self.assertEqual(w.group_of(lone), w.group_of(w.ids("alex")[0]))
        self.assertEqual(w.group_of(weak), w.group_of(w.ids("sam")[0]))
        self.assertEqual(w.group_of(blurry), w.group_of(w.ids("robin")[0]))
        self.assertIsNone(w.group_of(stranger))
        self.assertIsNone(w.group_of(stranger_good))

    def test_a_weak_face_alone_never_makes_a_group(self):
        w = World(days={})
        self.addCleanup(w.close)
        for _ in range(5):
            w.add_face("alex", "2026/2026-01-01", score=0.5)
        w.commit()
        code, out = w.group()
        self.assertEqual(code, 0, out)
        self.assertEqual({w.group_of(f["id"]) for f in w.faces}, {None})

    def test_only_faces_of_the_current_version_count(self):
        old = self.w.add_face("alex", "2026/2026-01-01", version="old-model")
        self.w.group()
        self.assertEqual(self.meta()["faces_count"], str(len(self.w.faces) - 1))
        self.assertIsNone(self.w.group_of(old))                              # no row at all

    def test_a_rerun_with_the_same_faces_is_skipped_unless_forced(self):
        self.w.group()
        before = self.meta()
        code, out = self.w.group()
        self.assertEqual(code, 0)
        self.assertIn("Nothing to do", out)
        self.assertEqual(self.meta(), before)                                # not even computed_at
        code, out = self.w.group("--force")
        self.assertEqual(code, 0, out)
        self.assertIn("Done:", out)
        after = self.meta()
        self.assertNotEqual(after["computed_at"], before["computed_at"])
        self.assertEqual({k: v for k, v in after.items() if k != "computed_at"},
                         {k: v for k, v in before.items() if k != "computed_at"})

    def test_a_new_face_or_a_new_grouping_version_runs_it_again(self):
        self.w.group()
        before = self.meta()["computed_at"]
        self.w.add_face("sam", "2026/2026-01-03")
        self.assertIn("Done:", self.w.group()[1])
        self.assertNotEqual(self.meta()["computed_at"], before)
        before = self.meta()["computed_at"]
        with mock.patch.object(pc, "FACE_GROUP_VERSION", "g2"):
            self.assertIn("Done:", self.w.group()[1])
        self.assertEqual(self.meta()["version"], "g2")
        self.assertNotEqual(self.meta()["computed_at"], before)

    def test_a_group_keeps_its_key_when_it_grows_and_every_face_keeps_its_group(self):
        self.w.group()
        before = {f["id"]: self.w.group_of(f["id"]) for f in self.w.faces}
        fresh = self.w.add_face("alex", "2026/2026-01-02")                  # a later (higher) id
        self.w.group()
        for f, g in before.items():
            self.assertEqual(self.w.group_of(f), g)
        self.assertEqual(self.w.group_of(fresh), before[self.w.ids("alex")[0]])

    def test_no_faces_at_all_says_so_and_writes_nothing(self):
        w = World(days={})
        self.addCleanup(w.close)
        code, out = w.group()
        self.assertEqual(code, 0)
        self.assertIn("No faces", out)
        con = sqlite3.connect(w.db)
        self.assertEqual(con.execute("SELECT COUNT(*) FROM face_groups_meta").fetchone()[0], 0)
        con.close()

    def test_a_missing_database_exits_with_a_message(self):
        self.w.db.unlink()
        code, out = self.w.group()
        self.assertEqual(code, 1)

    def test_progress_lines_and_the_elapsed_time(self):
        code, out = self.w.group()
        self.assertIn("Loading 39 faces", out)
        self.assertRegex(out, r"\[1/3\] per day: 4 folders -> \d+ day-clusters, \d+ with 2 or more faces")
        self.assertRegex(out, r"\[2/3\] across days: \d+ day-clusters -> 3 groups")
        self.assertRegex(out, r"\[3/3\] attach: \d+ loose faces joined a group, \d+ are in none")
        self.assertRegex(out, r"Done: 3 groups \(3 with 3 or more faces\), 38 of 39 faces grouped, in \d+m\d\ds\.")

    def test_group_faces_alone_on_plain_arrays(self):
        """The function under the command: unit vectors, a folder code and a good flag per face."""
        rng = np.random.default_rng(3)
        a, b = unit(rng.normal(size=D)), unit(rng.normal(size=D))
        vecs = np.stack([mix(rng, [(c, 1.0)], 0.75) for c in (a, a, a, b, b, b, a, a)])
        folders = np.array([0, 0, 0, 0, 0, 0, 1, 1])
        grp, stats = pc.group_faces(vecs, folders, np.ones(8, bool), np.array([10, 11, 12, 13, 14, 15, 16, 17]))
        self.assertEqual(grp.tolist(), [10, 10, 10, 13, 13, 13, 10, 10])
        self.assertEqual((stats["groups"], stats["folders"]), (2, 2))
        self.assertEqual(pc.group_faces(vecs[:0], folders[:0], np.zeros(0, bool), np.zeros(0, int))[0].tolist(), [])


# ======================================================================= the rules, on arrays
def basis(k, seed=1):
    """k orthonormal 512-d vectors (rows)."""
    q, _ = np.linalg.qr(np.random.default_rng(seed).normal(size=(D, k)))
    return q.T.astype(np.float32)


def like(e, parts):
    """A unit vector: sum of weight * basis vector, the rest of its length on the basis vector `rest`."""
    v = sum(w * e[i] for i, w in parts.items() if i != "rest")
    left = 1 - float(v @ v)
    return (v + np.sqrt(max(left, 0.0)) * e[parts["rest"]]).astype(np.float32)


def make_state(vecs, *, grp=None, folder=None, yes=(), no=(), ignored=(), good=None, score=None):
    """A State over faces numbered 1..n (photo id 10 * face id): yes [(face, person)], no [(face, person)];
    good: which faces are good (all, if not given); score: their detector scores. Without 50 faces scoring
    under 0.6 there is no junk direction, so the junk rule is off."""
    n = len(vecs)
    ids = np.arange(1, n + 1)
    base = people.Base(ids, ids * 10, np.zeros(n, np.int64) if folder is None else np.array(folder),
                       np.full(n, -1) if grp is None else np.array(grp), np.zeros(n), np.zeros((n, 4), np.float32),
                       np.ones(n, np.float32), np.asarray(vecs, np.float32), "k",
                       None if good is None else np.array(good, bool), None if score is None else np.array(score, float))
    who = {p for _, p in list(yes) + list(no)}
    labels = people.Labels({p: {"name": f"Person {p}", "cover_face": None, "created_at": "t", "updated_at": "t"}
                            for p in who},
                           [(f, p, "named") for f, p in yes], list(no), list(ignored))
    return people.compute(base, labels)


class Rules(unittest.TestCase):
    def test_spread_is_even_and_fixed(self):
        self.assertEqual(people.spread(10).tolist(), list(range(10)))
        pos = people.spread(1000)
        self.assertEqual((len(pos), pos[0], pos[-1]), (300, 0, 999))
        self.assertTrue((np.diff(pos) > 0).all())
        self.assertEqual(pos.tolist(), people.spread(1000).tolist())

    def test_the_score_is_the_mean_of_the_top_three(self):
        e = basis(8)
        f = e[0]
        refs = [like(e, {0: s, "rest": 1 + i}) for i, s in enumerate((0.9, 0.6, 0.3, 0.1))]
        v = np.stack([f, *refs])
        self.assertAlmostEqual(float(people.person_score(v, np.array([1, 2, 3, 4]))[0]), (0.9 + 0.6 + 0.3) / 3, places=5)
        self.assertAlmostEqual(float(people.person_score(v, np.array([1, 2]))[0]), (0.9 + 0.6) / 2, places=5)   # fewer than 3
        self.assertAlmostEqual(float(people.person_score(v, np.array([1]))[0]), 0.9, places=5)

    def test_a_person_with_over_300_confirmed_faces_is_scored_against_a_spread_of_300(self):
        rng = np.random.default_rng(4)
        v = unit(rng.normal(size=(450, D)))
        conf = np.arange(50, 450)
        want = people.person_score(v, conf[people.spread(len(conf))])
        np.testing.assert_allclose(people.person_score(v, conf), want, atol=1e-6)
        self.assertEqual(len(people.spread(len(conf))), 300)

    def test_a_confirmed_face_is_that_person_and_an_ignored_one_is_nobody(self):
        e = basis(4)
        st = make_state(e, yes=[(1, 7), (2, 7)], ignored=[2])
        self.assertEqual((st.res.pid[0], HOW(st, 0)), (7, "confirmed"))
        self.assertEqual((st.res.pid[1], HOW(st, 1)), (-1, "none"))        # hidden, though Danny had said yes
        self.assertEqual(len(st.faces[7]), 1)

    def test_the_group_rule_needs_two_thirds_of_the_confirmed_faces(self):
        e = basis(8)                                   # orthogonal faces: only the group can make a face anybody's
        grp = [5, 5, 5, 5, 5, 5, -1, 5]
        st = make_state(e, grp=grp, yes=[(1, 1), (2, 1), (3, 2)])           # 2 of 3 confirmed are person 1
        self.assertEqual([(int(p), HOW(st, i)) for i, p in enumerate(st.res.pid)],
                         [(1, "confirmed"), (1, "confirmed"), (2, "confirmed"), (1, "auto"), (1, "auto"), (1, "auto"),
                          (-1, "none"), (1, "auto")])           # the face outside the group (7th) is nobody's
        st = make_state(e, grp=grp, yes=[(1, 1), (2, 2)])                    # 1 of 2: not enough
        self.assertEqual(st.res.pid.tolist(), [1, 2, -1, -1, -1, -1, -1, -1])
        st = make_state(e, grp=grp, yes=[(1, 1), (2, 1), (3, 1), (4, 2)])    # 3 of 4: enough
        self.assertEqual(st.res.pid.tolist(), [1, 1, 1, 2, 1, 1, -1, 1])

    def test_the_group_rule_skips_a_face_marked_not_that_person_and_ignored_faces(self):
        e = basis(8)
        grp = [5] * 6
        st = make_state(e[:6], grp=grp, yes=[(1, 1), (2, 1)], no=[(4, 1)], ignored=[5])
        self.assertEqual(st.res.pid.tolist(), [1, 1, 1, -1, -1, 1])        # 4 said no, 5 ignored (it is hidden)
        self.assertEqual(int(st.res.how[4]), 0)
        # a confirmed face that is ignored does not count towards the group's majority
        st = make_state(e[:6], grp=grp, yes=[(1, 1), (2, 2)], ignored=[1])
        self.assertEqual(st.res.pid.tolist(), [-1, 2, 2, 2, 2, 2])

    def test_similarity_filing_and_the_suggestion_band(self):
        e = basis(12)
        refs = [e[0]] * 3                                                    # person 1's confirmed faces, all alike
        sims = (0.56, 0.54, 0.45, 0.41, 0.39)
        faces = [like(e, {0: s, "rest": 2 + i}) for i, s in enumerate(sims)]
        st = make_state(np.stack(refs + faces), yes=[(1, 1), (2, 1), (3, 1)])
        res = st.res
        self.assertEqual((int(res.pid[3]), HOW(st, 3)), (1, "auto"))         # at 0.55 and above: filed
        for i, s in ((4, 0.54), (5, 0.45), (6, 0.41)):
            self.assertEqual((int(res.pid[i]), int(res.sug[i])), (-1, 1), f"s={s}")
            self.assertAlmostEqual(float(res.sug_sim[i]), s, places=4)
        self.assertEqual((int(res.pid[7]), int(res.sug[7])), (-1, -1))       # under 0.40: nothing
        self.assertEqual([int(i) for i in st.suggested[1]], [4, 5, 6])      # most alike first

    def test_a_face_needs_a_clear_lead_over_the_next_person(self):
        e = basis(12)
        refs = [e[0]] * 3 + [e[1]] * 3
        close = like(e, {0: 0.60, 1: 0.52, "rest": 2})                       # 0.08 ahead of person 2: unclear
        clear = like(e, {0: 0.60, 1: 0.40, "rest": 3})                       # 0.20 ahead: filed
        st = make_state(np.stack(refs + [close, clear]), yes=[(1, 1), (2, 1), (3, 1), (4, 2), (5, 2), (6, 2)])
        self.assertEqual(int(st.res.pid[6]), -1)
        self.assertEqual(int(st.res.sug[6]), -1)                             # 0.60 is past the band: not a suggestion either
        self.assertEqual((int(st.res.pid[7]), HOW(st, 7)), (1, "auto"))

    def test_face_no_blocks_filing_suggestions_and_the_runner_up_check(self):
        e = basis(12)
        refs = [e[0]] * 3 + [e[1]] * 3
        yes = [(1, 1), (2, 1), (3, 1), (4, 2), (5, 2), (6, 2)]
        sure = like(e, {0: 0.62, "rest": 2})                                 # would be filed under 1
        maybe = like(e, {0: 0.50, "rest": 3})                                # would be suggested for 1
        tied = like(e, {0: 0.62, 1: 0.60, "rest": 4})                        # 1 and 2 almost level
        v = np.stack(refs + [sure, maybe, tied, tied])
        st = make_state(v, yes=yes)
        self.assertEqual([int(st.res.pid[i]) for i in (6, 8)], [1, -1])      # level faces are nobody's
        self.assertEqual(int(st.res.sug[7]), 1)
        st = make_state(v, yes=yes, no=[(7, 1), (8, 1), (9, 2)])
        self.assertEqual(int(st.res.pid[6]), -1, "face_no for 1 blocks filing")
        self.assertEqual(int(st.res.sug[7]), -1, "face_no for 1 blocks the suggestion")
        self.assertEqual(int(st.res.pid[8]), 1, "face_no for 2 takes 2 out, so 1 has no rival")
        self.assertEqual(int(st.res.pid[9]), -1, "the other level face has no face_no, so it stays level")

    def test_unnamed_groups_are_the_unclaimed_ones_with_three_faces_most_days_first(self):
        e = basis(20)
        # group 1: 4 faces on one day; group 2: 3 faces on 3 days; group 3: 2 faces; group 4: 3 faces, one ignored
        grp = [1] * 4 + [2] * 3 + [3] * 2 + [4] * 3
        day = [0] * 4 + [0, 1, 2] + [0, 0] + [5, 5, 5]
        st = make_state(e[:12], grp=grp, folder=day, ignored=[10])
        self.assertEqual([(g["key"], g["faces"], g["days"]) for g in st.groups], [(2, 3, 3), (1, 4, 1)])
        self.assertEqual(sorted(st.unassigned), [1, 2, 3, 4])                # small groups can still be looked up
        self.assertEqual(len(st.unassigned[4]), 2)
        self.assertNotIn("maybe", st.groups[0])

    def test_a_group_needs_two_good_unclaimed_faces_to_be_listed(self):
        e = basis(14)
        grp = [1] * 5 + [2] * 5 + [3] * 4
        good = [True] + [False] * 4 + [True, True] + [False] * 3 + [True] * 4
        st = make_state(e, grp=grp, good=good)
        self.assertEqual([g["key"] for g in st.groups], [3, 2])               # group 1 has one good face: not listed
        self.assertEqual(len(st.unassigned[1]), 5)                            # ... but its faces are still unclaimed
        # and a good face somebody has claimed does not count
        st = make_state(e, grp=[1, 1, 1, 1] + [-1] * 10, good=[True, True, False, False] + [True] * 10, yes=[(1, 7)],
                        no=[(2, 7), (3, 7), (4, 7)])
        self.assertEqual(st.groups, [])                                       # three left, one of them good

    def test_groups_are_ordered_by_the_days_they_have_a_good_face_on(self):
        e = basis(32)
        # A: 6 good faces on one day and 10 others on five more; B: 4 good faces on three days; C: 3 good on
        # one day; D: 6 good on two days; E: the same as C
        grp = [1] * 16 + [2] * 4 + [3] * 3 + [4] * 6 + [5] * 3
        folder = [0] * 6 + [1, 1, 2, 2, 3, 3, 4, 4, 5, 5] + [0, 0, 1, 2] + [0] * 3 + [0, 0, 0, 1, 1, 1] + [7] * 3
        good = [True] * 6 + [False] * 10 + [True] * 4 + [True] * 3 + [True] * 6 + [True] * 3
        st = make_state(e, grp=grp, folder=folder, good=good)
        self.assertEqual([g["key"] for g in st.groups], [2, 4, 1, 3, 5])      # 3, 2, 1 (6 good), 1 (3 good), 1 (key 5)
        a = st.groups[2]
        self.assertEqual((a["faces"], a["photos"], a["days"]), (16, 16, 6))   # the counts still count every face
        self.assertEqual(set(a), {"key", "faces", "photos", "days", "cover"})

    def test_the_junk_direction_is_the_mean_of_the_low_score_faces_and_needs_enough_of_them(self):
        e = basis(8)
        score = [0.9, 0.5, 0.4, 0.9, 0.3, 0.9, 0.6, np.nan]                      # low: faces 2, 3 and 5 (0.6 is not under 0.6)
        with mock.patch.object(people, "JUNK_MIN_LOW", 3):
            base = make_state(e, score=score).base
        np.testing.assert_allclose(base.junk_dir, unit(e[1] + e[2] + e[4]), atol=1e-6)
        self.assertAlmostEqual(float(np.linalg.norm(base.junk_dir)), 1.0, places=5)
        with mock.patch.object(people, "JUNK_MIN_LOW", 4):
            self.assertIsNone(make_state(e, score=score).base.junk_dir)             # 3 low faces: too few
        self.assertIsNone(make_state(e, score=score).base.junk_dir)                 # the real minimum is 50
        self.assertIsNone(make_state(e).base.junk_dir)                              # no scores given
        self.assertIsNone(people.Base.empty().junk_dir)

    def test_the_junk_rule_needs_its_direction_but_the_good_face_rule_does_not(self):
        rng = np.random.default_rng(8)
        d = unit(rng.normal(size=D))
        junk = np.stack([mix(rng, [(d, 1.0)], NOISE) for _ in range(55)])          # weak faces that share a direction
        other = unit(rng.normal(size=(4, D)))
        vecs = np.concatenate([junk, other])
        grp = [1] * 5 + [-1] * 50 + [2] * 4
        score = [0.5] * 55 + [0.9] * 4
        good = [True] * 5 + [False] * 50 + [True] * 4                                # the junk group has good faces
        st = make_state(vecs, grp=grp, good=good, score=score)
        self.assertEqual([g["key"] for g in st.groups], [2])                         # group 1 sits on the junk direction
        self.assertGreaterEqual(float(unit(vecs[:5].mean(axis=0)) @ st.base.junk_dir), people.JUNK_SIM)
        self.assertEqual(len(st.unassigned[1]), 5)
        few = np.concatenate([vecs[:5], vecs[55:]])                                  # the same five junk faces, 5 weak ones in all
        low_few = make_state(few, grp=[1] * 5 + [2] * 4, good=[True] * 9, score=[0.5] * 5 + [0.9] * 4)
        self.assertEqual([g["key"] for g in low_few.groups], [1, 2])
        self.assertIsNone(low_few.base.junk_dir)
        one_good = make_state(few, grp=[1] * 5 + [2] * 4, good=[True] + [False] * 4 + [True] * 4,
                              score=[0.5] * 5 + [0.9] * 4)
        self.assertEqual([g["key"] for g in one_good.groups], [2])                   # MIN_GOOD applies with no direction too

    def test_a_group_may_be_a_named_person(self):
        e = basis(20)
        near = [like(e, {0: 0.42 + 0.03 * i, "rest": 5 + i}) for i in range(3)]       # suggestions for person 1
        far = [e[10], e[11], e[12]]
        refs = [e[0]] * 3
        st = make_state(np.stack(refs + near + far), grp=[-1] * 3 + [1] * 3 + [2] * 3, folder=[9] * 3 + [1, 2, 3] + [4, 5, 6],
                        yes=[(1, 1), (2, 1), (3, 1)])
        by_key = {g["key"]: g for g in st.groups}
        self.assertEqual(by_key[1]["maybe"], {"id": 1, "name": "Person 1"})
        self.assertNotIn("maybe", by_key[2])
        # ... unless most of its faces are marked not that person
        st = make_state(np.stack(refs + near + far), grp=[-1] * 3 + [1] * 3 + [2] * 3, folder=[9] * 3 + [1, 2, 3] + [4, 5, 6],
                        yes=[(1, 1), (2, 1), (3, 1)], no=[(4, 1), (5, 1)])
        self.assertNotIn("maybe", {g["key"]: g for g in st.groups}[1])

    def test_newest_photo_first(self):
        st = make_state(basis(4))
        st.base.ts[:] = [5, 9, 9, 1]
        self.assertEqual(people.newest_first(st.base, np.arange(4)), [30, 20, 10, 40])   # ts 9 (id tie: higher first), 5, 1


def HOW(st, i):
    return people.HOW[int(st.res.how[i])]


# ======================================================================= PeopleIndex on a made-up library
class IndexCase(unittest.TestCase):
    def setUp(self):
        self.w = World()
        self.addCleanup(self.w.close)

    def grouped(self):
        """The index over a real faces-group run."""
        self.w.group()
        return self.w.index()

    def two_looks(self):
        """alex in two groups (her last day was not grouped with the others), sam and robin one each, casey none."""
        w = self.w
        w.write_groups({
            self.key("alex", "2026/2026-01-01"): w.ids("alex", "2026/2026-01-01") + w.ids("alex", "2026/2026-01-02"),
            self.key("alex", "2026/2026-01-04"): w.ids("alex", "2026/2026-01-04"),
            self.key("sam"): w.ids("sam"), self.key("robin"): w.ids("robin")})
        return w.index()

    def key(self, person, folder=None):
        return min(self.w.ids(person, folder))

    def regroup_same(self, ix):
        """A new grouping run (a new computed_at) that groups every face as before."""
        st = ix.state()
        self.w.write_groups({k: st.base.ids[v].tolist() for k, v in st.base.group_faces.items()})


class Naming(IndexCase):
    def test_unnamed_groups_come_with_their_counts_most_days_first(self):
        ix = self.grouped()
        st = ix.state()
        self.assertEqual(ix.people_json(st), [])
        self.assertEqual([(g["key"], g["faces"], g["photos"], g["days"]) for g in st.groups],
                         [(self.key("alex"), 18, 18, 3), (self.key("sam"), 11, 11, 2), (self.key("robin"), 9, 9, 2)])
        for g in st.groups:
            self.assertIn(g["cover"], self.w.ids("alex") + self.w.ids("sam") + self.w.ids("robin"))

    def test_naming_a_group_confirms_every_face_in_it(self):
        ix = self.grouped()
        pid, st = ix.create("  Alex  ", group=self.key("alex"))
        self.assertEqual(ix.person_json(st, pid), {"id": pid, "name": "Alex", "photos": 18, "faces": 18,
                                                    "cover": st.cover[pid], "suggestions": 0})
        self.assertIn(st.cover[pid], self.w.ids("alex"))
        rows = self.w.labels("face_yes")
        self.assertEqual(sorted(r["face_id"] for r in rows), sorted(self.w.ids("alex")))
        self.assertEqual({(r["person_id"], r["how"]) for r in rows}, {(pid, "named")})
        self.assertEqual([r["name"] for r in self.w.labels("people")], ["Alex"])
        self.assertEqual([g["key"] for g in st.groups], [self.key("sam"), self.key("robin")])   # no longer unnamed

    def test_a_deleted_persons_id_is_never_reused(self):
        ix = self.grouped()
        alex, _ = ix.create("Alex", group=self.key("alex"))
        sam, _ = ix.create("Sam", group=self.key("sam"))
        ix.delete(sam)                                                       # the highest id goes ...
        robin, _ = ix.create("Robin", group=self.key("robin"))
        self.assertGreater(robin, sam)                                       # ... and does not come back
        ix.merge(robin, alex)                                                # a merge deletes one too
        casey, _ = ix.create("Casey", faces=[self.w.ids("casey")[0]])
        self.assertGreater(casey, robin)

    def test_naming_faces_and_a_group_together(self):
        ix = self.grouped()
        pid, st = ix.create("Sam", group=self.key("sam"), faces=[self.w.ids("casey")[0]])
        self.assertEqual(ix.person_json(st, pid)["faces"], 12)

    def test_a_name_taken_in_any_case_is_a_409_carrying_the_person(self):
        ix = self.grouped()
        pid, st = ix.create("Alex", group=self.key("alex"))
        with self.assertRaises(people.PeopleError) as cm:
            ix.create("aLEX", group=self.key("sam"))
        self.assertEqual(cm.exception.status, 409)
        self.assertEqual(cm.exception.body["person"], ix.person_json(ix.state(), pid))
        self.assertEqual(len(self.w.labels("people")), 1)                    # nothing was written
        with self.assertRaises(people.PeopleError) as cm:
            ix.update(ix.create("Sam", group=self.key("sam"))[0], name=" ALEX ")
        self.assertEqual(cm.exception.status, 409)

    def test_bad_names_and_bodies_are_400_and_unknown_things_404(self):
        ix = self.grouped()
        g = self.key("alex")
        cases = [(dict(name=""), 400), (dict(name="   ", group=g), 400), (dict(name=5, group=g), 400),
                 (dict(name="x" * 81, group=g), 400), (dict(name="Alex"), 400),
                 (dict(name="Alex", group="1"), 400), (dict(name="Alex", faces="all"), 400),
                 (dict(name="Alex", faces=[True]), 400), (dict(name="Alex", faces=[]), 400),
                 (dict(name="Alex", group=999999), 404), (dict(name="Alex", faces=[999999]), 404)]
        for kw, status in cases:
            with self.subTest(kw):
                with self.assertRaises(people.PeopleError) as cm:
                    ix.create(**kw)
                self.assertEqual(cm.exception.status, status)
        ix.create("x" * 80, group=g)                                         # 80 is fine
        self.assertEqual(len(self.w.labels("people")), 1)


class Filing(IndexCase):
    def test_another_look_of_the_same_person_is_filed_automatically(self):
        ix = self.two_looks()
        st = ix.state()
        self.assertEqual(len(st.groups), 4)                                   # her two looks, sam, robin
        pid, st = ix.create("Alex", group=self.key("alex", "2026/2026-01-01"))
        faces = ix.faces_of(st, pid, 0, 100)
        self.assertEqual(faces["total"], 18)                                  # the 13 named, the 5 of the other group
        how = {f["id"]: f["how"] for f in faces["faces"]}
        self.assertEqual({how[f] for f in self.w.ids("alex", "2026/2026-01-04")}, {"auto"})
        self.assertEqual({how[f] for f in self.w.ids("alex", "2026/2026-01-01")}, {"confirmed"})
        self.assertEqual([f["how"] for f in faces["faces"]][:5], ["auto"] * 5)   # the least sure come first
        self.assertEqual([g["key"] for g in st.groups], [self.key("sam"), self.key("robin")])
        self.assertEqual(len(self.w.labels("face_yes")), 13)                  # filing is never written down

    def test_other_people_are_not_filed_under_someone(self):
        ix = self.two_looks()
        pid, st = ix.create("Alex", group=self.key("alex", "2026/2026-01-01"))
        for f in self.w.ids("sam") + self.w.ids("robin") + self.w.ids("casey"):
            self.assertEqual(int(st.res.pid[st.base.idx_of[f]]), -1)

    def suggestion_world(self):
        """alex named from her main group; four faces of nobody in particular, about 0.45 alike to her, in a group of their own."""
        ix = self.two_looks()
        pid, st = ix.create("Alex", group=self.key("alex", "2026/2026-01-01"))
        mine = self.w.add_lookalikes("alex", 4, "2026/2026-01-06")
        self.w.add_group(mine)
        return ix, pid, mine

    def test_faces_in_the_band_become_suggestions_and_their_group_may_be_the_person(self):
        ix, pid, mine = self.suggestion_world()
        st = ix.state()
        for f in mine:
            s = float(st.res.sug_sim[st.base.idx_of[f]])
            self.assertTrue(0.40 <= s < 0.55, s)
            self.assertEqual(int(st.res.sug[st.base.idx_of[f]]), pid)
        self.assertEqual(ix.person_json(st, pid)["suggestions"], 4)
        sug = ix.suggestions_of(st, pid)
        self.assertEqual(sorted(f["id"] for f in sug["faces"]), sorted(mine))
        self.assertEqual([f["sim"] for f in sug["faces"]], sorted((f["sim"] for f in sug["faces"]), reverse=True))
        (g,) = sug["groups"]
        self.assertEqual((g["key"], g["faces"], g["maybe"]), (mine[0], 4, {"id": pid, "name": "Alex"}))
        # the faces are still unclaimed, so the group is in the unnamed list too
        self.assertIn(mine[0], [x["key"] for x in st.groups])

    def test_review_yes_confirms_and_no_blocks_the_face_for_good(self):
        ix, pid, mine = self.suggestion_world()
        st = ix.review(pid, yes=[mine[0]], no=[mine[1]])
        i0, i1 = st.base.idx_of[mine[0]], st.base.idx_of[mine[1]]
        self.assertEqual((int(st.res.pid[i0]), HOW(st, i0)), (pid, "confirmed"))
        self.assertEqual(int(st.res.sug[i1]), -1)
        # one confirmed face answers for its whole group (the group rule): the other two are filed, not suggested
        self.assertEqual([HOW(st, st.base.idx_of[f]) for f in mine[2:]], ["auto", "auto"])
        self.assertEqual(ix.person_json(st, pid)["suggestions"], 0)
        self.assertEqual([(r["face_id"], r["person_id"]) for r in self.w.labels("face_no")], [(mine[1], pid)])
        yes = {r["face_id"]: r["how"] for r in self.w.labels("face_yes")}
        self.assertEqual(yes[mine[0]], "confirmed")
        # the refused face stays out of its group's filing, and a new grouping run does not bring it back
        self.assertEqual(int(st.res.pid[i1]), -1)
        self.regroup_same(ix)
        st = ix.state()
        self.assertEqual((int(st.res.pid[i1]), int(st.res.sug[i1])), (-1, -1))
        with self.assertRaises(people.PeopleError) as cm:
            ix.review(pid, yes=[mine[2]], no=[mine[2]])
        self.assertEqual(cm.exception.status, 400)

    def test_review_no_for_a_face_that_was_a_yes_takes_it_back(self):
        ix = self.two_looks()
        pid, st = ix.create("Alex", group=self.key("alex", "2026/2026-01-01"))
        face = self.w.ids("alex", "2026/2026-01-01")[0]
        st = ix.review(pid, yes=[], no=[face])
        self.assertEqual(int(st.res.pid[st.base.idx_of[face]]), -1)
        self.assertEqual([r["face_id"] for r in self.w.labels("face_yes")].count(face), 0)


class Corrections(IndexCase):
    def setUp(self):
        super().setUp()
        self.ix = self.two_looks()
        self.alex, _ = self.ix.create("Alex", group=self.key("alex", "2026/2026-01-01"))
        self.sam, self.st = self.ix.create("Sam", group=self.key("sam"))

    def test_not_removes_the_face_and_never_suggests_it_again(self):
        auto = self.w.ids("alex", "2026/2026-01-04")[0]                       # filed automatically
        st = self.ix.act([auto], "not", self.alex)
        self.assertEqual(int(st.res.pid[st.base.idx_of[auto]]), -1)
        self.assertEqual([(r["face_id"], r["person_id"]) for r in self.w.labels("face_no")], [(auto, self.alex)])
        # and for a confirmed one: its face_yes goes, its face_no comes
        sure = self.w.ids("alex", "2026/2026-01-01")[0]
        st = self.ix.act([sure], "not", self.alex)
        self.assertEqual(int(st.res.pid[st.base.idx_of[sure]]), -1)
        self.assertNotIn(sure, [r["face_id"] for r in self.w.labels("face_yes")])
        self.assertEqual(self.ix.person_json(st, self.alex)["faces"], 18 - 2)

    def test_move_gives_the_face_to_another_person(self):
        face = self.w.ids("alex", "2026/2026-01-01")[0]
        st = self.ix.act([face], "move", self.sam)
        i = st.base.idx_of[face]
        self.assertEqual((int(st.res.pid[i]), HOW(st, i)), (self.sam, "confirmed"))
        yes = {r["face_id"]: (r["person_id"], r["how"]) for r in self.w.labels("face_yes")}
        self.assertEqual(yes[face], (self.sam, "moved"))
        self.assertEqual(self.ix.person_json(st, self.sam)["faces"], 12)

    def test_ignore_hides_a_face_everywhere(self):
        face = self.w.ids("alex", "2026/2026-01-01")[0]
        photo = next(f["photo"] for f in self.w.faces if f["id"] == face)
        self.assertIn(face, [f["id"] for f in self.ix.photo_faces(self.ix.state(), photo)])
        st = self.ix.act([face], "ignore")
        self.assertNotIn(face, [f["id"] for f in self.ix.photo_faces(st, photo)])
        self.assertNotIn(photo, self.ix.photos_of(st, self.alex))
        self.assertEqual(self.ix.person_json(st, self.alex)["faces"], 17)
        self.assertEqual([r["face_id"] for r in self.w.labels("face_ignored")], [face])
        self.assertEqual(len(self.w.labels("face_yes")), 13 + 11)            # spec: ignoring only adds to face_ignored
        # and a stranger in an unnamed group
        rob = self.w.ids("robin")[0]
        st = self.ix.act([rob], "ignore")
        self.assertEqual(next(g for g in st.groups if g["key"] == self.key("robin"))["faces"], 8)

    def test_act_validates(self):
        face = self.w.ids("alex")[0]
        for args, status in [(([face], "bogus", self.sam), 400), (([face], "move", None), 400), (([face], "not", "x"), 400),
                             (([], "ignore", None), 400), (("all", "ignore", None), 400), (([999999], "ignore", None), 404),
                             (([face], "move", 999999), 404)]:
            with self.subTest(args):
                with self.assertRaises(people.PeopleError) as cm:
                    self.ix.act(*args)
                self.assertEqual(cm.exception.status, status)

    def test_add_gives_faces_to_a_person_and_clears_face_no(self):
        casey = self.w.ids("casey")[0]
        self.ix.act([casey], "not", self.alex)
        st = self.ix.add(self.alex, faces=[casey])
        self.assertEqual(int(st.res.pid[st.base.idx_of[casey]]), self.alex)
        self.assertEqual(self.w.labels("face_no"), [])
        self.assertEqual({r["how"] for r in self.w.labels("face_yes") if r["face_id"] == casey}, {"added"})
        with self.assertRaises(people.PeopleError) as cm:
            self.ix.add(self.alex)
        self.assertEqual(cm.exception.status, 400)
        with self.assertRaises(people.PeopleError) as cm:
            self.ix.add(999999, faces=[casey])
        self.assertEqual(cm.exception.status, 404)

    def test_add_a_group_takes_only_its_unclaimed_faces(self):
        rob = self.w.ids("robin")
        self.ix.act(rob[:2], "ignore")
        st = self.ix.add(self.sam, group=self.key("robin"))
        self.assertEqual(self.ix.person_json(st, self.sam)["faces"], 11 + 7)

    def test_merge_moves_faces_and_refusals_and_deletes_the_person(self):
        s0 = self.w.ids("sam")[0]
        r0 = self.w.ids("robin")[0]
        self.ix.act([r0], "not", self.sam)                 # robin's face: "not Sam"
        self.ix.act([s0], "not", self.alex)                # sam's face: "not Alex" (it stays Sam's)
        st = self.ix.merge(self.sam, self.alex)
        self.assertNotIn(self.sam, st.people)
        self.assertEqual(self.ix.person_json(st, self.alex)["faces"], 18 + 11)
        yes = {r["face_id"]: r["person_id"] for r in self.w.labels("face_yes")}
        self.assertEqual(len(yes), 13 + 11)
        self.assertEqual({yes[f] for f in self.w.ids("sam")}, {self.alex})
        # Sam's refusal came across; the one that said s0 is not Alex is moot now that it is Alex's, so it went
        self.assertEqual([(r["face_id"], r["person_id"]) for r in self.w.labels("face_no")], [(r0, self.alex)])
        self.assertEqual([r["name"] for r in self.w.labels("people")], ["Alex"])

    def test_merge_leaves_out_a_refusal_for_a_face_that_is_already_a_yes(self):
        """P's face_no for a face that is `into`'s face_yes is dropped, not carried over."""
        f = self.w.ids("robin")[0]
        self.ix.add(self.alex, faces=[f])                  # Alex is robin's face f...
        self.ix.act([f], "not", self.sam)                   # ... and Sam says it is not hers
        st = self.ix.merge(self.sam, self.alex)
        self.assertEqual([(r["face_id"], r["person_id"]) for r in self.w.labels("face_no")], [])
        self.assertEqual(int(st.res.pid[st.base.idx_of[f]]), self.alex)

    def test_merge_validates(self):
        for args, status in [((self.alex, self.alex), 400), ((self.alex, 999999), 404), ((999999, self.alex), 404),
                             ((self.alex, "x"), 400), ((self.alex, None), 400)]:
            with self.subTest(args):
                with self.assertRaises(people.PeopleError) as cm:
                    self.ix.merge(*args)
                self.assertEqual(cm.exception.status, status)

    def test_deleting_a_person_sends_the_faces_back_to_their_groups(self):
        st = self.ix.delete(self.sam)
        self.assertNotIn(self.sam, st.people)
        self.assertIn(self.key("sam"), [g["key"] for g in st.groups])        # an unnamed group again
        self.assertEqual({r["person_id"] for r in self.w.labels("face_yes")}, {self.alex})
        self.assertEqual([r["name"] for r in self.w.labels("people")], ["Alex"])
        with self.assertRaises(people.PeopleError) as cm:
            self.ix.delete(self.sam)
        self.assertEqual(cm.exception.status, 404)

    def test_hide_a_group_ignores_its_unclaimed_faces(self):
        st = self.ix.hide_group(self.key("robin"))
        self.assertEqual(sorted(r["face_id"] for r in self.w.labels("face_ignored")), sorted(self.w.ids("robin")))
        self.assertNotIn(self.key("robin"), [g["key"] for g in st.groups])
        with self.assertRaises(people.PeopleError) as cm:
            self.ix.hide_group(999999)
        self.assertEqual(cm.exception.status, 404)
        st = self.ix.hide_group(self.key("sam"))                              # all Sam's: claimed, so nothing to hide
        self.assertEqual(len(self.w.labels("face_ignored")), 9)
        self.assertEqual(self.ix.person_json(st, self.sam)["faces"], 11)

    def test_rename_and_cover(self):
        st = self.ix.update(self.alex, name="Alexandra")
        self.assertEqual(self.ix.person_json(st, self.alex)["name"], "Alexandra")
        face = self.w.ids("alex")[3]
        st = self.ix.update(self.alex, cover=face, set_cover=True)
        self.assertEqual(self.ix.person_json(st, self.alex)["cover"], face)
        st = self.ix.update(self.alex, name="Alex")                            # renaming keeps the cover
        self.assertEqual(self.ix.person_json(st, self.alex)["cover"], face)
        st = self.ix.update(self.alex, cover=None, set_cover=True)             # back to the best confirmed face
        self.assertNotEqual(self.ix.person_json(st, self.alex)["cover"], None)
        for kw, status in [(dict(), 400), (dict(cover="x", set_cover=True), 400), (dict(cover=999999, set_cover=True), 404),
                           (dict(cover=self.w.ids("sam")[0], set_cover=True), 400), (dict(name="sam"), 409)]:
            with self.subTest(kw):
                with self.assertRaises(people.PeopleError) as cm:
                    self.ix.update(self.alex, **kw)
                self.assertEqual(cm.exception.status, status)
        with self.assertRaises(people.PeopleError) as cm:
            self.ix.update(999999, name="Nobody")
        self.assertEqual(cm.exception.status, 404)

    def test_the_cover_is_dropped_when_the_face_stops_being_theirs(self):
        face = self.w.ids("alex")[3]
        self.ix.update(self.alex, cover=face, set_cover=True)
        st = self.ix.act([face], "not", self.alex)
        self.assertNotIn(self.ix.person_json(st, self.alex)["cover"], (None, face))

    def test_a_failed_write_changes_nothing(self):
        before = self.w.labels("face_yes")
        with self.assertRaises(people.PeopleError):
            self.ix.review(self.alex, yes=[self.w.ids("robin")[0]], no=[999999])
        self.assertEqual(self.w.labels("face_yes"), before)

    def test_faces_in_a_photo_say_who_they_are(self):
        photo, (fa, fs) = self.w.together("2026/2026-01-01", ["alex", "sam"])
        self.regroup_same(self.ix)
        faces = self.ix.photo_faces(self.ix.state(), photo)
        self.assertEqual([f["id"] for f in faces], [fa, fs])                   # left to right
        self.assertEqual(faces[0]["person"], {"id": self.alex, "name": "Alex"})
        self.assertEqual(faces[0]["how"], "auto")                              # not in a group, so by looks alone
        self.assertEqual(faces[1]["person"], {"id": self.sam, "name": "Sam"})
        self.assertEqual(len(faces[0]["box"]), 4)
        self.assertEqual(self.ix.photo_faces(self.ix.state(), 123456789), [])


class Refresh(IndexCase):
    def test_it_is_empty_before_the_first_grouping_run(self):
        st = self.w.index().state()
        self.assertEqual((st.people, st.groups, len(st.base.ids)), ({}, [], 0))
        self.assertEqual(self.w.index().people_json(st), [])

    def test_it_is_empty_on_a_database_with_no_face_tables_at_all(self):
        bare = self.w.dir / "bare.db"
        con = sqlite3.connect(bare)
        con.execute("CREATE TABLE images(path TEXT, status TEXT)")
        con.commit()
        con.close()
        ix = people.PeopleIndex(db_ro=lambda: sqlite3.connect(f"file:{bare}?mode=ro", uri=True), anno=self.w.anno, pc=pc)
        self.assertEqual(ix.state().groups, [])
        self.assertEqual(ix.coverage(), (0, 0))

    def test_coverage_counts_photos_checked_and_ok(self):
        self.w.group()
        self.w.photo("2026/2026-01-09")
        self.w.commit()
        self.assertEqual(self.w.index().coverage(), (39, 40))               # the new photo is ok but not yet checked

    def test_faces_arriving_between_grouping_runs_do_not_rebuild_it(self):
        ix = self.grouped()
        first = ix.state()
        self.w.add_face("sam", "2026/2026-01-03")                            # the backfill goes on
        self.w.commit()
        self.assertIs(ix.state(), first)
        self.w.group()                                                       # a new grouping run
        second = ix.state()
        self.assertIsNot(second, first)
        self.assertEqual(len(second.base.ids), len(first.base.ids) + 1)

    def test_it_looks_for_a_new_run_at_most_every_refresh_s(self):
        self.w.group()
        ix = self.w.index(refresh_s=3600)
        first = ix.state()
        self.w.group("--force")
        self.assertIs(ix.state(), first)                                     # too soon to look
        ix._checked = 0.0
        self.assertIsNot(ix.state(), first)

    def test_labels_survive_a_regrouping_and_a_restart(self):
        ix = self.grouped()
        pid, st = ix.create("Alex", group=self.key("alex"))
        self.w.add_face("alex", "2026/2026-01-02")                           # a new face of Alex's
        self.w.group()
        st = ix.state()
        self.assertEqual(ix.person_json(st, pid)["faces"], 19)               # the group rule files the new one
        again = self.w.index().state()                                      # a restarted server
        self.assertEqual(ix.people_json(again), ix.people_json(st))

    def test_a_failed_rebuild_keeps_the_old_index(self):
        ix = self.grouped()
        first = ix.state()
        self.w.group("--force")
        with mock.patch.object(ix, "_load_base", side_effect=sqlite3.OperationalError("database is locked")):
            self.assertIs(ix.state(), first)
        self.assertIsNot(ix.state(), first)                                  # and it tries again

    def test_only_the_people_whose_confirmed_faces_changed_are_scored_again(self):
        ix = self.two_looks()
        with mock.patch.object(people, "person_score", wraps=people.person_score) as score:
            alex, _ = ix.create("Alex", group=self.key("alex", "2026/2026-01-01"))
            sam, _ = ix.create("Sam", group=self.key("sam"))
            self.assertEqual(score.call_count, 2)                            # Alex, then Sam: Alex's scores are kept
            score.reset_mock()
            ix.update(alex, name="Alexandra")
            ix.act([self.w.ids("robin")[0]], "ignore")
            ix.act([self.w.ids("alex", "2026/2026-01-04")[0]], "not", alex)   # filed automatically, not confirmed
            self.assertEqual(score.call_count, 0)
            ix.review(alex, yes=[self.w.ids("casey")[0]], no=[])
            self.assertEqual(score.call_count, 1)                            # Alex only
            ix.act([self.w.ids("sam")[0]], "move", alex)
            self.assertEqual(score.call_count, 3)                            # Alex gained one, Sam lost it


class Concurrency(IndexCase):
    def test_readers_and_writers_do_not_trip_over_each_other(self):
        ix = self.two_looks()
        alex, _ = ix.create("Alex", group=self.key("alex", "2026/2026-01-01"))
        errors, stop = [], threading.Event()

        def reader():
            try:
                while not stop.is_set():
                    st = ix.state()
                    for p in ix.people_json(st):
                        self.assertEqual(p["faces"], len(st.faces[p["id"]]))
                    ix.photos_of(st, alex)
                    ix.name_photos()
                    time.sleep(0.002)
            except BaseException as e:  # noqa: BLE001
                errors.append(e)
        threads = [threading.Thread(target=reader) for _ in range(4)]
        for t in threads:
            t.start()
        try:
            sam, _ = ix.create("Sam", group=self.key("sam"))
            for _ in range(3):
                ix.review(sam, yes=[self.w.ids("robin")[0]], no=[])
                ix.act([self.w.ids("robin")[0]], "not", sam)
            self.w.group("--force")
            ix.state()
            ix.merge(sam, alex)
        finally:
            stop.set()
            for t in threads:
                t.join(10)
        self.assertEqual(errors, [])
        self.assertEqual([p["name"] for p in ix.people_json(ix.state())], ["Alex"])

    def test_two_writers_at_once_both_land(self):
        ix = self.two_looks()
        results = []

        def name(who, group):
            try:
                results.append(ix.create(who, group=group)[0])
            except BaseException as e:  # noqa: BLE001
                results.append(e)
        ts = [threading.Thread(target=name, args=(n, g)) for n, g in
              (("Alex", self.key("alex", "2026/2026-01-01")), ("Sam", self.key("sam")), ("Robin", self.key("robin")))]
        for t in ts:
            t.start()
        for t in ts:
            t.join(15)
        self.assertEqual(len(results), 3)
        self.assertTrue(all(isinstance(r, int) for r in results), results)
        self.assertEqual(sorted(p["name"] for p in ix.people_json(ix.state())), ["Alex", "Robin", "Sam"])


# ======================================================================= groups that are not people
class JunkGroups(unittest.TestCase):
    """Unnamed groups that are probably not people are left out of the list. 14 people, a junk cluster of 60
    weak faces (enough of them to give the rule its direction), a "dog" and two groups with too few good faces.
    Written by hand as the groups, so the clustering does not matter."""
    P0_PER_DAY = 4                  # faces of the first person on each of their two days

    def setUp(self):
        days = {}
        for k in range(14):
            for d in {k % 7, (k + 3) % 7}:
                days.setdefault(f"2026/2026-03-{d + 1:02d}", {})[f"p{k}"] = self.P0_PER_DAY if k == 0 else 4
        self.w = w = World(days=days)
        self.addCleanup(w.close)
        rng = w.rng
        groups = {min(ids): ids for ids in (w.ids(f"p{k}") for k in range(14))}
        self.people_keys = set(groups)
        day = lambda i, n: f"2026/2026-03-{i % n + 1:02d}"
        # junk: 60 weak faces (a wheel, the backs of heads, blur) around one direction of their own
        wheel = unit(rng.normal(size=D))
        self.junk = [w.add_face(None, day(i, 6), vector=mix(rng, [(wheel, 1.0)], NOISE), score=0.55, sharp=20.0)
                     for i in range(60)]
        # a dog: tight and unlike anything else; 3 of its 12 faces are good, on three different days
        dog = unit(rng.normal(size=D))
        self.dog = [w.add_face(None, day(i, 4), vector=mix(rng, [(dog, 1.0)], NOISE), score=0.9 if i < 3 else 0.5)
                    for i in range(12)]
        # a tight cluster with only one good face
        thing = unit(rng.normal(size=D))
        self.thing = [w.add_face(None, day(i, 3), vector=mix(rng, [(thing, 1.0)], NOISE), score=0.9 if i == 0 else 0.5)
                      for i in range(6)]
        # weak faces of p5, in a group of their own
        self.weak = [w.add_face("p5", day(i, 3), score=0.5) for i in range(5)]
        w.commit()
        groups.update({min(g): g for g in (self.junk, self.dog, self.thing, self.weak)})
        w.write_groups(groups)
        self.ix = w.index()

    def mean_vs_junk_dir(self, st, ids):
        return float(unit(np.mean([self.w.vector(f) for f in ids], axis=0)) @ st.base.junk_dir)

    def test_the_numbers_the_rule_rests_on_hold_in_this_library(self):
        st = self.ix.state()
        self.assertGreaterEqual(self.mean_vs_junk_dir(st, self.junk), people.JUNK_SIM)
        for k in range(14):
            self.assertLess(self.mean_vs_junk_dir(st, self.w.ids(f"p{k}")[:8]), people.JUNK_SIM - 0.2)
        self.assertLess(self.mean_vs_junk_dir(st, self.dog), people.JUNK_SIM - 0.1)
        self.assertIsNotNone(st.base.junk_dir)

    def test_junk_and_groups_with_too_few_good_faces_are_not_listed_and_a_dog_is(self):
        st = self.ix.state()
        listed = {g["key"] for g in st.groups}
        self.assertNotIn(min(self.junk), listed)
        self.assertNotIn(min(self.thing), listed)                             # one good face
        self.assertNotIn(min(self.weak), listed)                              # none
        self.assertIn(min(self.dog), listed)                                  # 3 good of 12: a dog may get a name
        self.assertEqual(listed, self.people_keys | {min(self.dog)})
        dog = next(g for g in st.groups if g["key"] == min(self.dog))
        self.assertEqual((dog["faces"], dog["days"]), (12, 4))

    def test_the_dog_with_good_faces_on_three_days_comes_before_people_on_two(self):
        st = self.ix.state()
        self.assertEqual(st.groups[0]["key"], min(self.dog))

    def test_a_hidden_group_still_opens_and_can_still_be_named_or_hidden(self):
        c = self.w.client()
        listed = {g["key"] for g in c.get("/m/api/people").get_json()["groups"]}
        self.assertNotIn(min(self.junk), listed)
        r = c.get(f"/m/api/people/group/{min(self.junk)}")
        self.assertEqual((r.status_code, r.get_json()["total"]), (200, 60))
        self.assertEqual(len(self.ix.state().unassigned[min(self.junk)]), 60)  # still unclaimed
        r = c.post("/m/api/people", json={"name": "Rex", "group": min(self.thing)}, headers=H)
        self.assertEqual((r.status_code, r.get_json()["faces"]), (201, 6))
        r = c.post(f"/m/api/people/group/{min(self.junk)}/hide", json={}, headers=H)
        self.assertEqual(r.status_code, 200)

    def test_a_hidden_groups_faces_are_still_filed_one_by_one_by_their_looks(self):
        p5 = self.w.ids("p5")[:8]                                              # the good ones, in p5's own group
        pid, st = self.ix.create("P5", group=min(p5))
        for f in self.weak:
            i = st.base.idx_of[f]
            self.assertEqual((int(st.res.pid[i]), HOW(st, i)), (pid, "auto"))
        self.assertNotIn(min(self.weak), {g["key"] for g in st.groups})


class JunkGroupsWithADominantPerson(JunkGroups):
    """The same library, but the first person is 40% of all its faces (all of them good). The rule used to
    compare a group with the mean of every face, which such a person pulls toward themselves until they
    cross the limit and vanish from the list before they are named. It compares with the weak faces instead,
    so they stay, and so does the dog."""
    P0_PER_DAY = 60

    def test_the_premise_a_dominant_person_would_have_been_judged_junk_by_the_mean_of_all_faces(self):
        st = self.ix.state()
        p0 = self.w.ids("p0")
        self.assertGreater(len(p0) / len(self.w.faces), 0.35)
        all_mean = unit(st.base.vecs.mean(axis=0))
        self.assertGreaterEqual(float(unit(np.mean([self.w.vector(f) for f in p0], axis=0)) @ all_mean), people.JUNK_SIM)
        self.assertLess(self.mean_vs_junk_dir(st, p0), 0.2)

    def test_they_and_the_dog_stay_in_the_list_and_the_junk_does_not(self):
        listed = {g["key"] for g in self.ix.state().groups}
        self.assertIn(min(self.w.ids("p0")), listed)
        self.assertIn(min(self.dog), listed)
        self.assertNotIn(min(self.junk), listed)


# ======================================================================= the /m/api routes
H = {"X-Culling-Bay": "1"}


class RoutesCase(unittest.TestCase):
    group_it = True

    def setUp(self):
        self.w = World()
        self.addCleanup(self.w.close)
        if self.group_it:
            self.w.group()
        self.c = self.w.client()

    def key(self, person):
        return min(self.w.ids(person))

    def get(self, url):
        r = self.c.get("/m/api" + url)
        return r.status_code, r.get_json()

    def post(self, url, body=None, headers=H):
        r = self.c.post("/m/api" + url, json={} if body is None else body, headers=headers)
        return r.status_code, r.get_json()

    def name(self, who="Alex", person="alex"):
        status, body = self.post("/people", {"name": who, "group": self.key(person)})
        self.assertEqual(status, 201, body)
        return body


class PeopleReads(RoutesCase):
    def test_before_the_first_grouping_run_it_answers_with_empty_lists(self):
        w = World()
        self.addCleanup(w.close)
        r = w.client().get("/m/api/people")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.get_json(), {"people": [], "groups": [], "faces_checked": 39, "photos_ok": 39})

    def test_a_database_that_has_never_seen_faces_does_too(self):
        w = World(days={})
        self.addCleanup(w.close)
        for t in ("face_groups", "face_groups_meta", "faces_checked", "faces"):
            w.con.execute(f"DROP TABLE {t}")
        w.con.commit()
        r = w.client().get("/m/api/people")
        self.assertEqual((r.status_code, r.get_json()), (200, {"people": [], "groups": [], "faces_checked": 0, "photos_ok": 0}))

    def test_the_list_has_unnamed_groups_then_named_people_most_photos_first(self):
        status, body = self.get("/people")
        self.assertEqual((status, body["people"], len(body["groups"])), (200, [], 3))
        self.assertEqual((body["faces_checked"], body["photos_ok"]), (39, 39))
        self.assertEqual([g["key"] for g in body["groups"]], [self.key("alex"), self.key("sam"), self.key("robin")])
        self.name("Sam", "sam")
        self.name("Alex", "alex")
        body = self.get("/people")[1]
        self.assertEqual([p["name"] for p in body["people"]], ["Alex", "Sam"])        # 18 photos, then 11
        self.assertEqual([g["key"] for g in body["groups"]], [self.key("robin")])
        self.assertEqual(body["people"][0]["photos"], 18)

    def test_at_most_300_groups(self):
        with mock.patch.object(people, "GROUPS_OUT", 2):
            self.assertEqual(len(self.get("/people")[1]["groups"]), 2)

    def test_a_persons_photos_newest_first_with_the_galleries_flags(self):
        p = self.name()
        status, body = self.get(f"/people/{p['id']}")
        self.assertEqual((status, body["id"], body["name"], body["total"]), (200, p["id"], "Alex", 18))
        ids = [x["id"] for x in body["photos"]]
        self.assertEqual(sorted(ids), self.w.photos("alex"))
        self.assertEqual(ids, sorted(ids, reverse=True))                           # capture time rises with the photo id
        self.assertEqual({x["day"] for x in body["photos"]}, {"2026/2026-01-01", "2026/2026-01-02", "2026/2026-01-04"})
        best = self.get(f"/people/{p['id']}?best=1")[1]
        self.assertEqual((best["total"], best["photos"]), (18, []))                # none picked or starred: Best is empty
        self.assertEqual(len(self.get(f"/people/{p['id']}?bursts=0")[1]["photos"]), 18)

    def test_an_unnamed_groups_photos(self):
        status, body = self.get(f"/people/group/{self.key('sam')}")
        self.assertEqual((status, body["key"], body["total"]), (200, self.key("sam"), 11))
        self.assertEqual(sorted(x["id"] for x in body["photos"]), self.w.photos("sam"))

    def test_the_fix_screens_faces_page_by_page(self):
        p = self.name()
        status, body = self.get(f"/people/{p['id']}/faces?limit=5")
        self.assertEqual((status, body["total"], len(body["faces"])), (200, 18, 5))
        self.assertEqual(set(body["faces"][0]), {"id", "photo", "how"})
        rest = self.get(f"/people/{p['id']}/faces?offset=5&limit=500")[1]["faces"]
        self.assertEqual(len(rest), 13)
        self.assertEqual({f["id"] for f in body["faces"]} | {f["id"] for f in rest}, set(self.w.ids("alex")))
        self.assertEqual(len(self.get(f"/people/{p['id']}/faces")[1]["faces"]), 18)
        self.assertEqual(self.get(f"/people/{p['id']}/faces?offset=99")[1], {"total": 18, "faces": []})
        for bad in ("limit=0", "limit=x", "offset=-1", "offset=1.5"):
            self.assertEqual(self.get(f"/people/{p['id']}/faces?{bad}")[0], 400, bad)

    def test_suggestions_when_there_are_none(self):
        p = self.name()
        self.assertEqual(self.get(f"/people/{p['id']}/suggestions"), (200, {"faces": [], "groups": []}))

    def test_the_faces_in_a_photo(self):
        p = self.name()
        face = self.w.ids("alex")[0]
        photo = next(f["photo"] for f in self.w.faces if f["id"] == face)
        status, body = self.get(f"/photo/{photo}/faces")
        self.assertEqual(status, 200)
        (f,) = body["faces"]
        self.assertEqual((f["id"], f["how"], f["person"]), (face, "confirmed", {"id": p["id"], "name": "Alex"}))
        self.assertEqual(f["box"], [0.3, 0.3, 0.5, 0.55])
        other = next(x["photo"] for x in self.w.faces if x["person"] == "robin")
        self.assertEqual(self.get(f"/photo/{other}/faces")[1]["faces"][0]["how"], "none")
        self.assertNotIn("person", self.get(f"/photo/{other}/faces")[1]["faces"][0])
        self.assertEqual(self.get("/photo/99999999/faces")[0], 404)

    def test_unknown_ids_are_404(self):
        for url in ("/people/9999", "/people/group/9999", "/people/9999/faces", "/people/9999/suggestions",
                    "/photo/9999999/faces", "/face/9999999"):
            status, body = self.get(url)
            self.assertEqual(status, 404, url)
            self.assertIn("error", body)


class CountingPC(FakePC):
    """FakePC that counts the photos it was asked to read."""
    loads = 0

    def load_source(self, path):
        CountingPC.loads += 1
        return super().load_source(path)


class FaceCrops(RoutesCase):
    def setUp(self):
        super().setUp()
        CountingPC.loads = 0
        self.c = self.w.client(pc_module=CountingPC())

    def jpeg(self, url):
        from io import BytesIO
        from PIL import Image
        r = self.c.get("/m/api" + url)
        self.assertEqual((r.status_code, r.mimetype), (200, "image/jpeg"), url)
        im = Image.open(BytesIO(r.data))
        return r, im.size

    def test_small_large_and_the_default(self):
        face = self.w.ids("alex")[0]
        self.assertEqual(self.jpeg(f"/face/{face}?s=small")[1], (160, 160))
        self.assertEqual(self.jpeg(f"/face/{face}?s=large")[1], (480, 480))
        self.assertEqual(self.jpeg(f"/face/{face}")[1], (160, 160))
        self.assertEqual(self.jpeg(f"/face/{face}?s=huge")[1], (160, 160))

    def test_it_is_cacheable_like_a_photo(self):
        face = self.w.ids("alex")[0]
        r, _ = self.jpeg(f"/face/{face}")
        self.assertIn("max-age=86400", r.headers["Cache-Control"])
        self.assertTrue(r.headers.get("ETag"))
        again = self.c.get(f"/m/api/face/{face}", headers={"If-None-Match": r.headers["ETag"]})
        self.assertEqual(again.status_code, 304)
        self.assertEqual(self.c.get(f"/m/api/face/{face}", headers={"If-Modified-Since": r.headers["Last-Modified"]}).status_code, 304)

    def test_it_is_cut_from_the_cached_view_and_asking_again_reads_nothing(self):
        face = self.w.ids("alex")[0]
        photo = next(f["photo"] for f in self.w.faces if f["id"] == face)
        self.assertEqual(self.c.get(f"/m/api/img/{photo}?s=view&warm=0").status_code, 200)
        self.assertEqual(CountingPC.loads, 1)
        self.jpeg(f"/face/{face}?s=large")
        self.jpeg(f"/face/{face}?s=small")
        self.jpeg(f"/face/{face}?s=small")
        self.assertEqual(CountingPC.loads, 1)                                      # the view was reused, never read again
        cache = self.w.dir / "cache"
        self.assertEqual(len(list(cache.glob("f-*.jpg"))), 2)                      # a small and a large, kept on disk

    def test_without_a_cached_view_one_is_made_and_no_full_decode_starts(self):
        face = self.w.ids("sam")[0]
        before = {t.name for t in threading.enumerate()}
        self.jpeg(f"/face/{face}")
        self.assertEqual(CountingPC.loads, 1)
        self.assertEqual(len(list((self.w.dir / "cache").glob("m-*.jpg"))), 1)      # the 1616 view, made once
        self.jpeg(f"/face/{self.w.ids('sam')[1]}")                                  # another face, another photo: another view
        self.assertEqual(CountingPC.loads, 2)

    def test_a_photo_that_will_not_decode_is_a_415(self):
        class Broken(CountingPC):
            def load_source(self, path):
                raise OSError("Input/output error")
        c = self.w.client(pc_module=Broken())
        r = c.get(f"/m/api/face/{self.w.ids('alex')[0]}")
        self.assertEqual(r.status_code, 415)
        self.assertIn("error", r.get_json())

    def test_the_square_is_the_box_enlarged_and_kept_inside_the_photo(self):
        import mobile
        self.assertEqual(mobile.face_square((0.4, 0.4, 0.6, 0.6), 1000, 800), (370, 270, 260))   # a 200 px box, 1.3 x, around its centre
        left, top, side = mobile.face_square((0.0, 0.0, 0.1, 0.1), 1000, 800)                     # in the corner: moved in
        self.assertEqual((left, top), (0, 0))
        left, top, side = mobile.face_square((0.9, 0.7, 1.0, 1.0), 1000, 800)
        self.assertEqual((left + side, top + side), (1000, 800))
        self.assertLessEqual(mobile.face_square((0.0, 0.0, 1.0, 1.0), 640, 480)[2], 480)          # never bigger than the photo


class PeopleWrites(RoutesCase):
    def test_writes_need_the_header_and_a_json_object(self):
        for url in ("/people", "/people/1", "/people/1/add", "/people/1/merge", "/people/1/review", "/people/1/delete",
                    "/faces", "/people/group/1/hide"):
            self.assertEqual(self.c.post("/m/api" + url, json={}).status_code, 403, url)
            self.assertEqual(self.c.post("/m/api" + url, data="[1]", headers={**H, "Content-Type": "application/json"}).status_code, 400, url)

    def test_naming_a_group_is_201_with_the_person_and_a_taken_name_is_409(self):
        body = self.name()
        self.assertEqual(set(body), {"id", "name", "photos", "faces", "cover", "suggestions"})
        self.assertEqual((body["name"], body["photos"], body["faces"]), ("Alex", 18, 18))
        status, err = self.post("/people", {"name": "ALEX", "group": self.key("sam")})
        self.assertEqual((status, err["person"]), (409, body))
        self.assertIn("error", err)

    def test_bad_bodies_are_400_and_unknown_things_404(self):
        g = self.key("alex")
        for body, status in [({}, 400), ({"name": "Alex"}, 400), ({"name": "", "group": g}, 400), ({"name": "x" * 81, "group": g}, 400),
                             ({"name": "Alex", "group": "a"}, 400), ({"name": "Alex", "faces": "a"}, 400),
                             ({"name": "Alex", "group": 12345678}, 404), ({"name": "Alex", "faces": [12345678]}, 404)]:
            s, err = self.post("/people", body)
            self.assertEqual(s, status, body)
            self.assertIn("error", err)
        self.assertEqual(self.get("/people")[1]["people"], [])

    def test_rename_cover_add_review_merge_delete(self):
        alex, sam = self.name(), self.name("Sam", "sam")
        status, p = self.post(f"/people/{alex['id']}", {"name": "Alexandra"})
        self.assertEqual((status, p["name"]), (200, "Alexandra"))
        face = self.w.ids("alex")[2]
        self.assertEqual(self.post(f"/people/{alex['id']}", {"cover": face})[1]["cover"], face)
        self.assertEqual(self.post(f"/people/{alex['id']}", {"cover": None})[0], 200)
        self.assertEqual(self.post(f"/people/{alex['id']}", {})[0], 400)
        self.assertEqual(self.post(f"/people/{alex['id']}", {"name": "sam"})[0], 409)
        self.assertEqual(self.post(f"/people/{alex['id']}", {"cover": self.w.ids("sam")[0]})[0], 400)
        self.assertEqual(self.post("/people/9999", {"name": "Z"})[0], 404)
        casey = self.w.ids("casey")[0]
        status, p = self.post(f"/people/{alex['id']}/add", {"faces": [casey]})
        self.assertEqual((status, p["faces"]), (200, 19))
        status, p = self.post(f"/people/{alex['id']}/review", {"yes": [], "no": [casey]})
        self.assertEqual((status, p["faces"]), (200, 18))
        self.assertEqual(self.post(f"/people/{alex['id']}/review", {"yes": ["x"]})[0], 400)
        self.assertEqual(self.post(f"/people/{alex['id']}/add", {})[0], 400)
        status, p = self.post(f"/people/{sam['id']}/merge", {"into": alex["id"]})
        self.assertEqual((status, p["id"], p["faces"]), (200, alex["id"], 29))
        self.assertEqual([x["name"] for x in self.get("/people")[1]["people"]], ["Alexandra"])
        self.assertEqual(self.post(f"/people/{alex['id']}/merge", {"into": alex["id"]})[0], 400)
        self.assertEqual(self.post(f"/people/{alex['id']}/merge", {})[0], 400)
        self.assertEqual(self.post(f"/people/{alex['id']}/merge", {"into": 9999})[0], 404)
        self.assertEqual(self.post(f"/people/{alex['id']}/delete"), (200, {"ok": True}))
        self.assertEqual(self.get("/people")[1]["people"], [])
        self.assertEqual(self.post(f"/people/{alex['id']}/delete")[0], 404)
        self.assertEqual(len(self.get("/people")[1]["groups"]), 3)                  # all back as unnamed groups

    def test_not_move_ignore_and_hide(self):
        alex, sam = self.name(), self.name("Sam", "sam")
        face = self.w.ids("alex")[0]
        status, p = self.post("/faces", {"faces": [face], "action": "not", "person": alex["id"]})
        self.assertEqual((status, p["id"], p["faces"]), (200, alex["id"], 17))
        status, p = self.post("/faces", {"faces": [face], "action": "move", "person": sam["id"]})
        self.assertEqual((status, p["id"], p["faces"]), (200, sam["id"], 12))
        self.assertEqual(self.post("/faces", {"faces": [face], "action": "ignore"}), (200, {"ok": True}))
        self.assertEqual(self.get(f"/people/{sam['id']}")[1]["total"], 11)
        for body, status in [({"faces": [face], "action": "bogus"}, 400), ({"faces": [face], "action": "not"}, 400),
                             ({"faces": [], "action": "ignore"}, 400), ({"action": "ignore"}, 400),
                             ({"faces": [12345678], "action": "ignore"}, 404),
                             ({"faces": [face], "action": "move", "person": 9999}, 404)]:
            self.assertEqual(self.post("/faces", body)[0], status, body)
        self.assertEqual(self.post(f"/people/group/{self.key('robin')}/hide"), (200, {"ok": True}))
        self.assertEqual(self.get("/people")[1]["groups"], [])
        self.assertEqual(self.post("/people/group/9999/hide")[0], 404)

    def test_not_for_a_whole_group(self):
        """"No, that group isn't Alex": the app names the group, not its faces."""
        alex = self.name()
        robin = self.key("robin")
        before = len(self.w.ids("robin"))
        status, p = self.post("/faces", {"group": robin, "action": "not", "person": alex["id"]})
        self.assertEqual((status, p["id"]), (200, alex["id"]))
        con = self.w.anno()
        self.assertEqual(con.execute("SELECT COUNT(*) FROM face_no WHERE person_id=?", (alex["id"],)).fetchone()[0], before)
        group = next(g for g in self.get("/people")[1]["groups"] if g["key"] == robin)
        self.assertNotIn("maybe", group)
        self.assertEqual(self.post("/faces", {"group": 9999, "action": "not", "person": alex["id"]})[0], 404)
        self.assertEqual(self.post("/faces", {"group": "x", "action": "not", "person": alex["id"]})[0], 400)

    def test_the_labels_land_in_annotations_db(self):
        self.name()
        con = self.w.anno()
        self.assertEqual(con.execute("SELECT COUNT(*) FROM face_yes").fetchone()[0], 18)
        self.assertEqual(con.execute("SELECT name FROM people").fetchone()[0], "Alex")
        con.close()


# ======================================================================= search by name
class PeopleSearch(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import mobile
        import search
        cls.w = w = World()
        # photos with two people in them, and captions to search for
        cls.both = [w.together("2026/2026-01-01", ["alex", "sam"], caption="two at a table")[0],
                    w.together("2026/2026-01-03", ["sam", "alex"], caption="two on a bench")[0]]
        for f in w.ids("alex", "2026/2026-01-01")[:2] + w.ids("sam", "2026/2026-01-03")[:1] + w.ids("robin", "2026/2026-01-02")[:1]:
            w.con.execute("UPDATE images SET caption='a birthday cake' WHERE path=(SELECT path FROM faces WHERE id=?)", (f,))
        w.con.commit()
        w.group()
        cls.ix = ix = w.index()
        cls.alex = ix.create("Alex Smith", group=min(w.ids("alex")))[0]
        cls.sam = ix.create("Sam Jones", group=min(w.ids("sam")))[0]
        cls.make = staticmethod(lambda people_fn: search.Search(
            db_ro=w.db_ro, pc=FakePC(), day_of=mobile.day_of, day_date=mobile.day_date, ollama_url="http://127.0.0.1:9",
            library_root=mobile.LIBRARY_ROOT, embed=lambda t: [1.0], people=people_fn))
        cls.s = cls.make(ix.name_photos)

    @classmethod
    def tearDownClass(cls):
        cls.w.close()

    def ids(self, q, s=None):
        r = (s or self.s).photos(q)
        return r["ids"], r

    def alex_photos(self):
        return set(self.w.photos("alex")) | set(self.both)

    def sam_photos(self):
        return set(self.w.photos("sam")) | set(self.both)

    def test_a_full_name_in_any_case(self):
        for q in ("Alex Smith", "alex smith", "ALEX SMITH", "  alex   smith ", "alex,  smith"):
            ids, r = self.ids(q)
            self.assertEqual(set(ids), self.alex_photos(), q)
            self.assertEqual((r["total"], r["signals"], r["notes"]), (len(ids), ["people"], []))

    def test_newest_first(self):
        ids, _ = self.ids("alex smith")
        days = {p["id"]: p["day"] for p in self.photos_info(ids)}
        order = [(days[i].rsplit("/", 1)[-1], i) for i in ids]
        self.assertEqual(order, sorted(order, reverse=True))

    def photos_info(self, ids):
        import mobile
        con = self.w.db_ro()
        try:
            return [{"id": r["rowid"], "day": mobile.day_of(r["path"])} for r in con.execute(
                f"SELECT rowid, path FROM images WHERE rowid IN ({','.join('?' * len(ids))})", ids)]
        finally:
            con.close()

    def test_a_name_alone_lists_every_photo_not_just_the_top_ranked(self):
        ids = self.s.photos("alex", limit=2)["ids"]
        self.assertGreater(len(self.alex_photos()), 2)
        self.assertEqual(set(ids), self.alex_photos())
        # a search of dates alone, or of a name with words, keeps the cap
        self.assertEqual(len(self.s.photos("2026", limit=2)["ids"]), 2)

    def test_a_first_name_nobody_else_has(self):
        self.assertEqual(set(self.ids("alex")[0]), self.alex_photos())
        self.assertEqual(set(self.ids("SAM")[0]), self.sam_photos())

    def test_a_first_name_two_people_share_means_nothing_but_whole_names_still_work(self):
        ix = self.ix
        brown, _ = ix.create("Alex Brown", group=min(self.w.ids("robin")))
        try:
            self.assertEqual(self.ids("alex")[0], [])                             # a word now, and no caption has it
            self.assertEqual(self.ids("alex")[1]["signals"], [])
            self.assertEqual(set(self.ids("alex smith")[0]), self.alex_photos())
            self.assertEqual(set(self.ids("alex brown")[0]), set(self.w.photos("robin")))
        finally:
            ix.delete(brown)

    def test_two_people_together_are_and(self):
        for q in ("alex sam", "sam alex", "Alex Smith Sam Jones", "alex smith and sam", "photos of alex and sam"):
            ids, r = self.ids(q)
            self.assertEqual(set(ids), set(self.both), q)
            self.assertEqual(r["signals"], ["people"])

    def test_a_name_and_a_date(self):
        ids, r = self.ids("alex 2026-01-02")
        self.assertEqual(set(ids), set(self.w.photos("alex", "2026/2026-01-02")))
        self.assertEqual(r["signals"], ["people", "dates"])
        self.assertEqual(self.ids("alex 2025")[0], [])                            # no photo of hers from 2025
        self.assertEqual(set(self.ids("alex smith 2026-01")[0]), self.alex_photos())

    def test_a_name_and_words_search_among_their_photos_only(self):
        ids, r = self.ids("alex birthday")
        first_two = set(self.w.ids("alex", "2026/2026-01-01")[:2])
        self.assertEqual(set(ids), {f["photo"] for f in self.w.faces if f["id"] in first_two})
        self.assertEqual(r["signals"], ["people", "words"])
        everyone = self.ids("birthday")[0]
        self.assertEqual(len(everyone), 4)                                        # without a name: Sam's and Robin's too
        self.assertLess(set(ids), set(everyone))
        self.assertEqual(self.ids("birthday")[1]["signals"], ["words"])

    def test_the_names_are_not_searched_for_as_words(self):
        # no caption says "alex": the name picks the person, it is not also a word that must match
        self.assertEqual(len(self.ids("alex cake")[0]), 2)

    def test_unnamed_people_and_other_words_search_as_before(self):
        self.assertEqual(self.ids("robin")[0], [])
        self.assertEqual(len(self.ids("two at a table")[0]), 1)

    def test_a_people_provider_that_fails_leaves_the_search_working(self):
        broken = self.make(lambda: 1 / 0)
        ids, r = self.ids("birthday", broken)
        self.assertEqual(len(ids), 4)
        self.assertEqual(r["signals"], ["words"])

    def test_no_provider_is_the_old_search(self):
        ids, r = self.ids("birthday", self.make(None))
        self.assertEqual((len(ids), r["signals"]), (4, ["words"]))

    def test_the_gallery_route_finds_a_person(self):
        c = self.w.client()
        body = c.get("/m/api/gallery/search?q=alex+smith&bursts=0").get_json()
        self.assertEqual(body["signals"], ["people"])
        self.assertEqual(body["total"], len(self.alex_photos()))
        self.assertEqual({p["id"] for p in body["photos"]}, self.alex_photos())
        both = c.get("/m/api/gallery/search?q=alex+sam&bursts=0").get_json()
        self.assertEqual({p["id"] for p in both["photos"]}, set(self.both))
        # the name was just given: the next search sees a rename at once
        c.post("/m/api/people/%d" % self.alex, json={"name": "Alexa Smith"}, headers=H)
        try:
            self.assertEqual(c.get("/m/api/gallery/search?q=alexa").get_json()["total"], len(self.alex_photos()))
        finally:
            c.post("/m/api/people/%d" % self.alex, json={"name": "Alex Smith"}, headers=H)


if __name__ == "__main__":
    unittest.main()
