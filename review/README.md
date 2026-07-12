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

## Notes

- Single-theme dark by design (a darkroom tool).
- "100% zoom" is at the embedded-preview resolution (~1.6 MP for Sony ARW); true
  pixel-peeping would require demosaicing the RAW.
- Everything is localhost and read-only against your library.
