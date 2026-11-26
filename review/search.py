"""Search for Culling Bay Mobile: find days to review by words, places, dates, or what is in them.

Each photo carries three signals, ranked together:
- words: every query word starts a word in its caption, tags, subject, scene, town or file name;
- captions: its nomic-embed-text caption vector (`photo_cull.py embed`), against the query
  embedded by the same model in Ollama;
- pictures: its CLIP vector (`photo_cull.py embed-images`), against the query through CLIP's text
  half, so a search also matches how a photo looks, not only how it was captioned.

A meaning signal counts a photo as a match when it scores within a margin of the best photo and
at least MIN_Z standard deviations above the library's mean. Measured on the library on
2026-10-11, that is about 20 photos for "kayak" or "Eiffel Tower" and hundreds for "sunset over
the ocean"; a fixed cut-off can't do both. Matches are grouped by day, with each day's matching
photo ids, so the app can open the day with those stacks first.

Years, months and ISO dates in a query ("snow 2019", "june 2015", "2026-10-01") narrow the days
instead of being searched for. More like this ranks days by one photo's picture vector.

People named in Culling Bay (review/people.py) narrow the gallery's search the same way: "Alex Smith",
"Alex" when no other person is called Alex, or two people together ("Alex Sam") for the photos both are
in. Their names are taken out of the query, and what is left is searched among their photos.

The index (every photo's text and both vector matrices, about 220 MB) is rebuilt only when the
library changes: index() looks at a cheap content signature at most every REFRESH_S and builds a
new index off to the side, so searches keep using the old one meanwhile.
"""
import json
import logging
import math
import re
import threading
import time
import urllib.error
import urllib.request

import numpy as np

import perf

log = logging.getLogger(__name__)

CAPTION_MARGIN = 0.06   # nomic cosine: within this of the best photo
PICTURE_MARGIN = 0.03   # CLIP cosine runs on a tighter scale than nomic's
MIN_Z = 3.0
# Below these a signal found nothing. Queries that mean something reached 0.70+ on captions;
# gibberish, file names and "lanai" (a place the captions never name) stayed under 0.52.
CAPTION_FLOOR = 0.58
PICTURE_FLOOR = 0.25
# CLIP alone is easily fooled ("lanai" scored like a real query), so pictures count only when
# the words or the captions understood the query too, or when the best picture stands far out.
PICTURE_ALONE_Z = 5.0
# ...and a photo matched by its picture alone must not be contradicted by its caption: the good
# ones ("a fluffy grey bird on a red cliff" for "seabird chicks") had caption z 2 and up, CLIP's
# mistakes (deer for "giraffe") 1.7 and under.
PICTURE_CAPTION_Z = 2.0
# More like this compares picture with picture, a wider scale (top ~0.9, sd ~0.07) than text
# with picture: these margins give several days, not just the closest frame.
LIKE_PICTURE_MARGIN = 0.10
LIKE_CAPTION_MARGIN = 0.08
IDENT = re.compile(r"\d{3,}")   # DSC04814, IMG_2231: a file name, matched by words only
REFRESH_S = 60          # how often to look for new photos or vectors
BACKSTOP_S = 24 * 3600  # rebuild the index at least this often, in case a change slips past the signature
KEEP_ALIVE = "2h"       # how long Ollama keeps the caption model loaded after a query (its default is 5 min)
DAYS_OUT = 40
MATCH_IDS_MAX = 400     # matching photo ids sent per day, for "matches first"
PHOTOS_OUT = 600        # photos sent for one gallery search
PERSON_PHOTOS_OUT = 5000  # ... but a search for people alone lists all their photos, as the person screen does
LIKE_PHOTOS_OUT = 200
STOP = {"a", "an", "the", "of", "in", "on", "at", "with", "and", "or", "to", "for", "by", "from",
        "my", "me", "some", "photo", "photos", "picture", "pictures", "shot", "shots", "day", "days"}
MONTHS = {m: i + 1 for i, m in enumerate(
    ("january", "february", "march", "april", "may", "june", "july", "august", "september",
     "october", "november", "december"))}
MONTHS.update({m[:3]: i for m, i in list(MONTHS.items())})
MONTHS["sept"] = 9


def parse(q: str):
    """Split a query into search words and date filters: years, months, ISO dates, and a day of
    the month when a month is given ("29 sept"). "may" and "march" are months only next to a year."""
    toks = [t for t in re.split(r"[\s,]+", q.lower().strip()) if t]
    is_year = lambda t: re.fullmatch(r"(19|20)\d\d", t)
    has_year = any(is_year(t) for t in toks)
    years, months, isos, nums, kind = set(), set(), [], [], []
    for t in toks:
        m = t.rstrip(".")
        if is_year(t):
            years.add(int(t)); kind.append("date")
        elif re.fullmatch(r"\d{4}-\d{2}(-\d{2})?", t):
            isos.append(t); kind.append("date")
        elif m in MONTHS and (m not in ("may", "march", "mar") or has_year):
            months.add(MONTHS[m]); kind.append("date")
        elif re.fullmatch(r"\d{1,2}", t):
            nums.append(int(t)); kind.append("num")
        else:
            kind.append("word")
    mdays = {n for n in nums if 1 <= n <= 31} if months else set()
    # a lone number is just a word ("2 dogs"); next to a month it is the day of the month
    words = [t for t, k in zip(toks, kind) if k == "word" or (k == "num" and not months)]
    return words, {"years": years, "months": months, "isos": isos, "mdays": mdays}


def date_ok(iso: str | None, f: dict) -> bool:
    if not (f["years"] or f["months"] or f["isos"] or f["mdays"]):
        return True
    if not iso:
        return False
    y, m, d = int(iso[:4]), int(iso[5:7]), int(iso[8:10])
    return ((not f["years"] or y in f["years"]) and (not f["months"] or m in f["months"])
            and (not f["mdays"] or d in f["mdays"]) and all(iso.startswith(x) for x in f["isos"]))


def cutoff(s: np.ndarray, margin: float, floor: float = -1.0) -> tuple[float, float]:
    """(cut, top) for one signal's scores: within margin of the best, MIN_Z above the mean,
    and at least the floor."""
    top = float(s.max())
    return max(top - margin, float(s.mean() + MIN_Z * s.std()), floor), top


class Search:
    def __init__(self, *, db_ro, pc, day_of, day_date, ollama_url: str, library_root: str, embed=None, people=None):
        """embed(text) -> the caption vector for a query; by default Ollama's /api/embed (tests pass a fake).
        people() -> {lower-case name: the ids of that person's photos}, for searching by who is in a photo."""
        self.db_ro, self.pc, self.day_of, self.day_date = db_ro, pc, day_of, day_date
        self.people = people
        self.ollama = ollama_url.rstrip("/")
        self.root = library_root
        self._embed = embed or self._ollama_embed
        self._clip = None
        self._clip_lock = threading.Lock()
        self.lock = threading.Lock()   # guards the fields below; never held while the index is built
        self.idx = None                # the index in use
        self.key = None                # the library signature it was built from
        self.checked = 0.0             # when the signature was last compared
        self.built = 0.0               # when the index was built
        self._building = None          # an Event while one thread checks or builds, so others don't
        self._error = None             # why the last build failed, for the threads that waited for it

    @property
    def clip(self):   # loaded on first use (~250 MB for the text half), once, however many ask at first
        if self._clip is None:
            with self._clip_lock:
                if self._clip is None:
                    self._clip = self.pc.Clip(threads=2)
        return self._clip

    # ---------------------------------------------------------------- the index
    SNAPSHOT_SQL = """SELECT e.top, e.n, i.top, i.ok, i.latest, i.places, {s} FROM
        (SELECT MAX(rowid) AS top, COUNT(*) AS n FROM embeddings) e,
        (SELECT MAX(rowid) AS top, SUM(status = 'ok') AS ok, MAX(processed_at) AS latest, COUNT(place) AS places
         FROM images) i{sums}"""

    def _snapshot(self, con):
        """What the library holds, cheaply: new rows (the highest rowids), rows changed in place (the
        count of photos that are ok, the newest processed_at, how many have a place) and the day
        summaries. Anything that changes what a search can find changes this."""
        try:
            row = con.execute(self.SNAPSHOT_SQL.format(
                s="s.n, s.latest", sums=", (SELECT COUNT(*) AS n, MAX(created_at) AS latest FROM day_summaries) s")).fetchone()
        except Exception:  # noqa: BLE001 - before daysum has ever run there is no such table
            row = con.execute(self.SNAPSHOT_SQL.format(s="0, NULL", sums="")).fetchone()
        return tuple(row)

    def index(self):
        """The index to search. Looks for library changes at most every REFRESH_S. One thread at a time
        checks and builds, outside the lock: the others go on with the old index, or wait when
        there is none yet. A failed build keeps the old index (and logs why); with none, it raises."""
        while True:
            with self.lock:
                if self.idx is not None and time.time() - self.checked < REFRESH_S:
                    return self.idx
                running = self._building
                if running is None:
                    self._building = mine = threading.Event()
                    break
                if self.idx is not None:
                    return self.idx
            running.wait()   # no index at all yet: wait for the build under way
            with self.lock:
                if self.idx is not None:
                    return self.idx
                if self._error is not None:
                    raise self._error
        err = built = None
        try:
            built = self._refresh()
        except BaseException as e:  # noqa: BLE001 - even an interrupt must let the waiting threads go
            err = e
        with self.lock:
            now = time.time()
            if err is None:
                if built is not None:
                    self.idx, self.key, self.built = built[0], built[1], now
                self.checked, self._error = now, None
            else:
                self._error = err
                if self.idx is not None:
                    self.checked = now      # try again after REFRESH_S, not on every search
            self._building = None
            idx = self.idx
        mine.set()
        if err is not None:
            if idx is None or not isinstance(err, Exception):
                raise err
            log.warning("search index not reloaded, keeping the old one: %s: %s", type(err).__name__, err)
        return idx

    def _refresh(self):
        """(new index, its signature) if the library changed or the backstop is due, else None."""
        con = self.db_ro()
        try:
            key = self._snapshot(con)
            with self.lock:
                if self.idx is not None and key == self.key and time.time() - self.built < BACKSTOP_S:
                    return None
            return self._load(con), key
        finally:
            con.close()

    def _load(self, con):
        rows = con.execute(
            "SELECT rowid AS id, path, filename, caption, subject, scene, activity, tags, animals, "
            "content_type, place FROM images WHERE status='ok'").fetchall()
        ids, days, blobs, caps, pos = [], [], [], [], {}
        for r in rows:
            d = self.day_of(r["path"])
            if not d:
                continue
            pos[r["path"]] = len(ids)
            ids.append(r["id"])
            days.append(d)
            caps.append(r["caption"] or "")
            blobs.append(" ".join(str(r[k] or "") for k in (
                "caption", "subject", "scene", "activity", "tags", "animals", "content_type", "place",
                "filename")).lower())
        n = len(ids)

        def vectors(version):
            mat, have = None, np.zeros(n, bool)
            for r in con.execute("SELECT path, vector FROM embeddings WHERE embed_version=?", (version,)):
                i = pos.get(r["path"])
                if i is None:
                    continue
                v = self.pc.unpack_vector(r["vector"])
                if mat is None:
                    mat = np.zeros((n, len(v)), np.float32)
                mat[i] = v
                have[i] = True
            if mat is not None:
                norms = np.linalg.norm(mat, axis=1, keepdims=True)
                norms[norms == 0] = 1
                mat /= norms
            return mat, have

        cap_m, cap_have = vectors(self.pc.EMBED_VERSION)
        pic_m, pic_have = vectors(self.pc.CLIP_VERSION)
        day_text, day_iso = {}, {}
        try:
            sums = {r["folder"]: r["summary"] for r in con.execute("SELECT folder, summary FROM day_summaries")}
        except Exception:  # noqa: BLE001 - before daysum has ever run
            sums = {}
        for d in set(days):
            day_iso[d] = self.day_date(d)
            day_text[d] = (sums.get(f"{self.root}/{d}") or "").lower()
        towns = {}   # a day's towns are searched with its summary
        for r in rows:
            d = self.day_of(r["path"])
            if d and r["place"]:
                towns.setdefault(d, set()).add(r["place"].lower())
        return {"ids": np.array(ids), "days": np.array(days, dtype=object), "blobs": blobs, "caps": caps,
                "cap": cap_m, "cap_have": cap_have, "pic": pic_m, "pic_have": pic_have,
                "pos_id": {rid: i for i, rid in enumerate(ids)},
                "day_text": day_text, "day_towns": towns, "day_iso": day_iso}

    def coverage(self) -> dict:
        idx = self.index()
        return {"photos": len(idx["ids"]), "captions": int(idx["cap_have"].sum()), "pictures": int(idx["pic_have"].sum())}

    # ---------------------------------------------------------------- queries
    def _ollama_embed(self, text: str) -> list:
        """The query through nomic-embed-text in Ollama's native /api/embed, which (unlike /v1/embeddings)
        takes keep_alive: the model stays loaded for KEEP_ALIVE after each query, so a search an hour
        after the last one doesn't wait seconds for it to load. The same vector as /v1 gives."""
        req = urllib.request.Request(
            self.ollama + "/api/embed", method="POST", headers={"Content-Type": "application/json"},
            data=json.dumps({"model": self.pc.EMBED_MODEL, "input": text, "keep_alive": KEEP_ALIVE}).encode())
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read().decode())["embeddings"][0]
        except urllib.error.HTTPError as e:
            with e:
                raise RuntimeError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}") from None

    def _caption_vec(self, text: str) -> np.ndarray:
        v = np.asarray(self._embed(text), np.float32)
        return v / (np.linalg.norm(v) or 1)

    def prime(self) -> None:
        """Load what a first search would otherwise wait for: CLIP's text half, and the caption model
        in Ollama (kept loaded for KEEP_ALIVE). Run it in the background after the index is built."""
        for what, run in (("CLIP text half", lambda: self.clip.text("warm up")),
                          ("caption model", lambda: self._caption_vec("warm up"))):
            t = time.perf_counter()
            try:
                run()
                log.info("search warm-up: %s ready in %.0f ms", what, (time.perf_counter() - t) * 1000)
            except Exception as e:  # noqa: BLE001 - a search will try again, and say what is wrong
                log.warning("search warm-up: %s failed: %s: %s", what, type(e).__name__, e)

    def _signal(self, mat, have, qv, margin, floor=-1.0):
        """(score array, match mask, strength 0..1, z of the best) for one meaning signal, over
        the photos in `have` only (so a date filter narrows the field before the cut)."""
        n = len(have)
        s = np.full(n, -1.0, np.float32)
        if mat is None or not have.any():
            return s, np.zeros(n, bool), np.zeros(n, np.float32), 0.0
        s[have] = mat[have] @ qv
        cut, top = cutoff(s[have], margin, floor)
        match = have & (s >= cut)
        strength = np.where(match, (s - cut) / max(top - cut, 1e-6), 0).astype(np.float32)
        sd = float(s[have].std()) or 1.0
        return s, match, strength, (top - float(s[have].mean())) / sd

    def _score(self, idx, words, day_keep, notes, used, only=None):
        """(match mask, score, word patterns) for a query's words over the photos in day_keep (and in
        `only`, a mask over the index, when given: the field is narrowed before any cut is made)."""
        n = len(idx["ids"])
        lex_words = [w for w in words if w not in STOP] or words
        pats = [re.compile(r"\b" + re.escape(w)) for w in lex_words]
        in_days = np.fromiter((d in day_keep for d in idx["days"]), bool, n)
        if only is not None:
            in_days &= only
        with perf.stage("words"):
            lex = in_days & np.fromiter((all(p.search(b) for p in pats) for b in idx["blobs"]), bool, n)
        if lex.any():
            used.append("words")
        text = " ".join(words)
        cap_m = np.zeros(n, bool)
        cap_k = np.zeros(n, np.float32)
        pic_m = np.zeros(n, bool)
        pic_k = np.zeros(n, np.float32)
        meaning = not any(IDENT.search(w) for w in words)
        cap_z = None
        if meaning and idx["cap"] is not None:
            try:
                h = idx["cap_have"] & in_days
                with perf.stage("caption_query"):     # the query embedded by nomic in Ollama
                    qv = self._caption_vec(text)
                with perf.stage("captions"):
                    cap_s, cap_m, cap_k, _ = self._signal(idx["cap"], h, qv, CAPTION_MARGIN, CAPTION_FLOOR)
                if h.any():
                    cap_z = (cap_s - cap_s[h].mean()) / (cap_s[h].std() or 1)
                if cap_m.any():
                    used.append("captions")
            except Exception as e:  # noqa: BLE001 - Ollama down: words and pictures still work
                notes.append(f"Caption meaning is off: the search model isn't answering ({type(e).__name__}).")
        if meaning and idx["pic"] is not None:
            try:
                with perf.stage("picture_query"):     # the query through CLIP's text half
                    tv = self.clip.text(text)
                with perf.stage("pictures"):
                    _, pm, pk, z = self._signal(idx["pic"], idx["pic_have"] & in_days, tv,
                                                PICTURE_MARGIN, PICTURE_FLOOR)
                if cap_z is not None:
                    pm &= cap_m | lex | (cap_z >= PICTURE_CAPTION_Z) | ~idx["cap_have"]
                if pm.any() and (lex.any() or cap_m.any() or z >= PICTURE_ALONE_Z):
                    pic_m, pic_k = pm, pk
                    used.append("pictures")
            except Exception as e:  # noqa: BLE001
                notes.append(f"Picture search is off ({type(e).__name__}).")
        score = lex * 1.0 + cap_k + pic_k
        matched = lex | cap_m | pic_m

        return matched, score, pats

    def search(self, q: str) -> dict:
        with perf.stage("index"):
            idx = self.index()
        words, dates = parse(q)
        n = len(idx["ids"])
        day_keep = {d for d, iso in idx["day_iso"].items() if date_ok(iso, dates)}
        notes, used = [], []
        if not words:   # only dates: the days in that span, newest first
            ds = sorted(day_keep, key=lambda d: idx["day_iso"].get(d) or "", reverse=True)
            return {"query": q, "days": [{"day": d, "n": 0, "ids": [], "match_ids": [], "why": ""} for d in ds[:200]],
                    "photos": 0, "signals": ["dates"], "notes": []}

        matched, score, pats = self._score(idx, words, day_keep, notes, used)

        by_day: dict[str, list[int]] = {}
        for i in np.flatnonzero(matched):
            by_day.setdefault(idx["days"][i], []).append(int(i))
        out = []
        for d, ii in by_day.items():
            ii.sort(key=lambda i: -score[i])
            best = ii[0]
            cap = idx["caps"][best]
            out.append({"day": d, "n": len(ii), "ids": [int(idx["ids"][i]) for i in ii[:4]],
                        "match_ids": [int(idx["ids"][i]) for i in ii[:MATCH_IDS_MAX]],
                        "why": f"{len(ii)} photo{'s' if len(ii) > 1 else ''}" + (f" · “{cap}”" if cap else ""),
                        "score": float(score[best]) + 0.15 * math.log2(1 + len(ii))})
        # days whose summary or towns hold every word, with no photo of their own matching
        for d in day_keep - set(by_day):
            towns = idx["day_towns"].get(d, set())
            hay = idx["day_text"].get(d, "") + " " + " ".join(towns)
            if all(p.search(hay) for p in pats):
                near = next((t for t in towns if all(p.search(t) for p in pats)), None)
                out.append({"day": d, "n": 0, "ids": [], "match_ids": [],
                            "why": "Near " + near.split(", ")[0].title() if near else "In the day’s summary", "score": 0.9})
        out.sort(key=lambda r: (-r["score"], r["day"]))
        for r in out:
            r.pop("score")
        return {"query": q, "days": out[:DAYS_OUT], "photos": int(matched.sum()), "signals": used, "notes": notes}

    def like(self, rowid: int) -> dict | None:
        """Days with photos most like this one: by its picture, else by its caption."""
        idx = self.index()
        i = idx["pos_id"].get(rowid)
        if i is None:
            return None
        if idx["pic"] is not None and idx["pic_have"][i]:
            mat, have, margin, by = idx["pic"], idx["pic_have"], LIKE_PICTURE_MARGIN, "pictures"
        elif idx["cap"] is not None and idx["cap_have"][i]:
            mat, have, margin, by = idx["cap"], idx["cap_have"], LIKE_CAPTION_MARGIN, "captions"
        else:
            return {"days": [], "photos": 0, "signals": [], "notes": ["This photo isn't indexed yet."]}
        other = have & (idx["days"] != idx["days"][i])   # its own day is the one you're in
        s, match, k, _ = self._signal(mat, other, mat[i], margin)
        by_day: dict[str, list[int]] = {}
        for j in np.flatnonzero(match):
            by_day.setdefault(idx["days"][j], []).append(int(j))
        out = []
        for d, jj in by_day.items():
            jj.sort(key=lambda j: -s[j])
            out.append({"day": d, "n": len(jj), "ids": [int(idx["ids"][j]) for j in jj[:4]],
                        "match_ids": [int(idx["ids"][j]) for j in jj[:MATCH_IDS_MAX]],
                        "why": f"{len(jj)} similar photo{'s' if len(jj) > 1 else ''}",
                        "score": float(s[jj[0]]) + 0.01 * math.log2(1 + len(jj))})
        out.sort(key=lambda r: -r["score"])
        for r in out:
            r.pop("score")
        return {"days": out[:DAYS_OUT], "photos": int(match.sum()), "signals": [by], "notes": []}

    def _find_people(self, q: str) -> tuple[set | None, str]:
        """(the ids of the photos all the people named in a query are in, the query without their names);
        None for the ids when it names nobody, and then the query comes back as it was. Whole names are
        found first, the longest first, in any case; then a first name that no other person has."""
        if self.people is None:
            return None, q
        try:
            sets = self.people()
        except Exception as e:  # noqa: BLE001 - the search goes on without people
            log.warning("people not searched: %s: %s", type(e).__name__, e)
            return None, q
        toks = [t for t in re.split(r"[\s,]+", q.strip()) if t]
        low = [t.lower() for t in toks]
        used, found = [False] * len(toks), []
        for name in sorted(sets, key=lambda nm: (-len(nm.split()), nm)):
            parts = name.split()
            for i in range(len(low) - len(parts) + 1):
                if parts and low[i:i + len(parts)] == parts and not any(used[i:i + len(parts)]):
                    used[i:i + len(parts)] = [True] * len(parts)
                    found.append(name)
                    break
        firsts = [nm.split()[0] for nm in sets if nm.split()]
        for i, t in enumerate(low):
            if not used[i] and firsts.count(t) == 1:
                name = next(nm for nm in sets if nm.split() and nm.split()[0] == t)
                if name not in found:
                    used[i] = True
                    found.append(name)
        if not found:
            return None, q
        return set.intersection(*(set(sets[nm]) for nm in found)), " ".join(t for t, u in zip(toks, used) if not u)

    def photos(self, q: str, limit: int = PHOTOS_OUT) -> dict:
        """Photos for a query, best match first, across every day (the gallery's search).
        A query of only dates gives the photos in that span, newest first. People named in it (all of
        them, together) narrow the search to their photos: with nothing else to search for, those photos
        newest first, narrowed by any dates; with words, the normal scoring among them."""
        with perf.stage("index"):
            idx = self.index()
        ids, rest = self._find_people(q)
        words, dates = parse(rest)
        if ids is not None and all(w in STOP for w in words):
            words = []        # "photos of Alex", "Alex and Sam": nothing left to search for
        day_keep = {d for d, iso in idx["day_iso"].items() if date_ok(iso, dates)}
        notes, used = [], (["people"] if ids is not None else [])
        only = None
        if ids is not None:
            only = np.fromiter((int(i) in ids for i in idx["ids"]), bool, len(idx["ids"]))
        if not words:
            keep = np.fromiter((d in day_keep for d in idx["days"]), bool, len(idx["ids"]))
            if only is not None:
                keep &= only
            order = sorted(np.flatnonzero(keep), key=lambda i: (idx["day_iso"].get(idx["days"][i]) or "", idx["ids"][i]),
                           reverse=True)
            # a search for people is a list of their photos, not a ranking: don't cut it at the top 600
            cap = max(limit, PERSON_PHOTOS_OUT) if ids is not None else limit
            return {"query": q, "ids": [int(idx["ids"][i]) for i in order[:cap]], "total": int(keep.sum()),
                    "signals": used + (["dates"] if ids is None or any(dates.values()) else []), "notes": []}
        matched, score, _ = self._score(idx, words, day_keep, notes, used, only=only)
        order = sorted(np.flatnonzero(matched), key=lambda i: -score[i])
        return {"query": q, "ids": [int(idx["ids"][i]) for i in order[:limit]], "total": int(matched.sum()),
                "signals": used, "notes": notes}

    def like_photos(self, rowid: int, limit: int = LIKE_PHOTOS_OUT) -> dict | None:
        """Photos most like this one, from any day, most similar first."""
        idx = self.index()
        i = idx["pos_id"].get(rowid)
        if i is None:
            return None
        if idx["pic"] is not None and idx["pic_have"][i]:
            mat, have, margin, by = idx["pic"], idx["pic_have"], LIKE_PICTURE_MARGIN, "pictures"
        elif idx["cap"] is not None and idx["cap_have"][i]:
            mat, have, margin, by = idx["cap"], idx["cap_have"], LIKE_CAPTION_MARGIN, "captions"
        else:
            return {"ids": [], "total": 0, "signals": [], "notes": ["This photo isn't indexed yet."]}
        others = have.copy()
        others[i] = False
        s, match, _, _ = self._signal(mat, others, mat[i], margin)
        order = sorted(np.flatnonzero(match), key=lambda j: -s[j])
        return {"ids": [int(idx["ids"][j]) for j in order[:limit]], "total": int(match.sum()),
                "signals": [by], "notes": []}
