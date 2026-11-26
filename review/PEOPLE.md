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

**What a "no" teaches** (added 2026-11-26). A `face_no` row takes P off that one face. Once P has
`NEG_MIN` (3) of them, it also teaches: `n_P(f)` is the mean of f's top 3 similarities to P's refused
faces, the same sum as `s_P`. A face with `n_P >= s_P + NEG_MARGIN` (0.10), much more like the faces
Danny said are not P than like P, counts as a `face_no` for P in rules 3–5 and in the groups' `maybe`.
Nothing is written: it is worked out again from the labels on every change, so it can't outlive the
answers it comes from.

Measured on the live labels that day. One person had 125 refused and 78 confirmed review answers.
Leaving each out in turn, the rule at 0.10 caught 80 of the 125 refusals and 1 of the 78 confirmations
(0.05: 105 and 6; 0.00: 118 and 6). Using only refusals from other days, it caught 65 and 1. On the
library it took that person off 354 photos (1,610 to 1,256), almost all through the group rule, and their
suggestions fell from 459 to 45. Only 5% of those faces were good faces. Nobody else changed.
The other three people with refusals had too few, or refusals unlike each other: eight refused faces
about 11 px across taught nothing. So a "yes" always teaches, through the confirmed set, and a "no"
teaches once there are a few alike.

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
- `GET /people/<id>/doubts` returns `{faces: [{id, photo, sim}], groups: []}` for "Maybe not <name>?": up to 60 of the faces filed under them automatically with `s_P` under 0.55 (`DOUBT_SIM`), which only the group rule filed, least sure first. Person JSON has their count as `doubts`. The answers go to `review`. (Added 2026-11-26: Danny asked for a way to catch the PC being over-eager.)
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

## App (phase D): CullingBayCore (Linux-tested) + SwiftUI views (Mac)

Follow the app's existing split: screen state lives in `CullingBayCore` as `@MainActor
@Observable` models with swift-testing tests (they run on the PC), and the SwiftUI views in
`ios/CullingBay/` stay thin.

### Core
- **Models** (`Codable`, `Sendable`, `Hashable`) for each People shape in API.md: Person, FaceGroup (`key`), PersonFace (`{id, photo, how}`), Suggestion (`{id, photo, sim}`), PhotoFace (`{id, box, person?, how}`), and the `/people` envelope.
- **Client** (`CullingBayClient+People.swift`):
  - one method per People route, with the same ETag/`Fetched` handling the other reads use, and writes through `writeJSON`;
  - a 409 on a name becomes a typed error carrying the existing person's id, so the UI can offer "Add to <name>?";
  - `faceURL(id:size:)` for the crops, built like `imageURL`.
- **`FeedModel.Source`** gains `.person(Int, name: String)` and `.group(Int)`, loaded from `/people/<id>` and `/people/group/<key>` with the same best and bursts flags. A person's photo grid is then the existing ResultsView, viewer and save included.
- **Screen models:**
  - `PeopleHomeModel`: loads `/people`. It holds `people`, `groups` and the "finding faces" progress (`faces_checked` of `photos_ok`), plus a name filter.
  - `PersonModel`: one person. Holds the header and suggestion count, and does rename, merge, delete and cover.
  - `GroupModel`: an unnamed group. Holds the `maybe` person, and does Add name (new, or an existing person via the 409 path), "Is this <maybe>?" yes/no (yes = add to that person; no = `POST /faces` action `not` for its faces and that person), and Hide.
  - `ReviewModel`: the suggestions for one person, in batches of up to 60 faces, every face starting as "yes". Tap toggles a face to "no". Confirm sends one `review`, then loads the next batch until none are left. Suggested groups come first ("These photos might be <name>": Yes / No).
  - `ManageFacesModel`: a person's faces, paged (offset/limit 120), with multi-select. Actions: Not <name>, Move to… (a person, or a new person), Not a face, and Make cover (single face only). Faces disappear as they're acted on.
  - `PhotoFacesModel`: the faces in one photo, each with its fix actions. The same three actions apply to an unnamed face, as "This is…" and "Not a face".
  - `PersonPickerModel`: named people filtered by typed text, plus "New person…".
- **Tests**: models decode the API.md examples; each screen model's states and actions run against the existing fake transport in the tests.

### Views (SwiftUI, compile on the Mac only)
- **People tab:** the fourth tab in `RootView`, "People", with the icon `person.2`. It's a NavigationStack with:
  - a "Finding faces… N of M photos" line while the backfill or an import is running;
  - a **People** grid of circles, 3 per row, each with the face crop, name and photo count, plus a small dot when suggestions > 0;
  - a **Not named yet** grid of group circles, each labelled "N photos · M days", or "<name>?" when `maybe` is set;
  - pull to refresh;
  - `.searchable` filtering by name.
- **Person screen** (pushed):
  - the header: a big circle, the name and the photo count;
  - a "Review N more photos" banner when there are suggestions;
  - then the photos as ResultsView for `.person`.
  - Select: the selection bar gets a "Not <first name>" button (red, next to Clear and Save to phone) that takes the person off every selected photo in one write. No confirm: one toast says "Removed <name> from 12 photos" (and "(2 didn't have <name>'s face)" when some had none; those stay), with one Undo for all of them. When none of the photos had their face the toast says so and the selection stays.
  - Toolbar menu: Rename, Merge with… (person picker), Manage faces, Remove name (with a confirm).
- **Group screen** (pushed):
  - the header circle and "N photos · M days";
  - Add name (a text field that lists matching existing people as you type);
  - "Is this <maybe>?" Yes / No, when set;
  - Hide ("Not someone I know");
  - then the photos as ResultsView for `.group`.
- **Review screen** (sheet):
  - "Is this <name>?" above a 3-column grid of large face crops;
  - tapping toggles a red ✕ overlay;
  - "None are <name>" under the subtitle puts the ✕ on every face of the batch (for when none of them are); it then reads "Clear all" and takes them all off. It sends nothing;
  - Confirm sends the batch: "Confirm 58 as <name>", "Confirm 56 as <name>, 2 not", or "Confirm 8 as not <name>" when every face is a no;
  - Done when nothing is left.
- **Manage faces** (pushed from the person menu):
  - a face grid with Select;
  - a bottom bar with Not <name>, Move to…, Not a face;
  - long-press for Make cover and Show photo;
  - auto faces have a thin outline, confirmed ones none.
- **From any photo:** the (i) sheet (`Shared/`, opened from the Gallery viewer, the Cull card and the burst picker) gets a **People** section listing the faces in the photo.
  - Each face shows a small crop and the name, or "Unnamed".
  - Tapping one opens a menu: Not <name> / This is… / Not a face.
  - This is the "flag or fix when something's wrong" path Danny asked for. A change refreshes the sheet.
- **Launch args** for simulator screenshots (read-only, like `-CBStartTab cull`): `-CBStartTab people`, `-CBOpenPerson <id>`.
- **Offline:** People needs the PC. Show the existing offline banner and keep nothing on the phone.

## Lightroom (phase E)

- **Server:** `review/people.py` writes `AICullInbox/people.tsv` whenever named-people assignments change, debounced by 10 s. Write it atomically: a temp file, then rename.
  - Each row: `shootFolder \t filename \t name1|name2|...`.
  - Confirmed and auto faces both count; suggestions don't.
  - Rows cover every photo that has ever had a named person, so a photo whose last name was removed still gets a row with an empty list.
  - Keep that sticky set in annotations.db (`people_lr(path TEXT PRIMARY KEY)`).
  - `|` and tabs in names are replaced, as `write_plugin_data` does.
- **Plugin:**
  - `CullCore.lua` gets `parsePeopleLine` and the pure set logic (`peopleChanges(desired, previouslySet, current)` → `{add, remove}`), tested under `lua5.1` like the existing rules.
  - `Sync.lua` reads `people.tsv` when it's present, next to `pending.tsv` and `cull-decisions.tsv`.
  - It creates the parent keyword `People` (not exported) and one child per name (exported), cached like `keywordFor`.
  - Per photo:
    - add the desired names it lacks;
    - remove only the names the plugin set before, as recorded in a new plugin metadata field `peopleSet` (pipe-joined, hidden, no `dataType`: Lightroom trap) that are no longer desired;
    - store the desired set in `peopleSet`.
  - It never removes a keyword it didn't set.
  - The receipt counts people added and removed.
- **As built (2.3.0):**
  - The file is described in [`API.md`](API.md) (People, "Lightroom: `people.tsv`"). Its first line is `#people v1`, which is how the plugin tells it from the other two inbox files.
  - `peopleChanges` takes names without regard to case and returns `add, remove`. A name set last time that is no longer on the photo (Danny took it off by hand) is not in `remove`: there is nothing left to take off.
  - `peopleSet` is the *desired* set after each sync, as written above. So a `People > Alex` that Danny added by hand to a photo Culling Bay also names Alex is the plugin's from then on, and goes if Culling Bay later drops Alex from it. Any other keyword, under People or not, is never removed.
  - The plugin leaves `people.tsv` in the inbox, where it moves `pending.tsv` and `cull-decisions.tsv` to `applied/`. They are batches of work that the next one must not repeat. This file is the whole current state: a sync of part of the library (or the launch offer, which covers the shoots it names) must not use it up for the photos it didn't reach, shoots not imported yet still need it later, and a second run changes nothing.
  - A repeat sync reads the keywords of the photos with names (or with something of the plugin's on them) and writes nothing when they match. The launch offer decides from the hidden field alone, with no per-photo calls, and asks only when a photo's names differ from what the plugin last set, so a file that stays in the inbox doesn't ask at every launch.
  - The receipt gets one comment line, `#people photos=N added=A removed=R`; the server's receipt reader skips `#` lines.
  - `schemaVersion` in `AICullMetadata.lua` went from 1 to 2 for the new field.
- **Mac install:** the plugin needs the usual Mac install. Quit Lightroom, replace the plugin folder and restart, because a new metadata field needs a full restart. Danny tests it on a scratch catalog first: a Needs-Danny issue.
