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

Matching is by **(shoot folder name, file name)**, not file name alone — Sony resets its file
counter across shoots, so `DSC03960.ARW` can exist in more than one folder. This means the TSV
can safely cover the **whole library at once**; you don't have to select one shoot at a time.

## One-time install

1. On the box that runs `photo_cull`, export the data (omit `--folder` for the whole library):
   ```bash
   photo_cull.py export --plugin-data /path/aicull.tsv --db trial_out/trial.db
   ```
2. Copy the `AICull.lrplugin` folder to your Mac (scp/AirDrop/share) — one-time, since it's just
   code. The TSV itself lives on the passport drive (`/mnt/Passport_AICullInbox/` from this
   Linux box — a narrow read-write mount scoped to just that subfolder, separate from the
   read-only `/mnt/passport` used to scan the library — `/Volumes/Passport/AICullInbox/` from the
   Mac), which the plugin's file picker defaults into — no copying needed for each sync.
   [`ops/watch_ingest.sh`](../ops/watch_ingest.sh) drops one TSV per shoot there automatically;
   see [`ops/README.md`](../ops/README.md).
3. Lightroom Classic → **File → Plug-in Manager → Add** → select the `AICull.lrplugin` folder.

## Each sync

1. In the Library grid, **select the photos to update** — "All Photographs" for a full-library
   sync, or a subset if you just want to touch a few shoots.
2. **Library → Plug-in Extras → Sync AI Cull Data (keywords + color label)…**
3. Pick a TSV from `/Volumes/Passport/AICullInbox/` (that's where the picker opens). It reports
   how many matched and applies the color label + keywords + caption.
4. On a full, uncanceled run, the TSV is moved into `AICullInbox/applied/` — so it drops out of
   the picker's default view and you can't accidentally re-pick the same one next time. A
   canceled run leaves its TSV in place, since it may not have covered every photo yet.

Your ratings and flags are never written, so cull however you like — before or after syncing.

## Notes / troubleshooting

- **Nothing matched?** You probably didn't select the photos, or the TSV doesn't cover them yet
  (re-export after the next `photo_cull.py run`).
- **Label set correctly but the color filter swatch doesn't find it?** Lightroom resolves the
  Attribute-bar color filter by a **case-sensitive** match against the active Label Set's display
  names (`Yellow`, not `yellow`). The TSV/plugin already use the capitalized form — if you ever
  hand-edit a TSV, keep the casing.
- Match is by `(shoot folder name, file name)` — the plugin reads the photo's own path via
  `photo:getRawMetadata('path')` and takes its parent directory's name, so it works regardless of
  where the library is mounted on this machine vs. the box that ran `photo_cull`.
