# AI Cull Sync — Lightroom Classic plugin

Merges `photo_cull`'s AI **keywords + caption** into your LrC catalog (never a colour label:
v2.2), and (v2)
your **phone culls** from Culling Bay Mobile: pick/reject flags, stars and burst notes, and (v2.1)
offers waiting phone culls when Lightroom starts, and (v2.3) the **people** you named in Culling
Bay, as `People > name` keywords. It
uses the Lightroom SDK, so — unlike "Read Metadata from File" — it never overwrites anything you
set by hand. Hidden plugin fields ([`AICullMetadata.lua`](AICull.lrplugin/AICullMetadata.lua))
record exactly what the plugin itself wrote, and only that is ever replaced. Re-run it as often as
you like.

Who owns what:

| Field | Owner |
|---|---|
| color label | **you** — the plugin never sets one (v2.2: you stripped them all on 2026-10-11); `photo_cull` exports none |
| `Stars-N`, `Cull-*`, `Scene-*`, tag keywords | **AI** — set by this plugin |
| Caption: the AI sentence | **AI** — replaced only while it is exactly what the plugin wrote |
| Caption: a first line `Burst reject · kept DSC05015` | **phone** — added and removed by the plugin |
| Caption: anything else | **you** — never touched |
| `People > <name>` keywords | **Culling Bay** — added for the people you named; removed only when Culling Bay no longer has that person in the photo, and only if this plugin added it |
| any other keyword, under `People` or not | **you** — never removed |
| pick / reject flag | **you**, then the phone — set only on unflagged photos, or ones the plugin flagged itself |
| star rating | **you**, then the phone — the phone's stars land only on unrated photos |

Matching is by **(shoot folder name, file name)**, not file name alone — Sony resets its file
counter across shoots, so `DSC03960.ARW` can exist in more than one folder. This means the TSV
can safely cover the **whole library at once**; you don't have to select one shoot at a time.

## One-time install

1. On the box that runs `photo_cull`, export the data (omit `--folder` for the whole library):
   ```bash
   photo_cull.py export --plugin-data /path/aicull.tsv --db trial_out/trial.db
   ```
2. Copy the `AICull.lrplugin` folder to your Mac (scp/AirDrop/share) — one-time, since it's just
   code. The TSVs themselves live on the passport drive (`/mnt/Passport_AICullInbox/` from this
   Linux box — a narrow read-write mount scoped to just that subfolder, separate from the
   read-only `/mnt/passport` used to scan the library — `/Volumes/Passport/AICullInbox/` from the
   Mac), which the plugin's file picker defaults into — no copying needed for each sync.
   [`ops/watch_ingest.sh`](../ops/watch_ingest.sh) merges each shoot into `pending.tsv` there;
   see [`ops/README.md`](../ops/README.md).
3. Lightroom Classic → **File → Plug-in Manager → Add** → select the `AICull.lrplugin` folder.
   To upgrade, **quit Lightroom first**, replace the folder's contents, then reopen it: Lightroom
   indexes a plug-in's scripts only at launch. A file added while it runs, Reload Plug-in
   included, gives "No script by the name …" until a restart (`AICullMetadata.lua` in v2,
   `Startup.lua` in v2.1, where the plug-in then fails to start at all). Lightroom asks once per
   catalog to update it for the hidden fields. **2.3.0 adds one (`peopleSet`)**, so replace the
   folder with Lightroom quit, as above, and accept the catalog update at the next launch: a
   Reload Plug-in is not enough.

## Each sync

1. In the Library grid, **select the photos to update** — "All Photographs" for a full-library
   sync, or a subset if you just want to touch a few shoots.
2. **Library → Plug-in Extras → Sync AI Cull Data (AI + phone culls)…**
3. Pick `pending.tsv` (AI), `cull-decisions.tsv` (phone) or `people.tsv` (people) from
   `/Volumes/Passport/AICullInbox/`; the others are applied in the same pass when they are in the
   same folder. It reports what it applied and what it left alone.
4. On a full, uncanceled run it writes `applied/<time>-receipt.tsv` (one outcome per phone row:
   `applied`, `your_flag_kept`, `your_stars_kept`, `caption_left`, `missing`, and a comment line
   `#people photos=… added=… removed=…` when people keywords changed), which Culling Bay reads
   back, and moves `pending.tsv` and `cull-decisions.tsv` to `applied/<time>-<name>`. A canceled
   run leaves its inputs in place, since it may not have covered every photo yet. `people.tsv`
   stays where it is (below).

A flag or rating you set by hand always wins, so cull however you like, before or after syncing.

### People keywords (v2.3)

When you name someone in Culling Bay, the server writes `people.tsv` into the inbox (about 10
seconds after the last change): one row per photo that has ever had a named person, with the
names in it. The sync turns each name into a keyword under a top-level **`People`** keyword
(`People > Alex`): `People` is not included on export, each name is, so a name exports as plain
`Alex`. Per photo it:

- **adds** the names the photo doesn't hold;
- **removes** a name only if this plugin added it earlier (the hidden `peopleSet` field records
  the names it set) and Culling Bay no longer has that person in the photo;
- **leaves everything else alone**: a keyword you added by hand, under `People` or anywhere else,
  is never removed. If you add `People > Alex` by hand to a photo Culling Bay also names Alex, the
  plugin treats it as its own from then on;
- puts a keyword back if you take a wanted one off by hand (the sync makes the catalog match Culling Bay).

A photo whose last person was taken off keeps a row with no names, so its keyword comes off; a
person renamed in Culling Bay (`Alex` → `Alexander`) gets the new keyword and loses the old one
from the photos (the old keyword stays in the keyword list with no photos).

**`people.tsv` is left in the inbox**, not moved to `applied/` like the other two. The server
rewrites all of it at every change, so it is the current state rather than a batch of work;
running it twice changes nothing (a photo whose names match `peopleSet` and which holds them
costs one keyword read and no write); and a sync of a selection or of the launch offer's shoots
must not use it up for photos it didn't cover. The sync reports `People: N row(s); P photo(s)
changed, A keyword(s) added and R removed.`

### At launch (v2.1)

When Lightroom starts, the plugin looks in the inbox. If `cull-decisions.tsv` holds phone culls,
it finds the shoot folders they name in the catalog and asks: *"88 phone culls are waiting from
Culling Bay — From 2026-08-09 (… photos in this catalog). Apply them now?"* **Apply** runs the
sync above on those folders' photos, with no selecting; **Not now** leaves the file for next
time. It applies only the phone's file: the AI's `pending.tsv` can name shoots you haven't
imported yet, and a sync files its input under `applied/` whether or not every row found a
photo, so the AI data waits for **Sync AI Cull Data** as before. Nothing is asked when the inbox
isn't mounted, nothing is waiting, or none of the shoots are in the open catalog.

(v2.3) `people.tsv` is looked at too. A photo counts as waiting only when the names Culling Bay
has for it differ from the ones the plugin last set (read from the hidden field in bulk, so it is
quick even on a big library), so the file sitting in the inbox doesn't ask at every launch. If
any photo in the open catalog is waiting, the question says so, together with the phone culls
(*"Also waiting: People keywords for 12 photos."*), or on its own (*"People keywords are waiting
from Culling Bay for 12 photos"*). **Apply** applies `people.tsv` to those photos alongside the
phone culls. A hand-removed keyword isn't noticed here; **Sync AI Cull Data** puts it back.

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

The rules live in [`CullCore.lua`](AICull.lrplugin/CullCore.lua), which has no Lightroom imports;
the sync is [`Sync.lua`](AICull.lrplugin/Sync.lua), run by the menu item
([`SyncAICull.lua`](AICull.lrplugin/SyncAICull.lua)) and the launch offer
([`Startup.lua`](AICull.lrplugin/Startup.lua)).
Lightroom runs Lua 5.1, and so do the tests:

```bash
lua5.1 lightroom-plugin/tests/test_cullcore.lua   # the rules
lua5.1 lightroom-plugin/tests/test_sync.lua       # the menu sync and the launch offer, on a fake SDK
```

The fake SDK can't prove what Lightroom does. [`TESTING.md`](TESTING.md) is the 15-minute
scratch-catalog checklist that does, using the same two-run kit in `tests/kit/`, and (at the top)
the People keywords checklist for 2.3. `review/tests/test_round_trip.py` runs the server's
`people.tsv` through the plugin on the fake SDK.

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
