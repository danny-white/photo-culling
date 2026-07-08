# photo-culling

A local, resumable first-pass culling tool for a Lightroom / Sony-ARW library. It
runs entirely on your own machine (no cloud) using the **Qwen3.5** vision models via
**Ollama**, and is built to grind through a large library over several nights.

For every photo it produces:

- a **quality rating** (1–5 stars),
- a **keep / review / reject** verdict as a Lightroom **color label** (Green / Yellow / Red),
- **keywords**, a caption, subject and scene, and
- **best-of-burst** picks (so a 10-frame burst doesn't become 10 keepers).

Everything is written to a **SQLite database** (`cull.db`) that is the source of truth,
so runs are resumable, failures are tracked, and the CSV report + XMP sidecars can be
regenerated any time.

## How it works (the short version)

- **Reads ARW directly.** It pulls the camera's embedded JPEG preview out of each RAW
  (near-instant, no demosaicing) and analyses that. JPEG/HEIC/TIFF are read directly too.
- **Downscales to 1536 px** before inference — the fix that lets the 9B model run on an
  8 GB GPU (feeding it a full 42 MP frame runs out of VRAM).
- **Hybrid scoring.** Technical quality (sharpness via variance-of-Laplacian, exposure via
  the luminance histogram) is measured deterministically in NumPy — *not* asked of the
  model, which tends to invent technical flaws. The vision model is used only for content:
  caption, subject, scene, tags, aesthetics, eyes-closed.

## Setup

```bash
./venv/bin/pip install -r requirements.txt
ollama pull qwen3.5:9b       # primary (best quality)
ollama pull qwen3.5:4b       # fallback / --fast
```

## Usage

```bash
# Process a library (resumable — safe to Ctrl-C and re-run; skips finished images)
./venv/bin/python photo_cull.py run /path/to/photos

# See progress / failures at any time
./venv/bin/python photo_cull.py status
./venv/bin/python photo_cull.py status --errors      # list each failed file

# Retry only the images that errored
./venv/bin/python photo_cull.py run /path/to/photos --redrive

# Write the report + Lightroom sidecars
./venv/bin/python photo_cull.py export --xmp
```

Useful flags on `run`: `--fast` (use the 4B model), `--limit N` (stop after N images —
good for a trial), `--force` (reprocess already-done images), `--no-recursive`.

### Getting the results into Lightroom Classic

`export --xmp` writes an `.xmp` sidecar next to each photo (`DSC01234.xmp`) containing the
rating, color label, caption and keywords. In Lightroom Classic:

1. Select the photos (or the folder).
2. **Metadata ▸ Read Metadata from File**.

Ratings, Green/Yellow/Red labels and keywords appear on your photos. You can then filter
by label/stars and cull fast. The **Green / Yellow / Red** label names match Adobe's
default label set, so the colors show up without extra configuration.

**Safety:** sidecars are only written where none exists, so an existing Lightroom sidecar
(with your develop settings) is never clobbered. Use `--force-xmp` to overwrite. Nothing is
ever written *into* your RAW files.

## Managing a multi-night run

- Runs are resumable: re-running `run` continues where it left off.
- `cull.db` is a normal SQLite file — inspect it directly:

  ```bash
  sqlite3 cull.db "SELECT error_class, COUNT(*) FROM images WHERE status='error' GROUP BY 1;"
  sqlite3 cull.db "SELECT filename, reason FROM images WHERE verdict='keep' ORDER BY quality_stars DESC;"
  ```

- To run overnight and detach: `nohup ./venv/bin/python photo_cull.py run /path/to/photos &`

## Tuning

Thresholds live as constants near the top of `photo_cull.py`:

| Constant | Meaning |
|---|---|
| `MAX_EDGE` | px sent to the model (VRAM/speed vs. detail; default 1536) |
| `SHARP_FLOOR` | variance-of-Laplacian below which a frame is "soft/blurred" |
| `BLOWN_PCT_MAX` / `CRUSHED_PCT_MAX` | exposure clipping thresholds |
| `BURST_GAP_S` | seconds between frames to group as one burst |

Sharpness is scene-dependent, so `SHARP_FLOOR` only catches clearly soft frames; fine
ranking between similar shots is done *relatively within a burst* when picking the best.

## What each verdict means

- **keep** (Green) — sharp, well-exposed, good composition, and the best of its burst.
- **review** (Yellow) — decent but borderline, or a good shot that isn't the pick of a burst.
- **reject** (Red) — blurred, badly exposed, eyes closed, or weak composition.

The star rating blends the aesthetic score with technical penalties, so you can also just
sort by stars.
