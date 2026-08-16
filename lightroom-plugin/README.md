# AI Cull Sync — Lightroom Classic plugin

Merges `photo_cull`'s AI **keywords + color label + caption** into your LrC catalog **without
ever touching your star ratings or pick/reject flags**. It uses the Lightroom SDK to set only
those three things, so — unlike "Read Metadata from File" — nothing you set by hand is
overwritten. Re-run it as often as you like (after re-analysis); your picks/stars stay put.

Axis split it relies on:

| Axis | Owner |
|---|---|
| color label (green/yellow/red = keep/review/reject) | **AI** — set by this plugin |
| `Stars-N`, `Cull-*`, `Scene-*`, tag keywords | **AI** — set by this plugin |
| Caption field | **AI** — set by this plugin (one-sentence descriptor) |
| star rating | **you** — never touched |
| pick / reject flags | **you** — never touched |

## One-time install

1. On the box that runs `photo_cull`, export the data for a shoot:
   ```bash
   photo_cull.py export --plugin-data /path/aicull.tsv \
     --folder /mnt/passport/Pictures/2024/2024-07-22 --db trial_out/trial.db
   ```
2. Copy `aicull.tsv` **and** the `AICull.lrplugin` folder to your Mac (scp/AirDrop/share).
3. Lightroom Classic → **File → Plug-in Manager → Add** → select the `AICull.lrplugin` folder.

## Each shoot

1. In the Library grid, **select the shoot's photos** (one shoot at a time — matching is by file
   name, which can repeat across shoots).
2. **Library → Plug-in Extras → Sync AI Cull Data (keywords + color label)…**
3. Pick the `aicull.tsv`. It reports how many matched and applies the color label + keywords +
   caption.

Your ratings and flags are never written, so cull however you like — before or after syncing.

## Notes / troubleshooting

- **Nothing matched?** You probably didn't select the photos, or the TSV is for a different shoot.
- **Keywords but no color?** Some catalogs restrict labels to a custom set; the AI uses the default
  color *names* (`Green`/`Yellow`/`Red`). If your label set renamed those, edit the export or your
  Label Set (Metadata → Color Label Set) to match.
- Match is by file name via `photo:getFormattedMetadata('fileName')`; export per-shoot to keep it
  unambiguous.
