# People in Culling Bay: design (DAN-142)

Danny's ask: group faces like Apple Photos, name a group, merge groups that are the same person,
confirm suggestions, flag and fix mistakes, and search by person. His decisions (2026-11-26):
- People screens go in the native app only.
- Named people go to Lightroom as keywords.
- Faces come from the preview for now. A RAW pass for small faces is a possible later option.

Measured on the 300-photo spike, ~/danny-MS-7C37/faces-spike. The numbers are in DAN-142.

## Four layers

| Layer | Where | Written by | What |
|---|---|---|---|
| faces | trial.db `faces`, `faces_checked` | `photo_cull.py faces` (phase A, done) | each face's box, quality and 512-d vector; `faces.id` is stable |
| face groups | trial.db `face_groups`, `face_groups_meta` | `photo_cull.py faces-group` | label-blind clustering of every face; rerun after imports |
| labels | annotations.db `people`, `face_yes`, `face_no`, `face_ignored` | the server, from the app | Danny's names and corrections only; never derived |
| people index | server memory, `review/people.py` | built from the three above | who is in which photo, suggestions, unnamed groups |

The pipeline never reads labels, and the labels never hold derived data. So regrouping can
never undo a correction: corrections always sit on top.

## Face groups (`photo_cull.py faces-group`)

A **good face** has detector `score >= 0.7` and `sharp >= 40` (Laplacian variance on the
aligned 112 px face). In the spike, 685 of 1,458 faces were good.

1. **Per day.** For each folder (`dirname(path)`), cluster its good faces with average linkage
   on cosine distance, cut at 0.6 (`scipy.cluster.hierarchy.linkage(method="average",
   metric="cosine")` then `fcluster(t=0.6, criterion="distance")`). These are the day-clusters.
2. **Across days.** For each day-cluster of 2 or more faces, take its normalised mean vector.
   Cluster those means with average linkage on cosine distance, cut at 0.55. Pairs of
   day-clusters from the **same folder** get distance 2.0, so same-day groups never join: stage 1
   already kept them apart. The spike's sisters (same day, different people) had means 0.48–0.50
   alike. The same person across days measured 0.55–0.88, and different people across days at
   most 0.24. Build the condensed distance matrix yourself (`1 - C @ C.T`, set the same-folder
   pairs, `squareform`). A 10k-cluster library makes it ~400 MB, which is fine on this PC.
3. **Attach the rest.** Faces in single-face day-clusters, and weak faces (not good), join the
   nearest group mean if the cosine similarity is at least 0.45. Otherwise `grp` is NULL.
4. **Write.** `face_groups(face_id INTEGER PRIMARY KEY, grp INTEGER)` is rewritten in one
   transaction. `grp` is the smallest face id in the group, a key that stays put while the
   group's oldest face stays in it. Write `face_groups_meta(k TEXT PRIMARY KEY, v TEXT)` with
   `faces_count`, `faces_max_id`, `version` (`FACE_GROUP_VERSION = "g1"`) and `computed_at`.
   Skip the run when `faces_count` and `faces_max_id` are unchanged, unless `--force`.
5. The watcher runs it after the `faces` step, non-fatal.

## Labels (annotations.db, `review/mobile.py` SCHEMA or the people module's own)

```sql
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
```

## People index: who each face is

For every face (`faces` at `FACE_VERSION`, joined to `images.rowid` for its photo id):

1. In `face_ignored`: nobody, hidden.
2. In `face_yes`: that person (`how: "confirmed"`).
3. **Group rule.** The face's `grp` holds confirmed faces. If at least 2/3 of them (and at least
   1) belong to one person P, and the face isn't in `face_no` for P, it's P (`how: "auto"`).
4. **Similarity rule.** `s_P(f)` is the mean of the top 3 cosine similarities between f and P's
   confirmed faces (if P has more than 300, use a fixed spread of 300 by id). If the best P has
   `s >= AUTO_SIM` (0.55), beats the second-best person by at least 0.10, and the face isn't in
   `face_no` for P, it's P (`how: "auto"`).
5. **Suggestion.** If the best P has `SUGGEST_SIM` (0.40) `<= s < AUTO_SIM` and the face isn't
   in `face_no` for P, it's a suggestion for P, ranked by s.
6. Otherwise, if it has a `grp`, it's a member of that unnamed group.

Spike calibration, with half of each group "named": at 0.55, 78% of the person's other faces
were auto-filed and none of anyone else's. At 0.45 it caught 96%, with 0.6% wrong. The 0.40–0.55
band becomes "Is this P?". Recalibrate on the full library once the backfill is done.

**Unnamed groups** are groups with 3 or more faces still unassigned (not ignored). Sort them by
the number of different days they appear on, then by photos. One-day crowds such as the
2026-02-11 parade sink below friends and family. Cap the list at 300. Each group gets
`maybe: {id, name}` when its mean is at least 0.40 alike to a named person's mean, so the app
can ask "Is this Alex?" on the group.

**Speed.** Keep one float32 score array per person (n_faces long) in memory. A label change for
P recomputes only P's array: 70k faces × ≤300 confirmed is ~0.2 s. Rebuild everything when
trial.db's faces or groups change (compare `face_groups_meta` and the faces max id, checked at
most every 30 s, like the search index's snapshot check). Load vectors once, as one
(n, 512) float32 matrix of ~140 MB.

## API (`/m/api`, documented in review/API.md, guarded by test_contract_*)

Reads:
- `GET /people` returns `{people: [Person], groups: [Group], faces_checked, photos_ok}`.
  - Person: `{id, name, photos, faces, cover, suggestions}`, where `cover` is a face id and `suggestions` a count.
  - Group: `{key, faces, photos, days, cover, maybe?}`.
  - Named people come first, most photos first.
- `GET /people/<id>` returns `{id, name, total, photos: [Photo]}`, newest first. It takes the gallery's `best` and `bursts` flags.
- `GET /people/group/<key>` returns `{key, total, photos: [Photo]}`.
- `GET /people/<id>/faces?offset=&limit=` returns `{total, faces: [{id, photo, how}]}`, for the fix screen.
- `GET /people/<id>/suggestions` returns `{faces: [{id, photo, sim}], groups: [Group]}`: up to 60 faces, plus the unnamed groups whose `maybe` is this person.
- `GET /face/<id>?s=small|large` returns a square JPEG, 160 or 480 px. It is cut from the photo's `view` rendition with the box padded 30%, and is cacheable like `/img`.
- `GET /photo/<id>/faces` returns `{faces: [{id, box: [x0,y0,x1,y1], person: {id, name}?, how}]}`. Ignored faces are left out.

Writes (the `X-Culling-Bay` header and a JSON body, as for every write):
- `POST /people {name, group?, faces?}` returns `201 {id}`. It names a group, so every face in it gets `face_yes` with `how: "named"`. A name that already exists gives `409 {error, person}`, and the app then offers "Add to <name>?".
- `POST /people/<id> {name?, cover?}` renames the person or sets the cover. A name clash gives 409.
- `POST /people/<id>/add {group?, faces?}` adds faces with `face_yes`, `how: "added"`, and removes any `face_no` for them.
- `POST /people/<id>/merge {into}`:
  - P's `face_yes` rows move to `into`;
  - P's `face_no` rows move too, unless the face is already a yes for `into`;
  - P is deleted.
- `POST /people/<id>/review {yes: [ids], no: [ids]}` records the answers to suggestions: `face_yes` with `how: "confirmed"`, or `face_no`.
- `POST /people/<id>/delete` deletes the person and its `face_yes`/`face_no` rows. The faces go back to their groups.
- `POST /faces {faces: [ids], action: "not", person}` is the flag and fix for "this isn't P": it deletes `face_yes` for P and adds `face_no`.
- `POST /faces {faces: [ids], action: "move", person}` gives each face `face_yes` for that person, with `how: "moved"`.
- `POST /faces {faces: [ids], action: "ignore"}` adds the faces to `face_ignored`.
- `POST /people/group/<key>/hide` puts every face of the group in `face_ignored`.

Every write answers with the changed Person, or `{ok: true}`, so the app can refresh one row.

## Search

`Search` takes an optional `people` provider: `() -> {lower-case name: set(photo ids)}`. In
`photos(q)`:
- Find person names in the query: whole names first (multi-word, case-insensitive), then
  first names that are unique among people.
- Combine several people with AND, and take their tokens out of the words.
- No words left: the people's photos, filtered by any dates, newest first.
- Words left: the normal scoring, limited to those photos.
- Add `"people"` to `signals`.

## Lightroom (phase E)

A `people` column in the sync file the plugin reads. The plugin creates `People > <name>`
keywords and records the names it set on each photo in a plugin property, so a later sync can
remove one Danny took off in Culling Bay. It never touches keywords it didn't set.

## App (phase D)

A People tab, the fourth tab:
- Named people as circles, then "Unnamed" groups with Add name.
- A person screen: the photo grid, Rename, Merge, "Review N suggestions" (a grid of faces to
  confirm, where tapping marks one as wrong), and "Manage faces" (multi-select, then Not <name>,
  Move to…, Not a face).
- From a photo: the faces in it, each with its fix menu.
- Gallery search finds names, because the server handles them.
