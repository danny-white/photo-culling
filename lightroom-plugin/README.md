# AI Cull Sync — Lightroom Classic plugin

Merges `photo_cull`'s AI **keywords + color label + caption** into your LrC catalog, and (v2)
your **phone culls** from Culling Bay Mobile: pick/reject flags, Hero stars and burst notes. It
uses the Lightroom SDK, so — unlike "Read Metadata from File" — it never overwrites anything you
set by hand. Hidden plugin fields ([`AICullMetadata.lua`](AICull.lrplugin/AICullMetadata.lua))
record exactly what the plugin itself wrote, and only that is ever replaced. Re-run it as often as
you like.

Who owns what:

| Field | Owner |
|---|---|
| color label (green/yellow/red = keep/review/reject) | **AI** — set by this plugin |
| `Stars-N`, `Cull-*`, `Scene-*`, tag keywords | **AI** — set by this plugin |
| Caption: the AI sentence | **AI** — replaced only while it is exactly what the plugin wrote |
| Caption: a first line `Burst reject · kept DSC05015` | **phone** — added and removed by the plugin |
| Caption: anything else | **you** — never touched |
| pick / reject flag | **you**, then the phone — set only on unflagged photos, or ones the plugin flagged itself |
| star rating | **you**, then the phone — Hero's 5 stars land only on unrated photos |

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
   [`ops/watch_ingest.sh`](../ops/watch_ingest.sh) merges each shoot into `pending.tsv` there;
   see [`ops/README.md`](../ops/README.md).
3. Lightroom Classic → **File → Plug-in Manager → Add** → select the `AICull.lrplugin` folder.
   To upgrade, replace the folder's contents and click **Reload Plug-in**. v2 adds hidden
   metadata fields, so Lightroom asks once per catalog to update it.

## Each sync

1. In the Library grid, **select the photos to update** — "All Photographs" for a full-library
   sync, or a subset if you just want to touch a few shoots.
2. **Library → Plug-in Extras → Sync AI Cull Data (AI + phone culls)…**
3. Pick `pending.tsv` (AI) or `cull-decisions.tsv` (phone) from `/Volumes/Passport/AICullInbox/`;
   the other one is applied in the same pass when it is in the same folder. It reports what it
   applied and what it left alone.
4. On a full, uncanceled run it writes `applied/<time>-receipt.tsv` (one outcome per phone row:
   `applied`, `your_flag_kept`, `your_stars_kept`, `caption_left`, `missing`), which Culling Bay
   reads back, and moves each input to `applied/<time>-<name>`. A canceled run leaves its inputs
   in place, since it may not have covered every photo yet.

A flag or rating you set by hand always wins, so cull however you like, before or after syncing.

### Caption rules

| Caption now | What the plugin does |
|---|---|
| Empty | Writes the note line (if any), then the AI sentence |
| The AI sentence it last wrote, alone or inside your own text | Replaces just that sentence |
| The AI sentence, edited by you | Leaves it, marks the caption yours, lists it once in the receipt |
| First v2 sync, equal to the incoming AI text | Adopts it as the AI's |
| First v2 sync, anything else | Asks once: **Keep** (yours from now on) or **Replace** (old AI text) |

A caption that became yours gets AI text again only if you clear it. When your own flag wins over
a phone reject, the burst note and the `Cull › Burst reject` keyword stay off that photo too. A
smart collection, **Burst rejects, similar kept**, gathers rejects that carry the keyword.

### Testing

The rules live in [`CullCore.lua`](AICull.lrplugin/CullCore.lua), which has no Lightroom imports.
Lightroom runs Lua 5.1, and so do the tests:

```bash
lua5.1 lightroom-plugin/tests/test_cullcore.lua   # the rules
lua5.1 lightroom-plugin/tests/test_sync.lua       # SyncAICull.lua end to end, on a fake SDK
```

The fake SDK can't prove what Lightroom does. [`TESTING.md`](TESTING.md) is the 15-minute
scratch-catalog checklist that does, using the same two-run kit in `tests/kit/`.

## AI Semantic Search

**Library → Plug-in Extras → AI Semantic Search…** — type a description ("dog running on the
beach"), and it finds photos by *meaning*, not filename/keyword matching. Under the hood: the
Linux box embeds every photo's AI caption/tags/scene into a vector (`photo_cull.py embed`), and
this command sends your query to `review/server.py`'s `/api/semantic_search`, which embeds it the
same way and does a cosine-similarity nearest-neighbor search.

Results land in a collection named **AI Search Results**, ranked best match first — if it doesn't
look ranked, right-click the grid → **Sort → Custom Order**.

This is a new code path: it talks to the review server over **HTTP**, not the SMB-mounted TSV
files the sync command uses. It tries the Linux box's LAN address first, then falls back to
Tailscale — both addresses are hardcoded near the top of `SemanticSearch.lua`
(`LAN_URL`/`TAILSCALE_URL`); if the box's LAN IP ever changes, update it there. It also needs
`review/server.py` actually running and reachable — if you get "Could not reach the search
server," check that first.

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
