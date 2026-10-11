# Culling review + monitor (local web app)

A keyboard-driven, dark "culling bay" for reviewing `photo_cull` results: see each photo
next to its generated content, correct the AI's verdict/stars, **flag what's wrong** (to
refine the VLM prompt / thresholds), compare bursts, and **monitor / steer a live run** —
all on localhost. Nothing is ever written to the NAS.

## Run

```bash
./venv/bin/python review/server.py \
    --db trial_out/trial.db \
    --log trial_out/run.log \
    --folders /mnt/passport/Pictures/2024 /mnt/passport/Pictures/2025
```

Open **http://127.0.0.1:8000**.

- Reads the cull DB **read-only** (WAL-safe while a run is in progress).
- Your corrections go to a **separate** annotations DB (default `<db>.annotations.db`), so
  there is zero write-contention with the running culler.
- Thumbnails are generated from the embedded RAW previews and cached in `review/cache/`.
- `--folders` enables **Resume / Redrive** from the Monitor tab.

## Tabs

- **Review** — filter/scan the grid; click a frame for the loupe. Keyboard: `K`/`U`/`X`
  verdict · `1`–`5` stars · `Enter` agree + next · `←`/`→` move · `Z` 100% zoom (of the
  embedded preview) · `Esc` back. The "Flag what's wrong" chips feed the Feedback tab.
- **Bursts** — every detected burst (computed live from capture-time + camera, so it works
  before any export); open one to compare frames and pick the real best vs. the AI's pick.
- **Feedback** — aggregates your flags + disagreements into concrete suggested edits to
  `VLM_PROMPT`, with a copy-able draft addendum.
- **Tune** — slide the deterministic thresholds (`SHARP_FLOOR`, blown-highlights,
  aesthetic→verdict) and see verdicts **re-derived over your corrected set** and the
  agreement % with your labels — no VLM re-run.
- **Monitor** — live progress / throughput / ETA / errors / GPU; **Pause** (SIGINT to the
  run's PID), **Resume**, **Redrive** failures, **Export** a CSV+XMP snapshot.

## Culling Bay Mobile (`/m`)

Cull a day from the NAS on your phone, then send the flags to Lightroom. Open
`http://100.82.57.4:8000/m/` over Tailscale (or the `tailscale serve` HTTPS address, which
also lets it install to the Home Screen with an offline app shell).

- **One pass of cards:** one stack per card. Swipe up to keep, down to reject the stack,
  sideways to browse; tap to give the photo the whole screen, double-tap for the 1:1 focus check.
  Vertical photos use the full height. Under a landscape photo, an upright phone shows the RAW at
  1:1 where the camera focused (Sony, Canon and Nikon AF points), with a box on the photo marking
  the spot. Turned sideways, the photo fills the height with the buttons down the right edge.
- **Stars:** a row of five under a single photo keeps it with that rating in one tap (5 is Hero).
- **Stacks** follow the camera where it says: on the Sony, one shutter press is one stack, and
  brackets are exact (`photo_cull.py shotinfo` reads the tags). Other cameras use a 2-second gap.
- **Bursts:** a swipe up or Choose opens the burst on its first frame. The filmstrip (up to 6
  frames) has a 1:1 toggle that shows every frame at the same spot, and a star row that rates the
  frame you're on; bigger bursts open as a knock-out grid (tap the weak ones out, keep the rest).
  Keeping some frames rejects the others with the note `Burst reject · kept DSC05039`.
- **Going back** through a day, each decided stack shows it on the photo: a green, gold or red
  outline, rejects greyed, a line such as "Kept DSC04776 · 1 other rejected ★★★", and the button
  that made the decision pressed.
- **Budget:** 10 kept stacks per hour of shooting (pauses over 10 minutes don't count; at least
  5), counted per stack, so a whole panorama or bracket is one. A "Kept 7 of 10" bar turns amber
  over budget, and if you finish over, the review lists your kept stacks to trim. Stacks you kept
  in Lightroom count toward it and are skipped.
- **Review:** tap a reject to see it large, swipe through the day's rejects, and Rescue any.
- **Day grid:** the grid button on the cards or the review toggles to every photo of the day:
  picks outlined (Hero in gold), rejects greyed, your Lightroom stars shown, filters for All /
  Picks / Rejects / Unflagged. Each photo shows the phone's decision, or your Lightroom flag where
  the phone has none (or yours won). Tap a photo to open its card.
- **Start over:** "Start this day over", at the foot of the day grid and the review, clears the
  day's phone decisions and starts it again from the first stack. It works until anything from
  the day has reached Lightroom; rows already queued in the inbox are taken back out.
- **Send:** queues the day into `AICullInbox/cull-decisions.tsv`. The AI Cull plugin applies it
  on the next **Sync AI Cull Data**, or (v2.1) offers it when Lightroom starts, and leaves a
  receipt, which the app reads back: landed, your own flag kept, or not found.

The AI's keep/review/reject verdicts never reach the phone. What it shows is measured: each
burst leads with its sharpest frame, exposure brackets and likely panoramas suggest Keep all,
and badges mark Blown, Dark and Softer (than the burst's sharpest) frames. Rules in
[`stacks.py`](stacks.py); routes in [`mobile.py`](mobile.py); the app in [`static/m`](static/m).
Decisions live in `cull_*` tables in `annotations.db`, keyed by file path.

Tests (from the repo root):

```bash
./venv/bin/python -m unittest discover -s review/tests -t .   # rules, API, phone->Lightroom->phone
./venv/bin/python review/tests/ui_smoke.py                    # the app in headless Firefox
```

Both use the real `trial.db` read-only and a throwaway `annotations.db` and inbox.

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
A stack you picked, or rated, in Lightroom counts as done on the phone (a reject flag still
rejects), and a phone decision that loses to your own flag shows under "Your Lightroom flag won".

## Notes

- Single-theme dark by design (a darkroom tool).
- "100% zoom" is at the embedded-preview resolution (~1.6 MP for Sony ARW); true
  pixel-peeping would require demosaicing the RAW.
- Everything is localhost and read-only against your library.
