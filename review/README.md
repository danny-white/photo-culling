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

- **Pass 1, the sweep:** every stack of the day in a grid; tap the obvious misses.
- **Pass 2, the cards:** one stack per card. Swipe up to keep the frame, down to reject the
  burst, sideways to browse. Bursts open as a filmstrip (up to 6 frames) or a winner-stays
  duel. Keeping one frame rejects the rest with the note `Burst reject · kept DSC05039`.
  Double-tap for a 1:1 crop from the RAW.
- **Send:** queues the day into `AICullInbox/cull-decisions.tsv`. The AI Cull plugin (v2)
  applies it on the next **Sync AI Cull Data** and leaves a receipt, which the app reads back:
  landed, your own flag kept, or not found.

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

## Notes

- Single-theme dark by design (a darkroom tool).
- "100% zoom" is at the embedded-preview resolution (~1.6 MP for Sony ARW); true
  pixel-peeping would require demosaicing the RAW.
- Everything is localhost and read-only against your library.
