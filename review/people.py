"""People for Culling Bay: who is in which photo, from three layers (design: review/PEOPLE.md).

    faces         trial.db `faces`: each face's box, quality and 512-d vector (photo_cull.py faces)
    face groups   trial.db `face_groups`: label-blind clusters of every face (photo_cull.py faces-group)
    labels        annotations.db `people`, `face_yes`, `face_no`, `face_ignored`: only what Danny said

PeopleIndex reads all three and answers, for every face, which person it is, which it might be, or
which unnamed group it sits in. It also owns the label writes (the routes in mobile.py are thin), so
the labels and the index never disagree. No Flask in here: the pure functions work on numpy arrays
and label sets, and review/tests/test_people.py runs them without a server.

Rules, in order, for one face (thresholds are measured: see PEOPLE.md):
  1. ignored                 nobody, hidden everywhere
  2. face_yes                that person ("confirmed")
  3. the group rule          2/3 or more of the confirmed faces in its group are one person P
  4. the similarity rule     s_P >= AUTO_SIM, and AUTO_MARGIN ahead of the next person ("auto")
  5. a suggestion            SUGGEST_SIM <= s_P < AUTO_SIM
  6. otherwise               a member of its (unnamed) group, if it has one
face_no (this face is not P) takes P out of 3, 4, 5 and the runner-up check for that face.

The index is built once from trial.db and rebuilt when the grouping run changes (checked at most every
REFRESH_S; faces arriving between runs do not trigger it). A label change recomputes only the score
arrays of the people whose confirmed faces changed. Readers take one immutable State and use it for a
whole request; writers are serialised.
"""
from __future__ import annotations

import collections
import logging
import os
import sqlite3
import threading
import time
from datetime import datetime

import numpy as np

log = logging.getLogger(__name__)

AUTO_SIM = 0.55          # s_P at least this, and a clear lead: the face is filed under P
AUTO_MARGIN = 0.10       # ... the lead over the next best person
SUGGEST_SIM = 0.40       # s_P from here up to AUTO_SIM: "Is this P?"
GROUP_SHARE = 2 / 3      # the group rule: this share of a group's confirmed faces are one person
TOP_K = 3                # s_P is the mean of the top 3 similarities to P's confirmed faces ...
MAX_CONFIRMED = 300      # ... out of at most this many, a fixed spread by face id
MIN_UNNAMED = 3          # an unnamed group has at least this many unassigned faces
MAYBE_SIM = 0.40         # a group "may be" a person whose mean is this alike
MIN_GOOD = 2             # an unnamed group is worth listing only with this many good unclaimed faces ...
# ... and only if its mean is under JUNK_SIM alike to the "junk direction": the unit mean of the faces the
# detector is unsure of (score under JUNK_SCORE), which are mostly a car wheel, the backs of heads, hats and
# blur. It is used only when there are JUNK_MIN_LOW such faces to average; otherwise only MIN_GOOD applies.
# Measured on 12.8k real faces, against that mean: the junk group 0.83, another junk-ish group (8 faces, 25%
# good) 0.66, every real person -0.02 to 0.12 (the most photographed 0.05), a dog 0.30 (it should stay: it may
# get a name), a group of 32 faces with 9% good 0.35. Not the mean of ALL faces: that is pulled toward whoever
# is photographed most. The most photographed person (917 faces, 88% good) sat 0.43 from it, and as the
# library grows their share would take them past the limit and out of the list before they were named.
JUNK_SCORE = 0.6
JUNK_MIN_LOW = 50
JUNK_SIM = 0.5
GROUPS_OUT = 300         # unnamed groups in the list
SUGGESTIONS_OUT = 60     # suggested faces for one person
FACES_PAGE = 100         # faces per page on the fix screen, unless asked for more
FACES_PAGE_MAX = 500
NAME_MAX = 80
REFRESH_S = 30           # how often the grouping run's stamp is looked at
EMPTY = np.zeros(0, np.int64)

SCHEMA = """
CREATE TABLE IF NOT EXISTS people(
  id          INTEGER PRIMARY KEY AUTOINCREMENT,   -- never reused, so a deleted person's id can't come back
  name        TEXT NOT NULL,
  cover_face  INTEGER,                 -- faces.id Danny chose; NULL = the best confirmed face
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS people_name ON people(name COLLATE NOCASE);
CREATE TABLE IF NOT EXISTS face_yes(       -- this face IS this person
  face_id     INTEGER PRIMARY KEY,
  person_id   INTEGER NOT NULL,
  how         TEXT NOT NULL,           -- named | added | confirmed | moved
  at          TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS face_yes_person ON face_yes(person_id);
CREATE TABLE IF NOT EXISTS face_no(        -- this face is NOT this person (never suggest it again)
  face_id     INTEGER NOT NULL,
  person_id   INTEGER NOT NULL,
  at          TEXT NOT NULL,
  PRIMARY KEY (face_id, person_id));
CREATE TABLE IF NOT EXISTS face_ignored(   -- not a face, or a stranger: hidden everywhere
  face_id     INTEGER PRIMARY KEY,
  at          TEXT NOT NULL);
"""

HOW = {0: "none", 1: "confirmed", 2: "auto"}


class PeopleError(Exception):
    """A request the routes answer with `status` and the JSON `body`."""

    def __init__(self, status: int, error: str, **more):
        super().__init__(error)
        self.status, self.body = status, {"error": error, **more}


def now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


# ------------------------------------------------------------------ pure functions over arrays
def spread(m: int, cap: int = MAX_CONFIRMED) -> np.ndarray:
    """Positions of a fixed, even spread of at most `cap` out of m faces listed by id."""
    if m <= cap:
        return np.arange(m)
    return np.linspace(0, m - 1, cap).round().astype(np.int64)


def person_score(vecs: np.ndarray, confirmed: np.ndarray, chunk: int = 8192) -> np.ndarray:
    """s_P for every face: the mean of its top TOP_K cosine similarities to the person's confirmed faces
    (rows of `vecs` listed in `confirmed`, in face-id order; a fixed spread of MAX_CONFIRMED if more).
    With fewer than TOP_K confirmed faces, the mean of all of them. float32, one per face."""
    ref = vecs[confirmed[spread(len(confirmed))]]
    m = len(ref)
    k = min(TOP_K, m)
    out = np.empty(len(vecs), np.float32)
    for a in range(0, len(vecs), chunk):
        sims = vecs[a:a + chunk] @ ref.T
        top = np.partition(sims, m - k, axis=1)[:, m - k:] if m > k else sims
        out[a:a + chunk] = top.mean(axis=1)
    return out


class Resolution:
    """Who each face is. pid: the person's id or -1; how: 0 nobody, 1 confirmed, 2 auto; sug / sug_sim: the
    person it might be (or -1) and s_P, for faces with a suggestion."""

    def __init__(self, n: int):
        self.pid = np.full(n, -1, np.int64)
        self.how = np.zeros(n, np.int8)
        self.sug = np.full(n, -1, np.int64)
        self.sug_sim = np.zeros(n, np.float32)


def resolve(grp: np.ndarray, ignored: np.ndarray, yes: np.ndarray, scores: dict[int, np.ndarray],
            no: dict[int, np.ndarray]) -> Resolution:
    """Apply the rules in the module docstring to every face.
    grp: group key per face, -1 for none. ignored: bool per face. yes: the person each face is confirmed
    as, -1 for none (a confirmed face that is also ignored counts as nothing). scores: person id -> s_P
    per face, for each person with confirmed faces. no: person id -> the faces that are not that person."""
    n = len(grp)
    res = Resolution(n)
    confirmed = (yes >= 0) & ~ignored
    res.pid[confirmed] = yes[confirmed]
    res.how[confirmed] = 1

    # 3. the group rule: the people the confirmed faces of each group belong to
    if n and (confirmed & (grp >= 0)).any():
        by_group = collections.defaultdict(collections.Counter)
        for g, p in zip(grp[confirmed & (grp >= 0)].tolist(), yes[confirmed & (grp >= 0)].tolist()):
            by_group[g][p] += 1
        order = np.argsort(grp, kind="stable")
        sorted_grp = grp[order]
        for g, counts in by_group.items():
            person, count = counts.most_common(1)[0]
            if count < GROUP_SHARE * sum(counts.values()):
                continue
            members = order[np.searchsorted(sorted_grp, g, "left"):np.searchsorted(sorted_grp, g, "right")]
            members = members[(res.pid[members] < 0) & ~ignored[members]]
            if person in no:
                members = members[~np.isin(members, no[person])]
            res.pid[members] = person
            res.how[members] = 2

    # 4 and 5. the similarity rule and suggestions, for the faces still nobody's
    rest = np.flatnonzero((res.pid < 0) & ~ignored)
    people = sorted(scores)
    if len(rest) and people:
        s = np.stack([scores[p][rest] for p in people])             # (people, faces)
        if any(p in no for p in people):
            where = {f: j for j, f in enumerate(rest.tolist())}
            for j, p in enumerate(people):
                if p in no:
                    hit = no[p][np.isin(no[p], rest)]
                    s[j, [where[f] for f in hit.tolist()]] = -np.inf  # face_no: P is out for that face
        cols = np.arange(len(rest))
        best = s.argmax(axis=0)
        best_s = s[best, cols]
        s[best, cols] = -np.inf
        with np.errstate(invalid="ignore"):                         # -inf minus -inf: nobody left, so no lead
            lead = best_s - s.max(axis=0)                           # over the runner-up (inf when alone)
        who = np.array(people, np.int64)[best]
        auto = (best_s >= AUTO_SIM) & (lead >= AUTO_MARGIN)
        res.pid[rest[auto]] = who[auto]
        res.how[rest[auto]] = 2
        sug = (best_s >= SUGGEST_SIM) & (best_s < AUTO_SIM)
        res.sug[rest[sug]] = who[sug]
        res.sug_sim[rest[sug]] = best_s[sug]
    return res


# ------------------------------------------------------------------ what is loaded
class Base:
    """The faces as trial.db held them at the last grouping run, in face-id order. Never changed after
    it is built, so States made from it share it."""

    def __init__(self, ids, photo, folder, grp, ts, box, quality, vecs, key, good=None, score=None):
        """good: which faces are good (detector score and sharpness, as faces-group counts them); all of them
        if not given. score: each face's detector score. junk_dir: the unit mean of the vectors of the faces
        scoring under JUNK_SCORE, the direction junk shares; None unless there are JUNK_MIN_LOW of them (or no
        scores were given), and then no group is judged by it."""
        self.ids, self.photo, self.folder, self.grp, self.ts = ids, photo, folder, grp, ts
        self.box, self.quality, self.vecs, self.key = box, quality, vecs, key
        self.good = np.ones(len(ids), bool) if good is None else good
        self.junk_dir = None
        low = np.zeros(len(ids), bool) if score is None else score < JUNK_SCORE      # a missing score (NaN) is not low
        if low.sum() >= JUNK_MIN_LOW:
            mean = vecs[low].mean(axis=0, dtype=np.float64)
            if np.linalg.norm(mean) > 0:
                self.junk_dir = (mean / np.linalg.norm(mean)).astype(np.float32)
        self.idx_of = {f: i for i, f in enumerate(ids.tolist())}
        by_photo = collections.defaultdict(list)
        for i, p in enumerate(photo.tolist()):
            by_photo[p].append(i)
        self.photo_faces = dict(by_photo)
        order = np.argsort(grp, kind="stable")
        sorted_grp = grp[order]
        first = np.searchsorted(sorted_grp, 0, "left")             # skip the faces in no group (-1)
        keys, starts = np.unique(sorted_grp[first:], return_index=True)
        ends = np.append(starts[1:], len(sorted_grp) - first)
        self.group_faces = {int(k): order[first + a:first + b] for k, a, b in zip(keys, starts, ends)}

    @classmethod
    def empty(cls, key=None):
        z = np.zeros(0, np.int64)
        return cls(z, z, z, z, np.zeros(0), np.zeros((0, 4), np.float32), np.zeros(0, np.float32),
                   np.zeros((0, 512), np.float32), key)


class Labels:
    """The four label tables, read together."""

    def __init__(self, people, yes, no, ignored):
        self.people = people          # id -> {name, cover_face, created_at, updated_at}
        self.yes = yes                # [(face_id, person_id, how)]
        self.no = no                  # [(face_id, person_id)]
        self.ignored = ignored        # [face_id]


class State:
    """One consistent answer to "who is who", derived from a Base and a set of labels."""

    def __init__(self, base: Base, labels: Labels, conf, scores, res: Resolution, yes, ignored, no):
        self.base, self.labels, self.conf, self.scores, self.res = base, labels, conf, scores, res
        self.yes, self.ignored, self.no = yes, ignored, no
        self.people = labels.people
        self._names = None
        self._derive()

    def _derive(self):
        b, res = self.base, self.res
        self.faces = {}               # person id -> faces filed under them (confirmed and auto)
        self.photo_count = {}
        self.suggested = {}           # person id -> suggested faces, most alike first
        self.cover = {}
        for p, row in self.people.items():
            f = np.flatnonzero(res.pid == p)
            self.faces[p] = f
            self.photo_count[p] = len(np.unique(b.photo[f]))
            sg = np.flatnonzero(res.sug == p)
            self.suggested[p] = sg[np.argsort(-res.sug_sim[sg], kind="stable")]
            pool = self.conf.get(p, EMPTY)
            if len(pool) == 0:
                pool = f
            chosen = row["cover_face"]
            own = b.idx_of.get(chosen) if chosen is not None else None
            if own is not None and res.pid[own] == p:
                self.cover[p] = int(chosen)
            else:
                self.cover[p] = int(b.ids[pool[np.argmax(b.quality[pool])]]) if len(pool) else None
        self._groups()

    def _groups(self):
        """The unnamed groups: those with MIN_UNNAMED or more faces nobody has claimed (a suggested face is
        unclaimed), each with the person its mean most resembles, if any. A group that is probably not a person
        is left out of the list: under MIN_GOOD good unclaimed faces, or a mean JUNK_SIM alike to the junk direction.
        Its faces stay unclaimed (they can still be suggested or filed one by one, and `unassigned` has it).
        The list is ordered by the days the group has a good face on, then its good faces, then its key."""
        b, res = self.base, self.res
        free = (res.pid < 0) & ~self.ignored & (b.grp >= 0)
        self.unassigned = {}          # group key -> its unclaimed faces
        idx = np.flatnonzero(free)
        if len(idx):
            order = idx[np.argsort(b.grp[idx], kind="stable")]
            for part in np.split(order, np.flatnonzero(np.diff(b.grp[order])) + 1):
                self.unassigned[int(b.grp[part[0]])] = part
        means = {}
        for p, c in self.conf.items():
            m = b.vecs[c].mean(axis=0)
            means[p] = m / (np.linalg.norm(m) or 1.0)
        no_of_face = collections.defaultdict(list)    # face index -> the people it is not
        for p, f in self.no.items():
            for i in f.tolist():
                no_of_face[i].append(p)
        groups = []
        for key, part in self.unassigned.items():
            if len(part) < MIN_UNNAMED:
                continue
            good = part[b.good[part]]
            m = b.vecs[part].mean(axis=0)
            m /= np.linalg.norm(m) or 1.0
            if len(good) < MIN_GOOD or (b.junk_dir is not None and float(m @ b.junk_dir) >= JUNK_SIM):
                continue
            g = {"key": key, "faces": len(part), "photos": len(np.unique(b.photo[part])),
                 "days": len(np.unique(b.folder[part])), "cover": int(b.ids[part[np.argmax(b.quality[part])]])}
            if means:
                refused = collections.Counter(p for i in part.tolist() for p in no_of_face.get(i, ())) \
                    if no_of_face else collections.Counter()
                best = max(((float(m @ v), p) for p, v in means.items() if 2 * refused[p] < len(part)),
                           default=(-1.0, None))
                if best[0] >= MAYBE_SIM:
                    g["maybe"] = {"id": best[1], "name": self.people[best[1]]["name"]}
            groups.append(((-len(np.unique(b.folder[good])), -len(good), key), g))
        groups.sort(key=lambda t: t[0])       # good days first: friends and family over a one-day crowd
        self.groups = [g for _, g in groups]

    def name_sets(self) -> dict[str, frozenset]:
        """{lower-case name: the ids of the photos that person is in}, for the search."""
        if self._names is None:
            out: dict[str, set] = {}
            for p, row in self.people.items():
                out.setdefault(row["name"].lower(), set()).update(self.base.photo[self.faces[p]].tolist())
            self._names = {k: frozenset(v) for k, v in out.items()}
        return self._names


def compute(base: Base, labels: Labels, prev: State | None = None) -> State:
    """The State for these faces and labels. Only the people whose confirmed faces differ from `prev`'s
    (a State over the same Base) get their score arrays recomputed."""
    n = len(base.ids)
    idx_of = base.idx_of
    yes = np.full(n, -1, np.int64)
    for fid, p, _ in labels.yes:
        i = idx_of.get(fid)
        if i is not None and p in labels.people:
            yes[i] = p
    ignored = np.zeros(n, bool)
    for fid in labels.ignored:
        i = idx_of.get(fid)
        if i is not None:
            ignored[i] = True
    no: dict[int, list] = collections.defaultdict(list)
    for fid, p in labels.no:
        i = idx_of.get(fid)
        if i is not None and p in labels.people:
            no[p].append(i)
    no_arrays = {p: np.array(sorted(v), np.int64) for p, v in no.items()}
    counted = np.flatnonzero((yes >= 0) & ~ignored)
    conf = {p: counted[yes[counted] == p] for p in np.unique(yes[counted]).tolist()}   # index order is id order
    scores = {}
    for p, c in conf.items():
        if prev is not None and prev.base is base and p in prev.conf and np.array_equal(prev.conf[p], c):
            scores[p] = prev.scores[p]
        else:
            scores[p] = person_score(base.vecs, c)
    res = resolve(base.grp, ignored, yes, scores, no_arrays)
    return State(base, labels, conf, scores, res, yes, ignored, no_arrays)


def newest_first(base: Base, faces: np.ndarray) -> list[int]:
    """The distinct photo ids of these faces, newest capture first."""
    photos, first = np.unique(base.photo[faces], return_index=True)
    ts = base.ts[faces][first]
    return photos[np.lexsort((-photos, -ts))].tolist()


# ------------------------------------------------------------------ the index
def _int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


class PeopleIndex:
    def __init__(self, *, db_ro, anno, pc, refresh_s: float = REFRESH_S):
        """db_ro() / anno(): connections to trial.db (read-only) and annotations.db. pc: photo_cull (the
        face version and the vector format). refresh_s: how often the grouping run's stamp is looked at."""
        self.db_ro, self.anno, self.pc, self.refresh_s = db_ro, anno, pc, refresh_s
        self.lock = threading.Lock()      # guards the fields below; never held while loading or computing
        self.wlock = threading.RLock()    # one label write at a time, and the swap of a rebuilt index
        self._state: State | None = None
        self._checked = 0.0
        self._building: threading.Event | None = None
        self._error: BaseException | None = None
        self._version = 0                 # bumped by every label write, so a rebuild can tell one slipped in
        self._schema = False

    # ---------------------------------------------------------------- loading
    def _stamp(self, con) -> str | None:
        """The grouping run's computed_at, or None before the first run."""
        try:
            row = con.execute("SELECT v FROM face_groups_meta WHERE k='computed_at'").fetchone()
        except sqlite3.OperationalError:     # faces-group has never run: the tables aren't there
            return None
        return row[0] if row else None

    def _load_base(self, key: str | None) -> Base:
        con = self.db_ro()
        try:
            try:
                total = con.execute("SELECT COUNT(*) FROM face_groups").fetchone()[0]
            except sqlite3.OperationalError:
                return Base.empty(key)
            vecs = np.zeros((total + 1024, 512), np.float32)
            cols = {k: [] for k in ("ids", "photo", "folder", "grp", "ts", "box", "quality", "good", "score")}
            folders: dict[str, int] = {}
            n = 0
            for r in con.execute(
                    "SELECT f.id, i.rowid, f.path, g.grp, i.capture_ts, f.x0, f.y0, f.x1, f.y1, f.score, f.sharp, "
                    "f.box_px, f.vector FROM face_groups g JOIN faces f ON f.id = g.face_id "
                    "JOIN images i ON i.path = f.path WHERE f.face_version = ? AND i.status = 'ok' ORDER BY f.id",
                    (self.pc.FACE_VERSION,)):
                blob = r[12]
                if blob is None or len(blob) != 512 * 4:
                    continue
                if n == len(vecs):
                    vecs = np.concatenate([vecs, np.zeros_like(vecs)])
                vecs[n] = self.pc.unpack_vector(blob)
                cols["ids"].append(r[0])
                cols["photo"].append(r[1])
                cols["folder"].append(folders.setdefault(os.path.dirname(r[2]), len(folders)))
                cols["grp"].append(-1 if r[3] is None else r[3])
                cols["ts"].append(r[4] or 0.0)
                cols["box"].append([r[5], r[6], r[7], r[8]])
                # a cover wants a big, sharp, surely-a-face: each factor capped so none runs away
                cols["quality"].append((r[9] or 0.0) * min(r[11] or 0.0, 400.0) / 400.0 * min(r[10] or 0.0, 200.0) / 200.0)
                cols["score"].append(np.nan if r[9] is None else r[9])
                cols["good"].append((r[9] or 0.0) >= self.pc.FACE_GOOD_SCORE and (r[10] or 0.0) >= self.pc.FACE_GOOD_SHARP)
                n += 1
        finally:
            con.close()
        return Base(np.array(cols["ids"], np.int64), np.array(cols["photo"], np.int64),
                    np.array(cols["folder"], np.int64), np.array(cols["grp"], np.int64),
                    np.array(cols["ts"], np.float64), np.array(cols["box"], np.float32).reshape(-1, 4),
                    np.array(cols["quality"], np.float32), vecs[:n], key, np.array(cols["good"], bool),
                    np.array(cols["score"], np.float64))

    def _connect(self) -> sqlite3.Connection:
        con = self.anno()
        if not self._schema:
            try:
                con.executescript(SCHEMA)
            except Exception:
                con.close()
                raise
            self._schema = True
        return con

    def _read_labels(self) -> Labels:
        con = self._connect()
        try:
            people = {r[0]: {"name": r[1], "cover_face": r[2], "created_at": r[3], "updated_at": r[4]}
                      for r in con.execute("SELECT id, name, cover_face, created_at, updated_at FROM people")}
            return Labels(
                people,
                [tuple(r) for r in con.execute("SELECT face_id, person_id, how FROM face_yes")],
                [tuple(r) for r in con.execute("SELECT face_id, person_id FROM face_no")],
                [r[0] for r in con.execute("SELECT face_id FROM face_ignored")])
        finally:
            con.close()

    # ---------------------------------------------------------------- the current state
    def state(self) -> State:
        """The State to answer with. Looks for a new grouping run at most every refresh_s. One thread at a
        time checks and rebuilds, outside the lock; the others go on with the old State, or wait when there
        is none yet. A failed rebuild keeps the old State (and logs why); with none, it raises."""
        while True:
            with self.lock:
                if self._state is not None and time.time() - self._checked < self.refresh_s:
                    return self._state
                running = self._building
                if running is None:
                    self._building = mine = threading.Event()
                    break
                if self._state is not None:
                    return self._state
            running.wait()
            with self.lock:
                if self._state is not None:
                    return self._state
                if self._error is not None:
                    raise self._error
        err = None
        try:
            self._refresh()
        except BaseException as e:  # noqa: BLE001 - even an interrupt must let the waiting threads go
            err = e
        with self.lock:
            now = time.time()
            if err is None:
                self._checked, self._error = now, None
            else:
                self._error = err
                if self._state is not None:
                    self._checked = now         # try again after refresh_s, not on every request
            self._building = None
            st = self._state
        mine.set()
        if err is not None:
            if st is None or not isinstance(err, Exception):
                raise err
            log.warning("people index not rebuilt, keeping the old one: %s: %s", type(err).__name__, err)
        return st

    def _refresh(self) -> None:
        con = self.db_ro()
        try:
            key = self._stamp(con)
        finally:
            con.close()
        with self.lock:
            cur = self._state
        if cur is not None and cur.base.key == key:
            return
        base = self._load_base(key)
        st = None
        while True:      # labels may change while the faces load or the scores compute: look again if one did
            version = self._version
            st = compute(base, self._read_labels(), prev=st)
            with self.wlock:
                if version == self._version:
                    with self.lock:
                        self._state = st
                    return

    def warm(self) -> None:
        """Build the first State now (the server does it in the background), not on the first request."""
        try:
            self.state()
        except Exception:  # noqa: BLE001 - a request will try again, and report what is wrong
            log.warning("people index warm-up failed", exc_info=True)

    def coverage(self) -> tuple[int, int]:
        """(photos checked for faces, photos that are ok): how far the faces step has got."""
        con = self.db_ro()
        try:
            checked = con.execute(
                "SELECT COUNT(*) FROM faces_checked c JOIN images i ON i.path = c.path "
                "WHERE c.face_version = ? AND i.status = 'ok'", (self.pc.FACE_VERSION,)).fetchone()[0]
            return checked, con.execute("SELECT COUNT(*) FROM images WHERE status = 'ok'").fetchone()[0]
        except sqlite3.OperationalError:
            return 0, 0
        finally:
            con.close()

    def name_photos(self) -> dict[str, frozenset]:
        """The search's people provider: {lower-case name: photo ids}."""
        return self.state().name_sets()

    # ---------------------------------------------------------------- reads, as the API's JSON
    def person_json(self, st: State, pid: int) -> dict:
        return {"id": pid, "name": st.people[pid]["name"], "photos": st.photo_count[pid],
                "faces": len(st.faces[pid]), "cover": st.cover[pid], "suggestions": len(st.suggested[pid])}

    def people_json(self, st: State) -> list[dict]:
        """Everyone named, most photos first."""
        out = [self.person_json(st, p) for p in st.people]
        out.sort(key=lambda d: (-d["photos"], d["name"].lower(), d["id"]))
        return out

    def photos_of(self, st: State, pid: int) -> list[int]:
        return newest_first(st.base, st.faces[pid])

    def group_photos(self, st: State, key: int) -> list[int]:
        return newest_first(st.base, st.unassigned.get(key, EMPTY))

    def faces_of(self, st: State, pid: int, offset: int, limit: int) -> dict:
        """The faces filed under a person, for the fix screen: the ones the server filed itself, least sure
        first (the likeliest mistakes), then the ones Danny confirmed, newest photo first."""
        b, res = st.base, st.res
        f = st.faces[pid]
        auto = f[res.how[f] == 2]
        auto = auto[np.argsort(st.scores[pid][auto], kind="stable")] if len(auto) else auto
        sure = f[res.how[f] == 1]
        sure = sure[np.lexsort((-b.ids[sure], -b.ts[sure]))]
        order = np.concatenate([auto, sure])
        page = order[offset:offset + limit]
        return {"total": len(order), "faces": [
            {"id": int(b.ids[i]), "photo": int(b.photo[i]), "how": HOW[int(res.how[i])]} for i in page]}

    def suggestions_of(self, st: State, pid: int) -> dict:
        b = st.base
        return {"faces": [{"id": int(b.ids[i]), "photo": int(b.photo[i]), "sim": round(float(st.res.sug_sim[i]), 3)}
                          for i in st.suggested[pid][:SUGGESTIONS_OUT]],
                "groups": [g for g in st.groups if g.get("maybe", {}).get("id") == pid]}

    def photo_faces(self, st: State, photo: int) -> list[dict]:
        """The faces in one photo, left to right, with who each is. Ignored faces are left out."""
        b, res = st.base, st.res
        out = []
        for i in sorted(b.photo_faces.get(photo, ()), key=lambda i: b.box[i][0]):
            if st.ignored[i]:
                continue
            d = {"id": int(b.ids[i]), "box": [round(float(v), 5) for v in b.box[i]], "how": HOW[int(res.how[i])]}
            if res.pid[i] >= 0:
                d["person"] = {"id": int(res.pid[i]), "name": st.people[int(res.pid[i])]["name"]}
            elif res.sug[i] >= 0:
                d["suggestion"] = {"id": int(res.sug[i]), "name": st.people[int(res.sug[i])]["name"]}
            out.append(d)
        return out

    # ---------------------------------------------------------------- label writes
    def _need_person(self, st: State, pid) -> int:
        if pid not in st.people:
            raise PeopleError(404, "no such person")
        return pid

    def _need_faces(self, st: State, faces) -> list[int]:
        """Face indices for a list of face ids; 400 for something that isn't a list of ints, 404 for a face
        the index doesn't know."""
        if not isinstance(faces, list) or not all(_int(f) for f in faces):
            raise PeopleError(400, "faces must be a list of face ids")
        out = []
        for f in dict.fromkeys(faces):
            i = st.base.idx_of.get(f)
            if i is None:
                raise PeopleError(404, "no such face", face=f)
            out.append(i)
        return out

    def _group_faces(self, st: State, key) -> list[int]:
        """The faces of an unnamed group still unclaimed (what the app shows as the group)."""
        if key not in st.base.group_faces:
            raise PeopleError(404, "no such group")
        return st.unassigned.get(key, EMPTY).tolist()

    def _who(self, st: State, group, faces) -> list[int]:
        """The faces a request names: its group's, then its own `faces`."""
        out = []
        if group is not None:
            if not _int(group):
                raise PeopleError(400, "group must be a group key")
            out += self._group_faces(st, group)
        if faces is not None:
            out += self._need_faces(st, faces)
        return list(dict.fromkeys(out))

    @staticmethod
    def _name(name) -> str:
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= NAME_MAX:
            raise PeopleError(400, f"name must be 1 to {NAME_MAX} characters")
        return name.strip()

    def _clash(self, st: State, name: str, own: int | None = None) -> None:
        for p, row in st.people.items():
            if p != own and row["name"].lower() == name.lower():
                raise PeopleError(409, "that name is taken", person=self.person_json(st, p))

    def _write(self, plan) -> State:
        """One label write. `plan(st)` runs under the write lock against the current State: it checks the
        request (raising PeopleError) and returns `sql(con, at)`, which makes the changes in one
        transaction. Then the State is rebuilt from the labels, recomputing only the scores of the people
        whose confirmed faces changed."""
        self.state()                  # built before the write lock is taken: a build waits for that lock to swap
        with self.wlock:
            with self.lock:
                st = self._state
            sql = plan(st)
            con = self._connect()
            try:
                con.execute("BEGIN IMMEDIATE")
                try:
                    sql(con, now_iso())
                    con.commit()
                except BaseException:
                    con.rollback()
                    raise
            finally:
                con.close()
            self._version += 1
            new = compute(st.base, self._read_labels(), prev=st)
            with self.lock:
                self._state = new
            return new

    @staticmethod
    def _chunks(ids: list[int]):
        for a in range(0, len(ids), 500):
            part = ids[a:a + 500]
            yield part, ",".join("?" * len(part))

    @staticmethod
    def _ids(st: State, faces: list[int]) -> list[int]:
        return [int(st.base.ids[i]) for i in faces]

    def _yes(self, con, st, faces, pid, how, at) -> None:
        """Faces confirmed as `pid`: an earlier answer for them (another person, or face_no for pid) goes."""
        ids = self._ids(st, faces)
        for part, marks in self._chunks(ids):
            con.execute(f"DELETE FROM face_no WHERE person_id=? AND face_id IN ({marks})", [pid, *part])
        con.executemany("INSERT OR REPLACE INTO face_yes(face_id, person_id, how, at) VALUES(?,?,?,?)",
                        [(f, pid, how, at) for f in ids])
        con.execute("UPDATE people SET updated_at=? WHERE id=?", (at, pid))

    def _not(self, con, st, faces, pid, at) -> None:
        """Faces that are not `pid`: no longer hers, and never suggested for her again."""
        ids = self._ids(st, faces)
        for part, marks in self._chunks(ids):
            con.execute(f"DELETE FROM face_yes WHERE person_id=? AND face_id IN ({marks})", [pid, *part])
        con.executemany("INSERT OR IGNORE INTO face_no(face_id, person_id, at) VALUES(?,?,?)",
                        [(f, pid, at) for f in ids])
        con.execute("UPDATE people SET updated_at=? WHERE id=?", (at, pid))

    def create(self, name, group=None, faces=None) -> tuple[int, State]:
        """A new person named from the unclaimed faces of a group and/or a list of faces, each `named`.
        Returns (id, State). 409 (with the person) if the name is taken."""
        name = self._name(name)
        if group is None and faces is None:
            raise PeopleError(400, "give a group or faces to name")
        made = []

        def plan(st):
            who = self._who(st, group, faces)
            self._clash(st, name)
            if not who:
                raise PeopleError(400, "no faces to name")

            def sql(con, at):
                try:
                    pid = con.execute("INSERT INTO people(name, cover_face, created_at, updated_at) VALUES(?,NULL,?,?)",
                                      (name, at, at)).lastrowid
                except sqlite3.IntegrityError:    # someone took the name since we looked
                    raise PeopleError(409, "that name is taken") from None
                made.append(pid)
                self._yes(con, st, who, pid, "named", at)
            return sql
        new = self._write(plan)
        return made[0], new

    def update(self, pid, name=None, cover=None, *, set_cover: bool = False) -> State:
        """Rename a person (409 if the name is taken) and/or choose their cover face. `cover` None with
        set_cover goes back to the best confirmed face."""
        if name is None and not set_cover:
            raise PeopleError(400, "give a name or a cover")
        if name is not None:
            name = self._name(name)
        if set_cover and cover is not None and not _int(cover):
            raise PeopleError(400, "cover must be a face id")

        def plan(st):
            self._need_person(st, pid)
            if name is not None:
                self._clash(st, name, own=pid)
            if set_cover and cover is not None:
                i = st.base.idx_of.get(cover)
                if i is None:
                    raise PeopleError(404, "no such face", face=cover)
                if st.res.pid[i] != pid:
                    raise PeopleError(400, "that face is not theirs")

            def sql(con, at):
                try:
                    if name is not None:
                        con.execute("UPDATE people SET name=?, updated_at=? WHERE id=?", (name, at, pid))
                    if set_cover:
                        con.execute("UPDATE people SET cover_face=?, updated_at=? WHERE id=?", (cover, at, pid))
                except sqlite3.IntegrityError:
                    raise PeopleError(409, "that name is taken") from None
            return sql
        return self._write(plan)

    def add(self, pid, group=None, faces=None) -> State:
        """Faces (and the unclaimed faces of a group) are this person: `added`, and any face_no for them goes."""
        if group is None and faces is None:
            raise PeopleError(400, "give a group or faces to add")

        def plan(st):
            self._need_person(st, pid)
            who = self._who(st, group, faces)
            return lambda con, at: self._yes(con, st, who, pid, "added", at)
        return self._write(plan)

    def merge(self, pid, into) -> State:
        """Everything Danny said about `pid` becomes `into`'s, and `pid` is deleted. Its face_no rows come
        too, except for a face that is a face_yes of `into`."""
        if not _int(into):
            raise PeopleError(400, "into must be a person id")

        def plan(st):
            self._need_person(st, pid)
            self._need_person(st, into)
            if pid == into:
                raise PeopleError(400, "can't merge a person into themself")

            def sql(con, at):
                con.execute("UPDATE face_yes SET person_id=? WHERE person_id=?", (into, pid))
                con.execute("DELETE FROM face_no WHERE person_id=? AND face_id IN "
                            "(SELECT face_id FROM face_yes WHERE person_id=?)", (into, into))
                con.execute("INSERT OR IGNORE INTO face_no(face_id, person_id, at) SELECT face_id, ?, at FROM face_no "
                            "WHERE person_id=? AND face_id NOT IN (SELECT face_id FROM face_yes WHERE person_id=?)",
                            (into, pid, into))
                con.execute("DELETE FROM face_no WHERE person_id=?", (pid,))
                con.execute("DELETE FROM people WHERE id=?", (pid,))
                con.execute("UPDATE people SET updated_at=? WHERE id=?", (at, into))
            return sql
        return self._write(plan)

    def review(self, pid, yes, no) -> State:
        """The answers to "Is this <name>?": yes becomes face_yes (`confirmed`), no becomes face_no."""
        def plan(st):
            self._need_person(st, pid)
            said_yes, said_no = self._need_faces(st, yes or []), self._need_faces(st, no or [])
            if set(said_yes) & set(said_no):
                raise PeopleError(400, "a face can't be both yes and no")

            def sql(con, at):
                self._yes(con, st, said_yes, pid, "confirmed", at)
                self._not(con, st, said_no, pid, at)
            return sql
        return self._write(plan)

    def delete(self, pid) -> State:
        """Delete a person with their face_yes and face_no rows: the faces go back to their groups."""
        def plan(st):
            self._need_person(st, pid)

            def sql(con, at):
                con.execute("DELETE FROM face_yes WHERE person_id=?", (pid,))
                con.execute("DELETE FROM face_no WHERE person_id=?", (pid,))
                con.execute("DELETE FROM people WHERE id=?", (pid,))
            return sql
        return self._write(plan)

    def act(self, faces, action, person=None) -> State:
        """`not` (these faces are not `person`), `move` (they are `person`, `moved`) or `ignore` (not a face)."""
        if action not in ("not", "move", "ignore"):
            raise PeopleError(400, "action must be not, move or ignore")
        if action != "ignore" and not _int(person):
            raise PeopleError(400, "person must be a person id")

        def plan(st):
            who = self._need_faces(st, faces)
            if not who:
                raise PeopleError(400, "faces must not be empty")
            if action != "ignore":
                self._need_person(st, person)
            if action == "not":
                return lambda con, at: self._not(con, st, who, person, at)
            if action == "move":
                return lambda con, at: self._yes(con, st, who, person, "moved", at)
            return lambda con, at: con.executemany("INSERT OR IGNORE INTO face_ignored(face_id, at) VALUES(?,?)",
                                                   [(f, at) for f in self._ids(st, who)])
        return self._write(plan)

    def hide_group(self, key) -> State:
        """Ignore every unclaimed face of an unnamed group."""
        def plan(st):
            who = self._group_faces(st, key)
            return lambda con, at: con.executemany("INSERT OR IGNORE INTO face_ignored(face_id, at) VALUES(?,?)",
                                                   [(f, at) for f in self._ids(st, who)])
        return self._write(plan)
