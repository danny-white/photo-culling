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
