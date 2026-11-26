"""A made-up library of faces for the People tests: a temp trial.db and annotations.db, and a Flask client
over them. The people are random unit vectors in 512 dimensions ("centres") and each face is a centre plus
noise, normalised: faces of one person sit about 0.64 alike, two people about 0, whatever the seed. The
names are invented ("alex", "sam"); no real person appears anywhere in these tests.
"""
import sqlite3
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "review"))
import photo_cull as pc  # noqa: E402
from review.tests.helpers import FakePC, anno_connection  # noqa: E402

LIB = "/mnt/passport/Pictures"   # mobile.LIBRARY_ROOT: a photo outside it belongs to no day
D = 512
NOISE = 0.75                     # faces of one person: cosine 1 / (1 + NOISE**2) = 0.64


def unit(v):
    v = np.asarray(v, np.float32)
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def mix(rng, parts, noise=0.0):
    """A unit vector that is sum(weight * unit vector) over `parts` [(vector, weight)], plus noise."""
    v = sum(w * unit(c) for c, w in parts) + noise * rng.normal(size=D) / np.sqrt(D)
    return unit(v).astype(np.float32)


# who is photographed in which day folder: {folder: {person: faces}}. Four people over four days;
# casey is seen once, alone, on the last day.
DAYS = {
    "2026/2026-01-01": {"alex": 6, "sam": 5},
    "2026/2026-01-02": {"alex": 7, "robin": 5},
    "2026/2026-01-03": {"sam": 6, "robin": 4},
    "2026/2026-01-04": {"alex": 5, "casey": 1},
}


class World:
    def __init__(self, seed: int = 5, days=None):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.db, self.anno_path = self.dir / "trial.db", self.dir / "annotations.db"
        self.rng = np.random.default_rng(seed)
        self.centre = {}
        self.faces = []                  # [{id, person, folder, photo, path}] in id order
        self.n = 0
        self.con = pc.connect(self.db)
        for folder, who in (DAYS if days is None else days).items():
            for person, count in who.items():
                for _ in range(count):
                    self.add_face(person, folder)
        self.con.commit()

    def close(self):
        self.con.close()
        self.tmp.cleanup()

    # ---------------------------------------------------------------- building the library
    def person(self, name):
        if name not in self.centre:
            self.centre[name] = unit(self.rng.normal(size=D))
        return self.centre[name]

    def photo(self, folder, caption="a photo", ts=None):
        """A new ok photo in a day folder; returns (rowid, path)."""
        self.n += 1
        path = f"{LIB}/{folder}/IMG_{self.n:05d}.ARW"
        cur = self.con.execute(
            "INSERT INTO images(path, filename, status, capture_ts, caption, processed_at) VALUES(?,?,?,?,?,?)",
            (path, Path(path).name, "ok", ts if ts is not None else 1_700_000_000 + self.n * 60, caption, "2026-01-01T00:00:00+00:00"))
        return cur.lastrowid, path

    def add_face(self, person, folder, *, vector=None, photo=None, score=0.9, sharp=100.0, version=None,
                 caption="a photo", box=(0.3, 0.3, 0.5, 0.55)):
        """A face of `person` (None: of nobody in particular) in `folder`, in its own photo unless `photo`
        is a (rowid, path). Returns its face id."""
        rowid, path = photo or self.photo(folder, caption)
        if vector is None:
            vector = mix(self.rng, [(self.person(person), 1.0)], NOISE) if person else unit(self.rng.normal(size=D))
        cur = self.con.execute(
            "INSERT INTO faces(path, face_version, x0, y0, x1, y1, kps, score, sharp, eye_px, box_px, vector, created_at) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (path, version or pc.FACE_VERSION, *box, "[]", score, sharp, 40.0, 200.0,
             pc.pack_vector(vector), "2026-01-01T00:00:00+00:00"))
        self.con.execute("INSERT OR REPLACE INTO faces_checked(path, face_version, faces, checked_at) VALUES(?,?,1,'t')",
                         (path, version or pc.FACE_VERSION))
        self.faces.append({"id": cur.lastrowid, "person": person, "folder": folder, "photo": rowid, "path": path,
                           "version": version or pc.FACE_VERSION})
        return cur.lastrowid

    def together(self, folder, people, caption="a photo"):
        """One photo with a face of each person in it. Returns (photo rowid, [face ids])."""
        photo = self.photo(folder, caption)
        ids = [self.add_face(p, folder, photo=photo, box=(0.1 + 0.3 * k, 0.3, 0.3 + 0.3 * k, 0.55))
               for k, p in enumerate(people)]
        self.con.commit()
        return photo[0], ids

    # ---------------------------------------------------------------- looking
    def ids(self, person, folder=None, count=None):
        out = [f["id"] for f in self.faces if f["person"] == person and (folder is None or f["folder"] == folder)]
        return out[:count] if count else out

    def vector(self, face_id):
        return pc.unpack_vector(self.con.execute("SELECT vector FROM faces WHERE id=?", (face_id,)).fetchone()[0])

    def photos(self, person, folder=None):
        return sorted({f["photo"] for f in self.faces if f["person"] == person and (folder is None or f["folder"] == folder)})

    def group_of(self, face_id):
        con = sqlite3.connect(self.db)
        try:
            row = con.execute("SELECT grp FROM face_groups WHERE face_id=?", (face_id,)).fetchone()
        finally:
            con.close()
        return row[0] if row else None

    def commit(self):
        self.con.commit()

    def add_lookalikes(self, person, n, folder, weight=0.55):
        """n faces of nobody in particular that are about 0.45 alike to `person`'s faces: more than 0.40 (a
        suggestion for her) and less than 0.55 (not filed). Returns their ids."""
        centre = unit(np.mean([self.vector(f) for f in self.ids(person)], axis=0))
        ids = [self.add_face(None, folder, vector=mix(self.rng, [(centre, weight), (unit(self.rng.normal(size=D)), 0.85)]))
               for _ in range(n)]
        self.commit()
        return ids

    def add_group(self, ids):
        """A new grouping run that keeps the groups there are and adds one of these faces."""
        con = sqlite3.connect(self.db)
        try:
            rows = con.execute("SELECT face_id, grp FROM face_groups WHERE grp IS NOT NULL").fetchall()
        finally:
            con.close()
        groups = {}
        for face, grp in rows:
            groups.setdefault(grp, []).append(face)
        groups[min(ids)] = list(ids)
        self.write_groups(groups)

    def write_groups(self, groups: dict):
        """Write face_groups by hand, as `faces-group` would have: {group key: [face ids]}. Every other face
        is in no group. Stamps a new computed_at, so a PeopleIndex sees a new grouping run."""
        from datetime import datetime, timezone
        at = datetime.now(timezone.utc).isoformat(timespec="microseconds")
        of = {f: key for key, ids in groups.items() for f in ids}
        with self.con:
            self.con.execute("DELETE FROM face_groups")
            self.con.executemany("INSERT INTO face_groups(face_id, grp) VALUES(?,?)",
                                 [(f["id"], of.get(f["id"])) for f in self.faces if f["version"] == pc.FACE_VERSION])
            self.con.execute("DELETE FROM face_groups_meta")
            self.con.executemany("INSERT INTO face_groups_meta(k, v) VALUES(?,?)",
                                 [("faces_count", str(len(self.faces))), ("faces_max_id", str(self.faces[-1]["id"])),
                                  ("version", pc.FACE_GROUP_VERSION), ("computed_at", at)])

    def group(self, *extra):
        """Run `photo_cull.py faces-group` in-process. Returns (exit code, what it printed)."""
        import contextlib
        import io
        self.con.commit()
        out, code = io.StringIO(), 0
        with contextlib.redirect_stdout(out):
            try:
                args = pc.build_parser().parse_args(["faces-group", "--db", str(self.db), *extra])
                args.func(args)
            except SystemExit as e:
                code = e.code if isinstance(e.code, int) else 1
        return code, out.getvalue()

    def db_ro(self):
        con = sqlite3.connect(f"file:{self.db}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
        return con

    def anno(self):
        return anno_connection(self.anno_path)

    def labels(self, table):
        con = self.anno()
        try:
            return [dict(r) for r in con.execute(f"SELECT * FROM {table}")]
        finally:
            con.close()

    def index(self, refresh_s=0):
        import people
        return people.PeopleIndex(db_ro=self.db_ro, anno=self.anno, pc=pc, refresh_s=refresh_s)

    def client(self, refresh_s=0, pc_module=None):
        """A Flask test client over this world: the /m blueprint with fake pictures (a grey 64 x 48)."""
        from flask import Flask
        import mobile
        static = self.dir / "static"
        static.mkdir(exist_ok=True)
        app = Flask(__name__)
        app.register_blueprint(mobile.make_blueprint(
            db_ro=self.db_ro, anno=self.anno, pc=pc_module or FakePC(), cache_dir=self.dir / "cache", static_dir=static,
            state_dir=self.dir / "state", inbox=self.dir / "inbox", check_mount=False, ingest_log=self.dir / "ingest.log",
            ollama_url="http://127.0.0.1:9", people_refresh_s=refresh_s))
        (self.dir / "cache").mkdir(exist_ok=True)
        self.app = app
        return app.test_client()
