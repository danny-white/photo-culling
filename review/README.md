# Run monitor + Culling Bay Mobile (local web app)

`review/server.py` serves two things on port 8000:

- **`/`** — the run monitor for `photo_cull` ingest: progress, throughput, errors and GPU, with
  controls to steer the runs. Nothing is ever written to the NAS.
- **`/m`** — Culling Bay on a computer: culling, search, the gallery and Practice (below). On the
  iPhone, Culling Bay is the native app (`ios/`); its builds are served at `/m/ios/`.

The desktop page's Review, Search, Bursts, Feedback and Tune tabs were retired on 2026-10-17:
the AI verdicts, stars and burst picks weren't used for culling, and `/m` covers culling and search.
`/api/semantic_search` stays, because the Lightroom plugin's semantic search command calls it.

## Run

```bash
./venv/bin/python review/server.py \
    --db trial_out/trial.db \
    --log trial_out/run.log \
    --folders /mnt/passport/Pictures/2024 /mnt/passport/Pictures/2025
```

Open **http://127.0.0.1:8000**.

- Reads the cull DB **read-only** (WAL-safe while a run is in progress).
- The phone app's decisions go to a **separate** annotations DB (default `<db>.annotations.db`),
  so there is zero write-contention with the running culler.
- Thumbnails are generated from the embedded RAW previews and cached in `review/cache/`.
- `--folders` enables **Resume / Redrive** on the monitor.

## Monitor

Live progress / throughput / ETA / errors / GPU, by year and by folder, the last photo processed,
and what's up next. **Pause** (SIGINT to every running `photo_cull.py run`), **Resume**,
**Redrive** failures, **Export** a CSV+XMP snapshot, and switch the bulk-run timer on or off.
The topbar widget refreshes every 5 s, the page every 8 s.

## Culling Bay on a computer (`/m`)

Cull a day from the NAS, then send the flags to Lightroom. Open `http://100.82.57.4:8000/m/`
over Tailscale on the Mac or the PC, beside Lightroom. The web app is desktop only (since
2026-11-24): a phone or tablet (no hover and a coarse pointer, or a phone or tablet in the user
agent) gets a short page pointing to the iPhone app and `/m/ios/`, where its builds are. The
desktop layout needs 900 px; a narrower window scrolls sideways. There is no service worker or
web app manifest any more (`desktop.js` removes one an older version registered).

- **One pass of cards:** one stack per card, the photo beside a rail with its details, the RAW at
  1:1 where the camera focused (Sony, Canon and Nikon AF points) and the buttons, and the day's
  filmstrip below. Lightroom's keys: P keep, X reject, 1-5 keep with stars, arrows to browse, Z
  (or a click on the photo) for the 1:1 focus check, Ctrl/Cmd+Z undo, ? for the full list. A
  mouse drag never decides. The AF button shows a box on the photo where the camera focused.
- **Stars:** a row of five under a single photo keeps it with that rating in one tap (5 is Hero).
- **Stacks** follow the camera where it says: on the Sony, one shutter press is one stack, and
  brackets are exact (`photo_cull.py shotinfo` reads the tags). Other cameras use a 2-second gap.
- **Bursts** open in the burst picker, as on the iPhone: a filmstrip whatever the burst's size,
  opening on the sharpest frame (P or Choose) with nothing ticked, or on the frame you were
  looking at (Enter, a number key, or Keep on the 1:1 focus check, whose Reject reads "Reject all
  N"). The rail's 1:1 shows every frame at the lead frame's AF point, and a star row rates the
  frame you're on and ticks it. "Keep 2 · reject 3" keeps what is ticked and rejects the rest with
  the note `Burst reject · kept DSC05039, DSC05040`; with nothing ticked, Enter does nothing.
- **Going back** through a day, each decided stack shows it on the photo: a green, gold or red
  outline, rejects greyed, a line such as "Kept DSC04776 · 1 other rejected ★★★", and the button
  that made the decision pressed.
- **Budget:** 10 kept stacks per hour of shooting (pauses over 10 minutes don't count; at least
  5), counted per stack, so a whole panorama or bracket is one. A "Kept 7 of 10" bar turns amber
  over budget, and if you finish over, the review lists your kept stacks to trim. Stacks you kept
  in Lightroom count toward it and are skipped.
- **Review:** click a reject to see it large, step through the day's rejects with the arrows, and Rescue any.
- **Day grid:** the grid button on the cards or the review toggles to every photo of the day:
  picks outlined (Hero in gold), rejects greyed, your Lightroom stars shown, filters for All /
  Picks / Rejects / Unflagged. Each photo shows Culling Bay's decision, or your Lightroom flag where
  it has none (or yours won). Click a photo to open its card.
- **Start over:** "Start this day over", at the foot of the day grid and the review, clears the
  day's Culling Bay decisions and starts it again from the first stack. It works until anything from
  the day has reached Lightroom; rows already queued in the inbox are taken back out.
- **Send:** queues the day into `AICullInbox/cull-decisions.tsv`. The AI Cull plugin applies it
  on the next **Sync AI Cull Data**, or (v2.1) offers it when Lightroom starts, and leaves a
  receipt, which the app reads back: landed, your own flag kept, or not found.

The AI's keep/review/reject verdicts are never shown. What the app shows is measured: each
burst leads with its sharpest frame, exposure brackets and likely panoramas suggest Keep all,
and badges mark Blown, Dark and Softer (than the burst's sharpest) frames. Rules in
[`stacks.py`](stacks.py); routes in [`mobile.py`](mobile.py); the app in [`static/m`](static/m).
Decisions live in `cull_*` tables in `annotations.db`, keyed by file path.

Tests (from the repo root):

```bash
./venv/bin/python -m unittest discover -s review/tests -t .   # rules, API, phone->Lightroom->phone
./venv/bin/python -m unittest discover -s review/tests/web     # the web app in headless Chromium
./venv/bin/python review/tests/ui_smoke.py                    # older click-through in headless Firefox
```

All use the real `trial.db` read-only and a throwaway `annotations.db` and inbox. The browser
suite (`review/tests/web`, Playwright from `requirements-dev.txt`) runs its own server on port
8813 and skips when Playwright or its Chromium is missing.

**Days** are grouped by year and month, under an **On this day** lane (unculled days from this
week in earlier years); a shoot under 48 hours old is marked Resting. **Search** finds days by
words, places, dates ("snow 2019") or meaning, ranking three signals together
([`search.py`](search.py)): words in captions, tags and towns; caption meaning
(`nomic-embed-text`, `photo_cull.py embed`); and picture meaning from CLIP embeddings of the
photos themselves (`photo_cull.py embed-images`, ViT-B/32 on the CPU, model in `models/`). A
result opens its day with the matching stacks first, and **More like this** in a photo's
details lists other days with similar pictures. A **Place** view groups days by region. Places come from `photo_cull.py geotag`: GPS read
from EXIF with exiftool, then the nearest town with 1,000+ people from GeoNames, offline. The
data lives in `trial_out/geo` (download it as `geotag --help` says; GeoNames is CC BY 4.0). Only
some frames have GPS: the Sony when it is paired with a phone, and iPhone shots. The ingest
watcher geotags each new shoot.

**Day summaries:** each day shows two lines (what the day was, then its highlights), written
by a local text model (`qwen3.5:9b`) from the annotations `photo_cull.py` already made: one
caption line per burst in shot order, the GPS towns and the commonest subjects. Run
`photo_cull.py daysum`; the ingest watcher does it per new shoot, and a day is summarised again
only when its facts change. Search matches the summaries too.

**Lightroom read-back:** each sync, the plugin reports every selected photo's flag and rating.
A stack you picked, or rated, in Lightroom counts as done in Culling Bay (a reject flag still
rejects), and a Culling Bay decision that loses to your own flag shows under "Your Lightroom flag won".

## Timing (`trial_out/perf.jsonl`)

Every request is timed by `review/perf.py` and written as one JSON line to `trial_out/perf.jsonl`
(change it with `--perf-log`; rotated at 20 MB, three old files kept).

- **Each line:** the route, status, handler time (`ms`), time until the body was sent (`send_ms`), size and caller.
- **Stages:** the parts a handler times, e.g. `load`, `full_decode`, `decode_wait`, `encode`, `receipts`, `days_rebuild`, `caption_query`, `picture_query`.
- **Facts:** e.g. `cache=hit|miss`, `decode_cache`, `days_cache`, `served=original`.

Responses also carry a `Server-Timing` header with the same stages, so a browser's developer tools show them.

The phone pages load `static/m/perf-client.js` and send their own measurements to `POST /m/api/perf`:

- **Every `/m/api` fetch,** as the phone saw it: waiting in the browser's queue, first byte, download, and browser-cache hits.
- **Moments you feel:**
  - `card_photo`: a cull card's photo ready after it is drawn, marked `waited` or `prefetched`;
  - `day_open`;
  - `viewer_first` (the thumbnail up, at once), `viewer_photo` (the sharp 1616 px picture) and `viewer_hd`;
  - `results_ready`;
  - `save_ready`.

These are logged as `kind: "client"`. Summarise both with:

    ./venv/bin/python review/perf_report.py              # last 24 h; --hours 168 for a week, --route img to filter

The access log in the journal (`journalctl --user -u photo-review`) is unchanged.

## Notes

- Single-theme dark by design (a darkroom tool).
- "100% zoom" is at the embedded-preview resolution (~1.6 MP for Sony ARW); true
  pixel-peeping would require demosaicing the RAW.
- Everything is localhost and read-only against your library.
