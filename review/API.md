# Culling Bay API, as the iPhone app uses it

The native app (`ios/`) is a front end over the same `/m/api` routes as the web pages in
`static/m`. This file lists the routes and fields the app depends on. `review/tests/test_mobile_api.py`
(`test_contract_*`) fails if one of these shapes changes, so change both together.

Base URL: `http://100.82.57.4:8000` (Tailscale; plain HTTP, allowed in the app's Info.plist).
Writes need the header `X-Culling-Bay: 1` and a JSON body.

**Caching.** JSON GETs carry an `ETag` and `Cache-Control: no-cache`. Send `If-None-Match` and
a `304` comes back with no body when nothing changed. Pictures (`/m/api/img`) are
cacheable for a day (`max-age=86400`) and support `If-Modified-Since`.

**Timing.** Every response has a `Server-Timing` header (`total;dur=12.3, full_decode;dur=...`,
facts as `cache;desc="hit"`). The app can report its own measurements to `POST /m/api/perf`
(see `review/perf.py`).

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
| `sent_at` | string? | When the day was last sent to Lightroom |

## Gallery

All three return photos in display order, plus the query's facts. `?best=1` keeps only photos
picked or rated 3★+ (Lightroom or phone) and not rejected. `?bursts=1` (the default) keeps one
photo per stack; `bursts=0` returns every frame.

- `GET /m/api/gallery/search?q=<text>` → `{query, total, signals, notes, photos: [Photo]}`
  (best match first; `total` counts every match before Best and bursts; at most 600 ranked)
- `GET /m/api/gallery/like/<id>` → `{total, signals, notes, photos: [Photo]}` (most similar first; 404 for an unknown id)
- `GET /m/api/gallery/day/<day>` → `{day, date?, summary?, photos: [Photo]}` (time order; 404 for an unknown day)

`signals` lists what matched: `words`, `captions`, `pictures`, `dates`. `notes` are sentences to
show when part of search is unavailable.

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
| `budget` | `{stacks, per_hour, hours}` | Soft limit of stacks to keep: `per_hour` (10) per hour of shooting, at least 5. `hours` is the shooting time (pauses over 10 min count as 10), 2 decimals. |
| `progress` | `{pass, cursor}?` | Where the last session stopped; null until the first progress save. **After a Send with no saved progress it is `{pass: null, cursor: null}`**, so both can be null. |

Stack (stacks are in shot order):

| Field | Type | Meaning |
|---|---|---|
| `id` | int | Position in this response (0, 1, 2 ...). What `progress.cursor` refers to. Not stable if photos are added to the day. |
| `kind` | string | `single`, `burst`, `bracket` or `pano`. Brackets and panoramas suggest Keep all. `pano` shows only once a pixel check has confirmed a burst of 3+ frames that slides one way. |
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

Every write needs `X-Culling-Bay: 1` and `Content-Type: application/json`, or it gets `403 {error}`.
Errors are `{error: string}`. A `400` means the request itself is wrong: do not retry it.

**`POST /m/api/decide`**: one tap.

```
{action_id, day, label?, changes: [{id, flag, via, stars?, note?}]}
```

| Field | Meaning |
|---|---|
| `action_id` | Any unique string you make up (the web app uses time plus 12 random bytes in hex). Keep it: it is what `undo` takes. |
| `day` | Day id; every change must be a frame of that day |
| `label` | Free text kept with the action; `""` if omitted. The web app puts the toast text, e.g. `Kept DSC05050 ★3 · 1 rejected with a note`. Nothing reads it back. |
| `changes[].id` | A frame `id` (or a `partner_ids` entry). Required, an int. |
| `changes[].flag` | `pick`, `reject` or `none` (`none` takes a flag back off) |
| `changes[].via` | `card` (a decision on the card), `burst` (from the burst picker), `rescue` (a photo pulled back from the reject pile) or `sweep` (the web app no longer sends it) |
| `changes[].stars` | 1 to 5. **Kept only for `pick`**; for `reject` and `none` it is dropped. Not range-checked. |
| `changes[].note` | Free text. The web app writes `Burst reject · kept DSC05050, DSC05051` on the rejected frames of a burst it kept frames of. |

→ `{ok: true}`. A change replaces whatever decision the frame had and sets it to `draft`. All changes in one
call are one action. A pick or reject on a RAW is also written for its `partners` at Send time.

**Replay.** If `action_id` was seen before (a retry after a dropped response, or after the action was undone) the
call does nothing and answers `{ok: true, replay: true}`. The body is not compared. Validation runs first, so a bad
body still gets 400. To decide again after an undo, use a new `action_id`.

`400` for: missing `action_id`, `day` or `changes`; a change with a flag or via outside the lists above or a
non-int `id`; an unknown frame id, or one from another day.

**`POST /m/api/undo`**: `{action_id}` → `{ok: true}`. Puts the rows back exactly as they were before that
action (a frame that had no decision loses it). `{ok: true, replay: true}` if already undone; `404` for an
unknown `action_id`.

**`PUT /m/api/day/<day>/progress`**: `{pass, cursor, finished?}` → `{ok: true}`. `pass` is 1 or 2 (the web app
always uses 2 now) and `cursor` an int (a stack `id`); anything else is `400`. `finished: true` marks the day
finished (the `finished` field in Days). It can't be turned off again except by `reset`; `finished: false` leaves
it as it was. The web app saves 600 ms after the last move, and at once with `finished: true` when the last
open stack is decided. On opening a day it jumps to the stack whose `id` is `progress.cursor`.

**`POST /m/api/day/<day>/send`**: body `{}` → `{ok: true, queued, file_rows}`. Queues the day's `draft` and `missing`
decisions for the next Lightroom sync (they become `queued`). `queued` is the number of decisions; `file_rows` the
rows written to the inbox file, which counts pair partners too. Both are 0 when nothing was new, and that
is still `ok`. Also stamps `sent_at` on the day. `503 {error}` when the inbox share is not mounted; nothing is
sent. The web app waits for its own queued writes to land first, so the day is sent whole.

**`POST /m/api/day/<day>/reset`**: body `{}` → `{ok: true, cleared, withdrawn}`. Clears all the day's decisions,
progress and finished flag, and takes `queued` rows back out of the inbox file (`withdrawn` counts file rows).
`cleared` is the number of decisions removed. `409 {error, applied}` when `applied` of them are `landed` or
`conflict`: the phone can't take those back. `503 {error}` when rows are queued but the inbox is not mounted;
nothing is reset. Lightroom flags and stars are never touched.

`send` and `reset` don't check that the day exists: an unknown day answers `ok` with zeros.

**Order.** The web app sends its writes one at a time, in order, from a queue saved on the phone, and drops a
request after a 4xx; a 5xx or no connection is retried unchanged, which is safe because `decide` is idempotent
by `action_id` and the others are idempotent by nature. A `decide` followed by its `undo` must not overtake
each other.

## Pictures

| Route | Returns |
|---|---|
| `GET /m/api/img/<id>?s=thumb` | JPEG, longest side 320 |
| `GET /m/api/img/<id>?s=view` | JPEG, longest side 1616 (a RAW's embedded preview) |
| `GET /m/api/export/<id>?s=large` | JPEG, longest side 3000, decoded from the original (about 1.5 s for a cold RAW) |
| `GET /m/api/crop/<id>?x=&y=&w=&h=` | JPEG crop at full resolution: centre `x`,`y` as fractions of the upright frame, `w`,`h` in source pixels (64–2400). Header `X-Crop-Box: left,top,w,h of WxH` gives the box actually cut and the full size. |
| `GET /m/api/export/<id>` | Full-size JPEG for saving: a RAW is decoded, with capture time and GPS in its EXIF; a JPEG or HEIC original is sent as it is. `?dl=1` makes it a download. |
| `GET /m/api/export/<id>?s=original` | The original file untouched (a RAW for editing), always a download, `Content-Disposition` carries the file name |

Unknown ids give `404` JSON `{error}`; a file that won't decode gives `415` JSON `{error}`.
