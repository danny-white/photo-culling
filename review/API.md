# Culling Bay API, as the iPhone app uses it

The native app (`ios/`) is a front end over the same `/m/api` routes as the web pages in
`static/m`. This file lists the routes and fields the app depends on. `review/tests/test_mobile_api.py`
(`test_contract_*`) fails if one of these shapes changes, so change both together.

Base URL: `http://100.82.57.4:8000` (Tailscale; plain HTTP, allowed in the app's Info.plist).
Writes need the header `X-Culling-Bay: 1` and a JSON body.

**Caching.** JSON GETs carry an `ETag` and `Cache-Control: no-cache`. Send `If-None-Match` and
a `304` comes back with no body when nothing changed. Pictures (`/m/api/img`) are
cacheable for a day (`max-age=86400`) and support `If-Modified-Since`.

**Compression.** A JSON `200` of 1 KB or more is gzipped when the request says
`Accept-Encoding: gzip` (URLSession sends it and decodes the body itself): `Content-Encoding: gzip`,
`Vary: Accept-Encoding`, and the `ETag` becomes weak (`W/"..."`) because the compressed body is a
different representation. Send back whatever `ETag` came; it matches either way, so the `304` works
as before. Pictures, crops and downloads are never compressed.

**Timing.** Every response has a `Server-Timing` header (`total;dur=12.3, full_decode;dur=...`,
facts as `cache;desc="hit"`). The app can report its own measurements to `POST /m/api/perf`
(see `review/perf.py`). The server tells the app's lines from the web pages' by the User-Agent
URLSession sends (`CullingBay/<build> CFNetwork/...`): its timing lines get `app: "ios"`, and
its reports are logged as `device: "iphone"`, `app: "ios"`.

`?` after a type means it can be `null`.

## Days

`GET /m/api/days` → `{days: [Day]}`, newest first.

| Field | Type | Meaning |
|---|---|---|
| `day` | string | Library-relative folder, e.g. `2026/2026-10-01`. The id used in other routes. |
| `folder` | string | Last path part, e.g. `2026-10-01` |
| `date` | string? | ISO date, null for an undated folder |
| `frames` | int | Photos, counting bracket and pano partners |
| `stacks` | int | Stacks (a burst or bracket is one) |
| `thumbs` | [int] | Up to 3 photo ids for the day's row |
| `last_ts` | number | Latest capture time, epoch seconds |
| `place` | string? | The town most photos were near, lower case, `town, region, country` |
| `places` | [string] | Up to 4 towns |
| `gps_frames` | int | Photos with GPS |
| `summary` | string? | One-line summary of the day |
| `decided`, `sent`, `landed`, `conflicts`, `lr_done` | int | Cull progress (Cull tab) |
| `finished` | bool | Day finished in the cull |
| `unsent` | int | Decisions not yet sent to Lightroom: draft, or missing from the last sync. The web app's day rows show it ("N unsent", and "Finished, not sent" on a finished day) |
| `sent_at` | string? | When the day was last sent to Lightroom |

## Gallery

All three return photos in display order, plus the query's facts. `?best=1` keeps only photos
picked or rated 3★+ (Lightroom or phone) and not rejected. `?bursts=1` (the default) keeps one
photo per stack; `bursts=0` returns every frame.

- `GET /m/api/gallery/search?q=<text>` → `{query, total, signals, notes, photos: [Photo]}`
  (best match first; `total` counts every match before Best and bursts; at most 600 ranked)
- `GET /m/api/gallery/like/<id>` → `{total, signals, notes, photos: [Photo]}` (most similar first; 404 for an unknown id)
- `GET /m/api/gallery/day/<day>` → `{day, date?, summary?, photos: [Photo]}` (time order; 404 for an unknown day)

`signals` lists what matched: `words`, `captions`, `pictures`, `dates`, `people`. `notes` are sentences to
show when part of search is unavailable.

**People in a search.** `gallery/search` finds the people named in Culling Bay (see People below). A query
naming one or more of them (case does not matter) returns the photos they are all in: `alex smith`, or `alex`
when no other person has the first name Alex, or `alex sam` for the photos both are in. Whole names are looked
for first, then first names; the names are taken out of the query and what is left narrows to their photos.
With nothing else left (or only words like "photos of"), the answer is those photos, newest first, narrowed by
any dates in the query (`alex 2026-01`), with `signals: ["people"]` (and `"dates"` when dates were used). With
words left (`alex birthday`) the usual word, caption and picture matching runs among those photos only, and
`signals` is `"people"` plus what matched. A name no one has, or one two people share, is searched as an
ordinary word. `search` (days) and `like` do not look at names.

Photo:

| Field | Type | Meaning |
|---|---|---|
| `id` | int | Photo id for every picture route |
| `day` | string | Its day id |
| `date` | string? | ISO date |
| `ts` | number? | Capture time, epoch seconds of the camera's wall clock (show it in local time) |
| `file` | string | File name, e.g. `DSC05040.ARW`. Not unique: camera numbers wrap. |
| `bytes` | int? | Size of the original file |
| `camera`, `lens` | string? | |
| `caption` | string? | Machine caption (useful for search context; not always right) |
| `place` | string? | Nearest town, as in Day |
| `stars` | int | 0–5, the higher of Lightroom and phone |
| `picked`, `rejected` | bool | Lightroom or phone flag |
| `raw` | bool | The original is a RAW (ARW, NEF, CR2, CR3, DNG, ...) |

## People

Faces are found in every photo's preview (`photo_cull.py faces`), grouped by who they look like across the whole
library (`photo_cull.py faces-group`, which the ingest watcher runs after each shoot), and named in the app.
Danny's answers are the only thing stored; who is in which photo is worked out from them each time, so a
regrouping never undoes a correction. The design and the measurements behind the thresholds are in
`review/PEOPLE.md`.

A **face** is one detected face in one photo: its `id` is stable. A **group** is faces that look alike and
nobody has named; its `key` is its smallest face id, which stays put while that face stays in it. A **person**
has a name, the faces Danny confirmed and the faces the server filed under them.

Every face is in exactly one state, its `how`:

| `how` | Meaning |
|---|---|
| `confirmed` | Danny said so: named it, added it, answered "Is this ...?" with yes, or moved it there |
| `auto` | The server filed it: it sits in a group where 2/3 or more of the confirmed faces are that person, or it is 0.55+ alike to their confirmed faces and 0.10 clear of the next person. Never when Danny said it is not them. |
| `none` | Nobody's yet: a member of an unnamed group, or a suggestion (`Is this <name>?`: 0.40 to 0.55 alike) |

Faces Danny marked **Not a face** are hidden everywhere.

Until the first `faces-group` run, and on a database with no faces, `GET /people` is `200` with empty lists.
Everything is rebuilt when a grouping run finishes (looked for every 30 s at most); faces found since do not
show until the next run.

### Reads

- `GET /m/api/people` → `{people: [Person], groups: [Group], faces_checked, photos_ok}`. `people` has the
  named people, most photos first. `groups` has the unnamed groups worth naming: 3 or more faces nobody has
  claimed (a suggested face is not claimed), the groups with a good (sharp, surely-a-face) face on the most days
  first (friends and family above a one-day crowd), then most good faces, at most 300. A group that is
  probably not a person (under 2 good unclaimed faces, or a mean very like that of the library's low-confidence
  faces, which are mostly wheels, the backs of heads and blur) is left out, though its faces stay unclaimed and
  `people/group/<key>` still opens it. `faces_checked` is the number of photos checked for faces
  and `photos_ok` the number of photos in the library, so the app can say "faces found in N of M photos".
- `GET /m/api/people/<id>` → `{id, name, total, photos: [Photo]}`, newest first (404 for an unknown person).
  `?best=1` and `?bursts=` work as in Gallery; `total` counts the person's photos before them.
- `GET /m/api/people/group/<key>` → `{key, total, photos: [Photo]}`, newest first, for the group's unclaimed
  faces; the same flags (404 for an unknown group, `total: 0` for one with nothing left).
- `GET /m/api/people/<id>/faces?offset=0&limit=100` → `{total, faces: [{id, photo, how}]}` for the fix screen
  (`limit` 1 to 500, default 100; `400` for anything else). The faces the server filed itself come first, the
  least sure first (the likeliest mistakes), then the confirmed ones, newest photo first. `how` is `auto` or `confirmed`.
- `GET /m/api/people/<id>/suggestions` → `{faces: [{id, photo, sim}], groups: [Group]}`: up to 60 faces that
  may be this person, most alike first (`sim` is 0.40 to 0.55), and the unnamed groups whose `maybe` is them.
- `GET /m/api/photo/<id>/faces` → `{faces: [PhotoFace]}`, left to right; `404` for an unknown photo.
- `GET /m/api/face/<id>?s=small|large` → a square JPEG of the face, 160 or 480 px (default `small`). It is cut
  from the photo's 1616 px picture (the same file as `img?s=view`, made if missing; it never starts the RAW's
  full decode), with the box enlarged by 30%. Cacheable for a day like `img`: `ETag`, `Last-Modified`,
  `max-age=86400`. `404` for an unknown face, `415` for a photo that won't decode.

Person:

| Field | Type | Meaning |
|---|---|---|
| `id` | int | Person id, in every people route |
| `name` | string | As given, trimmed; 1 to 80 characters. No two people share a name, case aside. |
| `photos` | int | Photos with at least one face of theirs (confirmed or auto) |
| `faces` | int | Their faces, confirmed and auto |
| `cover` | int? | A face id for their picture: the one Danny chose, else the best confirmed face. `null` only when they have no faces left. |
| `suggestions` | int | Faces that may be them, for "Review N suggestions" |

Group:

| Field | Type | Meaning |
|---|---|---|
| `key` | int | Group id, in `group` of the writes and in `people/group/<key>` |
| `faces`, `photos` | int | Unclaimed faces in the group, and the photos they are in |
| `days` | int | How many different shoot folders they are from |
| `cover` | int | Face id of its best face |
| `maybe` | `{id, name}` | Only when the group looks 0.40+ like a named person, for "Is this Alex?". Absent otherwise. |

PhotoFace:

| Field | Type | Meaning |
|---|---|---|
| `id` | int | Face id |
| `box` | [number] | `[x0, y0, x1, y1]` as fractions (0 to 1) of the upright photo |
| `how` | string | As above |
| `person` | `{id, name}` | Only when `how` is `confirmed` or `auto` |
| `suggestion` | `{id, name}` | Only for a `none` face that may be that person |

### Writes

The same rules as Cull's writes (header, JSON object body). Unknown person, group or face ids are `404 {error}`;
a bad body is `400 {error}` (a name that is not 1 to 80 characters after trimming, a `faces` that is not a list of
ints, a missing field); a name that is taken is `409 {error, person}` with the existing Person, so the app can
offer "Add to <name>?". A write that fails changes nothing. Unless said otherwise, a write answers with the
changed Person.

`group` is a group key; naming or adding a group takes the faces in it nobody has claimed yet (the ones the
app shows), never ones already filed under someone else.

- `POST /m/api/people` `{name, group?, faces?}` → `201` with the new Person. At least one of `group` and
  `faces`, naming a face at least; each is a confirmed face (`named`).
- `POST /m/api/people/<id>` `{name?, cover?}` → rename and/or choose the cover face (`cover: null` goes back to
  the best confirmed face; `400` for a face that is not theirs; `409` for a taken name).
- `POST /m/api/people/<id>/add` `{group?, faces?}` → these faces are this person (`added`); a "not this person"
  on them is taken back. A face already someone else's becomes theirs.
- `POST /m/api/people/<id>/merge` `{into}` → all that was said about this person becomes `into`'s and this person
  is deleted; answers with `into`'s Person. Their "not" answers come too, except for a face that is `into`'s.
  `400` when `into` is the person itself.
- `POST /m/api/people/<id>/review` `{yes: [faces], no: [faces]}` → the answers to "Is this ...?": yes is a
  confirmed face, no means never suggest it for them again. A face in both lists is `400`.
- `POST /m/api/people/<id>/delete` → `{ok: true}`. Their confirmed and "not" answers are deleted; the faces
  go back to their groups.
- `POST /m/api/faces` `{faces: [ids], action, person?}` → fix faces. `action` is:
  - `not`: these faces are not `person` (the "Not Alex" of Manage faces): no longer theirs, never suggested for
    them again. Answers with `person`'s Person.
  - `move`: they are `person` (`moved`). Answers with `person`'s Person.
  - `ignore`: not a face, or a stranger: hidden everywhere. Answers `{ok: true}`.
- `POST /m/api/people/group/<key>/hide` → `{ok: true}`: hides the group's unclaimed faces like `ignore`.

### Lightroom: `people.tsv`

Named people reach Lightroom Classic as `People > <name>` keywords through the AI Cull plugin (2.3.0 and later).
The server writes the file `people.tsv` in the inbox (`AICullInbox/`, next to `pending.tsv` and
`cull-decisions.tsv`); it is not a route. Nothing is written when the server runs without the feed (the tests).

```
#people v1
2026-10-01<TAB>DSC05036.ARW<TAB>Alex|Sam
2026-10-01<TAB>DSC05037.ARW<TAB>
```

- One row per photo: shoot folder name, file name, the names in it joined by `|`. Rows are in folder and file order
  and the names alphabetical (case aside). Folder and file are what `pending.tsv` and `cull-decisions.tsv` use, so
  the plugin matches all three the same way.
- A photo's names are the people with a confirmed or an auto face in it. Suggestions ("Is this Alex?") don't count.
- `|` in a name becomes `/`, and tab, CR and LF become a space, as `write_plugin_data` does for keywords.
- The first line, `#people v1`, is how the plugin tells this file from the other two. The plugin's parsers skip `#` lines.
- Rows cover every photo that has ever been written with a name: `people_lr(path)` in `annotations.db` remembers them
  and never forgets. A photo whose last person was taken off (or whose person was deleted) keeps its row with an
  empty names field, which is how the plugin knows to remove the keyword it added.
- The whole state is written every time, never a change list.
- It is written 10 s after the last change (`people.FEED_DEBOUNCE_S`), on a timer thread: after a label write
  (naming, renaming, adding, merging, review, delete, not/move/ignore, hiding a group) and after the index is
  rebuilt for a new grouping run, since new faces are filed under named people on their own. It is also written once
  at server start, which covers a wiped inbox.
- Written to `people.tsv.tmp` in the same directory and renamed over `people.tsv`, so the plugin never reads half a
  file. When the inbox isn't mounted (the check Send uses) nothing is written and a line is logged; the photos named
  so far are still remembered, and the next change or restart writes the file.
- The plugin never moves or deletes `people.tsv`: it is the current state, and applying it again changes nothing.

## Practice

The challenge list is hand-maintained in `trial_out/mobile/practice.json`. Its `path` is resolved
against `images.path` on each list refresh and is never returned to the phone. Challenges keep the
file's order; entries whose photo is no longer in the library are omitted and counted in `missing`.
The file is re-read when its modification time changes. A missing file means an empty list; an
invalid file returns `{challenges: [], error}` without exposing file contents or paths.

- `GET /m/api/practice` → `{challenges: [PracticeChallenge], missing}`
- `POST /m/api/practice/<cid>` → `{ok, id, status, note, updated_at, downloaded_at, done_at}`
  (writes need `X-Culling-Bay: 1` and JSON; 400 for invalid fields, 404 for an unknown challenge)

PracticeChallenge contains the challenge file's fields other than `path`, plus:

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Stable challenge key used by the write route |
| `title` | string | Short challenge name |
| `mode` | string | `phone` or `mac` |
| `minutes` | int | Approximate time budget |
| `tools` | [string] | Allowed Lightroom tools |
| `aim`, `why` | string | Desired result and why the photo suits it |
| `hints` | [string]? | Optional editing suggestions |
| `level` | string | `easy`, `medium`, or `hard` |
| `picked_by`, `added` | string | Challenge attribution and date |
| `photo` | Photo | Gallery photo fields used for previews and original download |
| `status` | string | `todo`, `downloaded`, `done`, or `skipped`; no row means `todo` |
| `note` | string | Danny's note, up to 2000 characters |
| `updated_at` | string? | Last state update time |
| `downloaded_at`, `done_at` | string? | First download and completion times |
| `needs_desktop` | bool | Always present, `false` when the file omits it. The full challenge needs Lightroom Classic (Calibration, Enhance, ...), which Lightroom on the phone lacks. Show a **Needs Desktop** tag |
| `desktop_reason` | string? | One line saying which tool needs the desktop; `null` when absent |
| `companion_of` | string? | Id of the Needs Desktop challenge this is the on-the-go version of. `null` when the file has none **or the parent is not in this answer** (its photo is missing), so it then stands alone |
| `companions` | [string] | Ids, in file order, of the challenges in this answer whose `companion_of` is this id; usually empty |
| `lightroom` | object? | Absent when nobody has checked. Whether the photo is already in Lightroom on the phone, read **once** from Lightroom Classic's catalog when the challenge was written (nothing keeps it current): `albums` [string] are the synced albums it is in, smallest first (`[]` = not on the phone); `find_in` string? is the album to look in (the smallest), `null` when `albums` is empty; `captured` string? is Lightroom's capture time (local, no zone; it can be a day off Culling Bay's for photos whose time was shifted in Classic); `edited` bool says Classic already has edits on it; `checked` is the date of the check. With albums, show where to find it and that edits made there change the photo in Classic, and keep the download behind a tap; without, offer the download |

A Needs Desktop challenge and its companions are the same photo, each with its own status and note.
A *group* is a challenge without `companion_of` plus its companions, in file order. Place a group in
Waiting if any member is `todo` or `downloaded`, else in Done if any is `done`, else in Skipped, so a
pair stays together. `mode` stays informational (`mac` for the desktop version, `phone` for the companion).

The three new fields are optional in `practice.json`. A violation makes the whole file malformed:
`needs_desktop` must be a bool and `desktop_reason` a string when present (`null` is not accepted);
`companion_of` must name another challenge in the file that has `needs_desktop: true` and no
`companion_of` of its own; a challenge with `companion_of` must not have `needs_desktop: true`.
`lightroom`, when present, must be an object with `albums` a list of strings, `find_in` one of them or `null`,
`edited` a bool, `checked` a string and `captured` a string or `null`.

POST accepts `status` and/or `note`. Setting `downloaded` records the first download time. It does
not move a `done` challenge back; moving off `done` clears `done_at`. Setting `done` preserves its
first completion time until the challenge leaves that state.

## Cull

The Cull tab works one day at a time. Everything it writes is the phone's own state in
`annotations.db`; **Send** copies unsent decisions into the inbox file the Lightroom plug-in
reads, and the plug-in's receipts move them on (see `decision.state`).

### Day

`GET /m/api/day/<day>` → `{day, folder, date?, summary?, budget, stacks: [Stack], progress?}`
(404 `{error}` for an unknown day). Reading it also reads any new plug-in receipts, so a
decision's `state` is current.

| Field | Type | Meaning |
|---|---|---|
| `budget` | `{stacks, per_hour, hours, basis}` | The soft goal of stacks to keep (since 25 Nov 2026): a third of the day's stacks, rounded up, but no more than `per_hour` (10) per hour of shooting, a cap that is never below 5. So at least 1 for any day with photos, and 0 for none. `hours` is the shooting time (pauses over 10 min count as 10), 2 decimals. `basis` says which limit set the goal, for the note: `a third of 33 stacks`, `10 an hour for 1.2 h of shooting`, `the minimum of 5, for 11 min of shooting`, `the day’s one stack`; empty for a day with no stacks. |
| `progress` | `{pass, cursor}?` | Where the last session stopped; null until the first progress save, including after Send. When present, `pass` and `cursor` are ints. |

Stack (stacks are in shot order):

| Field | Type | Meaning |
|---|---|---|
| `id` | int | Position in this response (0, 1, 2 ...). What `progress.cursor` refers to. Positions can change when photos are added. Save progress with `lead` so the cursor follows that photo's stack. |
| `kind` | string | `single`, `burst`, `bracket` or `pano`. Brackets and panoramas suggest Keep all. `pano` shows only once a pixel check has confirmed 3+ frames that slide one way: either one burst, or separate presses each within 3 s of the last (a hand-held sweep, which the camera numbers as presses), joined into one stack. |
| `lead` | int | Frame `id` to show first: the sharpest frame; a bracket's base exposure |
| `frames` | [Frame] | In shot order. A single stack has one frame. |

Frame:

| Field | Type | Meaning |
|---|---|---|
| `id` | int | Photo id for every picture route and for `decide`. A RAW with a same-name JPEG is one frame (the RAW); the JPEG rides along. |
| `file` | string | File name, e.g. `DSC05040.ARW` |
| `partners` | [string] | File names that ride along (the JPEG of a RAW+JPEG pair) |
| `partner_ids` | [int] | Their photo ids, same order |
| `sharpness` | number? | Higher is sharper. Only comparable inside one burst. |
| `af` | [number]? | `[u, v]`: autofocus point as fractions of the upright frame; null when the camera did not record one |
| `badges` | [string] | Measured hints, at most one: `Blown` (over 15% pure white), `Dark` (mean brightness under 35 of 255), `Softer` (under 35% of the sharpest frame in its burst). Always empty inside a bracket. Show as given. |
| `lr` | `{pick, rating, by, stars_by}?` | What Lightroom held at the last sync that covered the photo; null if none did |
| `decision` | `{flag, stars?, note, state, outcome?}?` | The phone's decision; null if none |
| `lens`, `caption`, `place` | string? | As in Photo |
| `blown_pct`, `mean_lum` | number? | Share of pure-white pixels (0 to 100), mean brightness (0 to 255) |

`lr.pick` is `1` picked, `0` unflagged, `-1` rejected. `lr.rating` is 0 to 5. `lr.by` says who set the
flag and `lr.stars_by` who set the stars: `you` (by hand in Lightroom), `phone` (the plug-in, from a Send)
or `""` (nobody). Only `you` should count as "already culled in Lightroom": the web app reads
`by == you && pick == -1` as rejected, `by == you && pick == 1` as picked, and
`stars_by == you && rating > 0` as rated.

`decision.flag` is `pick`, `reject` or `none`. `decision.stars` is 1 to 5 or null, and only a `pick`
has any. `decision.note` is `""` when empty. `decision.state`:

| state | Meaning |
|---|---|
| `draft` | Saved on the phone only. Every `decide` sets it back to `draft` and clears `outcome`. |
| `queued` | Sent: written to the inbox file, waiting for the Mac's next Lightroom sync |
| `landed` | The plug-in applied it. `outcome` is null or `your N kept` (Lightroom already had your own star rating, which was kept). |
| `conflict` | Your own flag in Lightroom was kept instead. `outcome` is the plug-in's text for what it kept. |
| `missing` | The photo was not in the Lightroom selection. `outcome` is `not in the Lightroom selection`. It is sent again by the next Send. |

### Search for days

Both give the days to open in the Cull tab (not photos; for photos see Gallery).

- `GET /m/api/search?q=<text>` → `{query, days: [DayMatch], photos, signals, notes}` (400 `{error: "missing q"}`;
  `q` is cut to 200 characters)
- `GET /m/api/like/<id>` → `{days: [DayMatch], photos, signals, notes}` (no `query`; 404 `{error}` for an unknown
  photo). Never includes the photo's own day. A photo that is not indexed yet gives `days: []` and a note.

`photos` is the number of matching photos (int). `signals` and `notes` are as in Gallery. At most 40 days,
best first. A query of only dates (`2026-10`, `2019`, `june 2015`) lists up to 200 days in that span, newest first, with `photos: 0`, `signals: ["dates"]` and `n: 0` on each.

DayMatch:

| Field | Type | Meaning |
|---|---|---|
| `day` | string | Day id |
| `n` | int | Matching photos in the day. `0` when the day matched by its summary or a town only, or by date only. |
| `ids` | [int] | Up to 4 matching photo ids, best first (for thumbnails) |
| `match_ids` | [int] | Up to 400 matching ids. The web app moves stacks containing one to the front of the day. |
| `why` | string | One line to show, e.g. `3 photos · “a chick in a burrow”`, `Near Greenwood`, `In the day’s summary`, or `""` (date-only) |

### Writes

Every write needs `X-Culling-Bay: 1` (`403 {error}` without it) and `Content-Type: application/json`.
An existing body sent without a JSON content type also gets `403 {error}`.
A missing, invalid, null or non-object JSON body gets `400 {error}`. `send` and `reset` accept `{}`.
Errors are `{error: string}` unless more fields are listed. A `400` means the request itself is wrong: do not retry it.
Booleans do not count as ints.

**`POST /m/api/decide`**: one tap.

```
{action_id, day, label?, changes: [{id, flag, via, stars?, note?}]}
```

| Field | Meaning |
|---|---|
| `action_id` | Any unique non-empty string you make up (the web app uses time plus 12 random bytes in hex). Keep it: it is what `undo` takes. |
| `day` | Non-empty day id string; every change must be a frame of that day |
| `label` | String kept with the action; `""` if omitted or null. The web app puts the toast text, e.g. `Kept DSC05050 ★3 · 1 rejected with a note`. Nothing reads it back. |
| `changes` | Non-empty list of objects |
| `changes[].id` | A frame `id` (or a `partner_ids` entry). Required, an int. |
| `changes[].flag` | `pick`, `reject` or `none` (`none` takes a flag back off) |
| `changes[].via` | `card` (a decision on the card), `burst` (from the burst picker), `rescue` (a photo pulled back from the reject pile) or `sweep` (the web app no longer sends it) |
| `changes[].stars` | For `pick`, an int from 1 to 5, null or omitted. For `reject` and `none` it is dropped. |
| `changes[].note` | String; `""` if omitted or null. The web app writes `Burst reject · kept DSC05050, DSC05051` on the rejected frames of a burst it kept frames of. |

→ `{ok: true}`. A change replaces whatever decision the frame had and sets it to `draft`. All changes in one
call are one action. A pick or reject on a RAW is also written for its `partners` at Send time.
Replacing a `queued` decision withdraws its inbox rows, including partners. `503 {error}` if those rows
need withdrawing but the inbox is unavailable; nothing changes.

**Replay.** If `action_id` was seen before (a retry after a dropped response, or after the action was undone) the
call does nothing and answers `{ok: true, replay: true}`. The body is not compared. Validation runs first, so a bad
body still gets 400. To decide again after an undo, use a new `action_id`.

`400` for missing or invalid fields above; an unknown frame id, or one from another day.

**`POST /m/api/undo`**: `{action_id}` → `{ok: true}`. Puts the rows back exactly as they were before that
action (a frame that had no decision loses it). `{ok: true, replay: true}` if already undone; `404` for an
unknown `action_id`. `400` if `action_id` is not a non-empty string. It reads new plug-in receipts first.
Current `queued` rows and their partners
are withdrawn. Restored `queued` decisions go back into the inbox.
`409 {error, applied}` if `applied` current decisions from this action are `landed` or `conflict`;
nothing changes. `503 {error}` if withdrawing or restoring queued rows needs an unavailable inbox;
nothing changes. Replaying an already-undone action has no side effects.

**`PUT /m/api/day/<day>/progress`**: `{pass, cursor, lead?, finished?}` → `{ok: true}`. `pass` is the int 1 or 2
(the web app always uses 2 now) and `cursor` an int (a stack `id`); anything else is `400`.
`lead`, if present and not null, must be an int frame id from this day; unknown ids and ids from another day get `400`.
The server stores that photo's library path. On the next day read, `progress.cursor` is the current position
of the stack containing that photo, including as a pair partner. If the path is absent, it falls back to the
saved integer cursor. Omitting `lead` (or sending null) clears the path and saves only the integer cursor, as older clients do.
`finished`, if present, must be a bool (`400` otherwise). `finished: true` marks the day
finished (the `finished` field in Days). It can't be turned off again except by `reset`; `finished: false` leaves
it as it was. The web app saves 600 ms after the last move, and at once with `finished: true` when the last
open stack is decided. On opening a day it jumps to the stack whose `id` is `progress.cursor`.

**`POST /m/api/day/<day>/send`**: body `{}` → `{ok: true, queued, file_rows}`. Queues the day's `draft` and `missing`
decisions for the next Lightroom sync (they become `queued`). `queued` is the number of decisions; `file_rows` the
rows written to the inbox file, which counts pair partners too. Both are 0 when nothing was new, and that
is still `ok`. Also stamps `sent_at` on the day. `503 {error}` when the inbox share is not mounted; nothing is
sent. The web app waits for its own queued writes to land first, so the day is sent whole.

**Offline copies.** The app saving days for offline asks for pictures with `warm=0` (no decode-ahead) and
for 1:1 crops with `keep=0`. Such a crop of a RAW not already in memory is decoded for the crop's area only
(`review/region_decode.py`, ~0.35 s against ~1.4 s for the whole frame; the same colour and brightness as the full
decode), two at a time beside the decodes someone is waiting for, and nothing is kept in the server's decode
cache. A RAW the region decode can't read (not a 2x2 Bayer sensor) is decoded whole instead.

**`POST /m/api/send`**: body `{days: [day, ...]}` → `{ok: true, queued, file_rows, days: [{day, queued}]}`.
Send for several days at once (Send all: the app's Cull tab, and the web app's Days list): the same as `day/<day>/send` for each, in one write to
the inbox file, each day stamped `sent_at`. `400 {error}` unless `days` is a non-empty list of strings; `404
{error}` naming an unknown day (nothing is sent); `503 {error}` when the inbox share is not mounted.

**`POST /m/api/day/<day>/reset`**: body `{}` → `{ok: true, cleared, withdrawn}`. Clears all the day's decisions,
progress and finished flag, and takes `queued` rows back out of the inbox file (`withdrawn` counts file rows).
`cleared` is the number of decisions removed. `409 {error, applied}` when `applied` of them are `landed` or
`conflict`: the phone can't take those back. `503 {error}` when rows are queued but the inbox is not mounted;
nothing is reset. Lightroom flags and stars are never touched.

`progress`, `send` and `reset` return `404 {error: "no such day"}` for an unknown day.
A day is known if it has library rows or retained phone decisions or progress/Send state.
This allows resetting a day whose folder vanished.

**Order.** Both clients send their writes one at a time, in order, from a queue they keep (the web app's is
in `localStorage`, shared by its tabs, with one tab sending at a time), and drop a request after a 4xx; a 5xx
or no answer (the web app gives up on a request after 15 s) is retried unchanged, which is safe because
`decide` is idempotent by `action_id` and the others are idempotent by nature. A `decide` followed by its `undo`
must not overtake each other. A `409` to an `undo` means the tap is still in force: both clients put its
decisions back and say "Not undone". The web app also puts a card back when its `decide` gets another 4xx,
and keeps a "N taps not saved" banner up until it is dismissed. It keeps only the newest queued `progress`
per day. Opening a day, both lay the queued taps for it over what `day/<day>` returned.

## Pictures

| Route | Returns |
|---|---|
| `GET /m/api/img/<id>?s=thumb` | JPEG, longest side 320 |
| `GET /m/api/img/<id>?s=view` | JPEG, longest side 1616 (a RAW's embedded preview) ; asking for it starts the RAW's full decode in the background (decode-ahead) unless `&warm=0` |
| `GET /m/api/ping` | `204`, no body. The iPhone app's connection check: it touches no database or file, so an answer means only that the PC can be reached. |
| `GET /m/api/warm?ids=<id>,<id>` | `204`, no body. Queues the named RAWs' full decodes in the background, most urgent first, at most 4, as a `view` picture request would. For cards the phone shows from its own saved copy (offline days), whose pictures never reach the server. Unknown ids, non-RAW files and junk are skipped. |
| `GET /m/api/info/<id>` | The camera details for the app's (i) sheet, read from the file with exiftool when first asked (~0.1 s) and kept in memory: `file`, `format`, `bytes`, `width`, `height`, `megapixels`, `camera` (e.g. "Sony ILCE-7RM3"), `make`, `model`, `lens`, `iso`, `shutter_s` (seconds), `aperture` (f-number), `focal_mm`, `focal_35mm`, `ev`, `program`, `metering`, `flash`, `white_balance`, `focus_mode` (exiftool's words), `taken` ("YYYY:MM:DD HH:MM:SS[.sub]", the camera's clock), `offset` ("-07:00"), `gps` ([lat, lon]), `place` (the nearest town, from the index). Anything the file lacks is `null`. `404` unknown id; `503 {error: "photo storage unavailable"}` when the NAS can't be reached; `415` when exiftool reads nothing. |
| `GET /m/api/face/<id>?s=small` | JPEG, 160 px square: a face (`large` is 480). See People. |
| `GET /m/api/export/<id>?s=large` | JPEG, longest side 3000, decoded from the original (about 1.5 s for a cold RAW) |
| `GET /m/api/crop/<id>?x=&y=&w=&h=` | JPEG crop at full resolution: centre `x`,`y` as fractions of the upright frame, `w`,`h` in source pixels (64–2400). Header `X-Crop-Box: left,top,w,h of WxH` gives the box actually cut and the full size. |
| `GET /m/api/export/<id>` | Full-size JPEG for saving: a RAW is decoded, with capture time and GPS in its EXIF; a JPEG or HEIC original is sent as it is. `?dl=1` makes it a download. |
| `GET /m/api/export/<id>?s=original` | The original file untouched (a RAW for editing), always a download, `Content-Disposition` carries the file name |

Unknown ids give `404` JSON `{error}`; a file that won't decode gives `415` JSON `{error}`.

## Pipeline health (for the Pi status page, not the app)

`GET /m/api/pipeline-health` returns `{status: ok|warn|bad, alerts: [{level, title, detail, fix}], index, model,
last_ingest, recent, checked_at}`. Every alert is worked out from the pipeline's current state, so it clears
itself once fixed. The failed-photo alerts and the `index` fields that go with them:

| Alert | When | `index` field |
|---|---|---|
| `N photos waiting for a retry` (warn) | rows with `status='error'` that another try can help: `size > 0`, `error_class != 'empty'`, `attempts < 4`. The watcher retries them every 15 minutes. | `retrying` |
| `N originals can't be read` (warn) | error rows that no retry will help: `size = 0`, `error_class = 'empty'` or `attempts >= 4`, minus the paths in `trial_out/known-unreadable.txt` (one path per line, `#` starts a comment, a missing file is an empty list) | `unreadable` (after that list), `acknowledged_unreadable` (the ones it removed), `unreadable_files` (up to 100 of `{path, size, error}`, sorted by path) |

`index.caption_errors` is every error row, retry or not, and is unchanged: the Pi dashboard may read it.

`Faces not grouped into people yet` (warn) appears when faces have been found at the current face version but
`face_groups_meta` has no `computed_at` (the `faces-group` step has never run); `People grouping is out of date`
(warn) when the last grouping is over a day older than the newest face. Both say to run
`photo_cull.py faces-group --db trial_out/trial.db`. A `faces-group FAILED` line in the log counts as resolved
once neither alert is showing.

`Ingest watcher hasn't run for N hours` (bad) appears when the ingest log exists and nothing has been written
to it for over 2 hours. The watcher writes a `poll: ...` line at least once an hour, even when nothing
changed. The log file's own modification time counts as activity too, because one long run can go hours
without a timestamped line while it writes the log all the time. `last_poll` is the time of the newest
timestamped line in the log (ISO, or `null` when there is no log). `poll:` lines are never read as failures.
