# AI Cull Sync v2.1 — the launch offer

About 5 minutes, on your **real** catalog. v2.1 adds one thing: when Lightroom starts, it offers
the phone culls waiting in the inbox. The sync it runs is v2's, unchanged (checked below in the
scratch catalog, and since used for real). What's new is finding the shoots' photos without a
selection, and asking first.

Use the real catalog, not a scratch one: Apply files the inbox's `cull-decisions.tsv` under
`applied/`, and Culling Bay then counts those culls as in Lightroom. In a scratch catalog they
would land there instead of in yours. On 11 Oct the inbox held **88 phone culls from 2026-08-09**
(your phone cull of that day), which make the test.

1. Quit Lightroom. Replace the contents of the AI Cull Sync plugin folder (Plug-in Manager shows
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
