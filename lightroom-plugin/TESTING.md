# AI Cull Sync v2.3 — People keywords

About 20 minutes at the Mac, in a **scratch catalog**. v2.3 turns the people you name in Culling
Bay into `People > <name>` keywords. The fake SDK in `tests/` checks the rules; this checks the
parts only Lightroom can: the new hidden field, the keyword hierarchy and the export flags, and
that your own keywords survive. The names below ("Alex", "Pat") stand for anyone: use real ones in
your own catalog.

## Set up

1. Copy `AICull.lrplugin` from the repo (branch `people-lr`) to the Mac. **Quit Lightroom (⌘Q)**,
   keep the old plugin folder as `AICull-2.2.lrplugin` somewhere else (to roll back to), and
   replace the folder's contents (Plug-in Manager shows where it loads from). Reload Plug-in is
   not enough: 2.3 adds a hidden field, `peopleSet`, and Lightroom reads those only at launch.
2. Reopen Lightroom. **File → New Catalog**, `AI Cull people test`. Accept the prompt to update
   the catalog for the plugin's metadata. Plug-in Manager should show **AI Cull Sync 2.3.0**,
   enabled, with no "error reading the schema" message (that message means a hidden field
   declares a `dataType`).
3. Import with **Add** (not Move) one shoot folder that has people in it, so Culling Bay has
   faces there: about 30 photos is plenty.
4. In Culling Bay (the app), name one group **Alex** (People tab → Not named yet → the group →
   Add name). Wait 15 seconds, then on the Mac open
   `/Volumes/Passport/AICullInbox/people.tsv`: the first line is `#people v1`, then one row per
   photo of Alex's: `2026-…<tab>DSC….ARW<tab>Alex`, with the names of the other people the
   same way (`Alex|Sam`).

## Add

5. **Select All Photographs → Library → Plug-in Extras → Sync AI Cull Data…** → pick `people.tsv`.
   The summary ends `People: N row(s); P photo(s) changed, A keyword(s) added and 0 removed.`,
   and **there is no caption question** (nothing else was applied).
6. Check:
   - Keyword List panel: a top-level keyword **People** with **Alex** under it.
   - Right-click **People → Edit Keyword Tag…**: *Include on Export* is **off**. On **Alex** it is **on**.
   - Filter by the Alex keyword: exactly the photos in `people.tsv`'s Alex rows (rows for photos
     of the shoot you didn't import match nothing; that is fine).
   - `people.tsv` is **still in the inbox** (it isn't moved to `applied/`); `applied/` holds a
     new `…-receipt.tsv` whose second line is `#people photos=… added=… removed=0`.
7. Sync again, same file: the summary says `0 photo(s) changed`.

## Your own keywords survive

8. Pick a photo **A** that has Alex, and add the keyword `Family` by hand. Pick another photo
   **B** that has Alex and add `People > Pat` by hand (create **Pat** under **People** in the
   Keyword List).
9. In Culling Bay take Alex off photo **B** only: Person screen → Manage faces → select B's face →
   **Not Alex** (or open B's (i) sheet and use *Not Alex* on the face). Wait 15 seconds: the
   `people.tsv` row for B now ends with a tab and no name.
10. Sync again with `people.tsv`. Check: **B has lost `People > Alex` but keeps `People > Pat`**
    (`1 removed`); **A still has Family and People > Alex**.
11. Sync once more: `0 photo(s) changed`. **Pat is still on B.**

## Put back, rename, delete

12. Take `People > Alex` off photo **A** by hand. Sync: it comes back (`1 added`).
13. In Culling Bay rename Alex to **Alexander**. Wait, sync: photos get `People > Alexander`
    and lose `People > Alex` (the empty keyword `Alex` stays in the Keyword List; delete it by
    hand if you like). Pat and Family are untouched.
14. In Culling Bay use *Remove name* on Alexander. Wait, sync: every photo loses
    `People > Alexander`; the rows in `people.tsv` stay, with no names.

## The launch offer

15. In Culling Bay name a group again (any name), wait 15 seconds, quit Lightroom and reopen the
    scratch catalog. About 5 seconds after it opens: **"People keywords are waiting from Culling
    Bay for N photos"**. Click **Not now**: nothing changes. Quit and reopen: **Apply**: the
    keywords arrive and the usual summary shows. Quit and reopen once more: **no question**,
    although `people.tsv` is still in the inbox.
16. Send a phone cull with the same launch: the question is the phone culls', with *"Also waiting:
    People keywords for N photos."* underneath, and Apply does both.

## If something is off

Note the photo, the step and what you saw (a screenshot of any error dialog helps; the dialog
names the photo and the SDK call that failed). Two things the fake SDK can't settle are worth
watching: that a photo's keyword list holds only the keywords on the photo itself (so `People`
never shows as a keyword on a photo, only `Alex` under it), and that the sync of thousands of
photos stays quick (time a full-library sync on the real catalog once; the second sync reads each
named photo's keywords and writes nothing). To roll back, put `AICull-2.2.lrplugin`'s contents
back and restart Lightroom; the hidden field stays in the catalog, unused, and the keywords stay
on the photos.

---

# AI Cull Sync v2.1 — the launch offer

About 5 minutes, on your **real** catalog. v2.1 adds one thing: when Lightroom starts, it offers
the phone culls waiting in the inbox. The sync it runs is v2's, unchanged (checked below in the
scratch catalog, and since used for real). What's new is finding the shoots' photos without a
selection, and asking first.

Use the real catalog, not a scratch one: Apply files the inbox's `cull-decisions.tsv` under
`applied/`, and Culling Bay then counts those culls as in Lightroom. In a scratch catalog they
would land there instead of in yours. On 11 Oct the inbox held **88 phone culls from 2026-08-09**
(your phone cull of that day), which make the test.

1. Quit Lightroom (⌘Q) before touching the folder: replaced while it runs, Lightroom reports
   "No script by the name Startup.lua" until the next restart. Replace the contents of the AI Cull Sync plugin folder (Plug-in Manager shows
   where it loads from) with `/Volumes/Passport/AICullInbox/plugin-v2.1/AICull.lrplugin`.
   `plugin-v2.1/AICull-v2.lrplugin` beside it is v2, to roll back to.
2. Open Lightroom on your real catalog. About 5 seconds after it opens:
   **"88 phone culls are waiting from Culling Bay"**, *From 2026-08-09 (… photos in this
   catalog)*. Click **Not now**. Nothing changes; the file stays in the inbox.
3. Quit and reopen. The same question: click **Apply**. The usual sync summary follows (88 phone
   rows; any of your own flags kept are counted). Spot-check a few 9 Aug photos: flags and
   stars from the phone, burst notes on burst rejects.
4. Quit and reopen once more: no question, since nothing is waiting.
5. On the phone, 9 Aug should show **Synced** in the day list once the receipt is read (open the
   day list, or wait for the next refresh).

If the question never comes, check the inbox is mounted on the Mac
(`/Volumes/Passport/AICullInbox`) and the file is still there; **Sync AI Cull Data** from the
menu still works as before.

---

# AI Cull Sync v2 — scratch-catalog checklist

About 15 minutes at the Mac. It runs the same two-run kit as `tests/test_sync.lua`, but in real
Lightroom, which the fake SDK can't stand in for. Use a scratch catalog: nothing here touches
your real one.

The kit is staged on the inbox share at `/Volumes/Passport/AICullInbox/plugin-v2-test/`:

| Path | What |
|---|---|
| `AICull.lrplugin/` | v2 |
| `AICull-v1.lrplugin/` | v1, to roll back to |
| `run1/`, `run2/` | `pending.tsv` + `cull-decisions.tsv` for each run |

## Set up

1. **File → New Catalog**, named `AI Cull test`, anywhere on the Mac.
2. Import `/Volumes/Passport/Pictures/2026/2026-10-01` with **Add**: 32 photos. Check the mode at
   the top of the import window before clicking Import: Lightroom remembers the last one, and
   **Move** carries the files off the NAS (it did, on the first run of this checklist).
3. **File → Plug-in Manager**, select **AI Cull Sync**, note the folder it loads from, replace that
   folder's contents with `plugin-v2-test/AICull.lrplugin`, then **quit and reopen Lightroom**
   (⌘Q). Lightroom reads a plug-in's metadata definitions only at launch: Reload Plug-in after
   adding `AICullMetadata.lua` reports "No script by the name AICullMetadata.lua". Accept the
   prompt to update the catalog for the plugin's metadata.
4. Set the "before" state by hand:
   - `DSC05038`: flag as **Pick** (P).
   - `DSC05039`: Caption `My own caption.`
   - `DSC05040`: **2 stars**.

## Run 1

5. Select **All Photographs** → **Library → Plug-in Extras → Sync AI Cull Data (AI + phone
   culls)…** → pick `plugin-v2-test/run1/pending.tsv`.
6. It asks about **1 caption** that differs from the AI's text. Choose **Keep them**.
7. Check:

| Photo | Expected |
|---|---|
| DSC05036 | Rejected. Caption: `Burst reject · kept DSC05037`, then `TEST AI: A one.` Keyword `Cull › Burst reject` |
| DSC05037 | Pick, 5 stars |
| DSC05038 | Still **your** Pick. Caption `TEST AI: C one.` with no burst line, no burst keyword |
| DSC05039 | Caption still `My own caption.` |
| DSC05040 | Pick, still **2** stars |
| DSC05041 | Caption `TEST AI: F one.` |
| Collections | Smart collection **Burst rejects, similar kept** holds DSC05036 only |
| Final dialog | 1 phone row matched no photo (`NOTREAL.ARW`); flags and ratings of 32 photos sent back to Culling Bay; a receipt and a catalog file in `run1/applied/` |

## Between runs

8. `DSC05041`: add ` Extra words.` to the end of its caption.
9. `DSC05042`: change its caption to `TEST AI: I one, fixed by me.`

## Run 2

10. Select **All Photographs** → Sync → pick `plugin-v2-test/run2/cull-decisions.tsv` this time.
    There should be **no** caption question.
11. Check:

| Photo | Expected |
|---|---|
| DSC05036 | Pick (rescued). Caption `TEST AI: A one.` with no burst line; keyword gone; out of the smart collection |
| DSC05038 | Still your Pick |
| DSC05039 | Still `My own caption.` |
| DSC05041 | `TEST AI: F two. Extra words.` |
| DSC05042 | Still `TEST AI: I one, fixed by me.` |

## If something is off

Note the photo and what you saw (a screenshot of any error dialog helps). To roll back, put
`AICull-v1.lrplugin`'s contents back in the plugin folder and Reload. The hidden fields v2 added
stay in the catalog, unused.
