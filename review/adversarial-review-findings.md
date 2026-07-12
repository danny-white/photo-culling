# Adversarial review findings — qwen NEW-prompt audit (overnight run)

**Run:** started automatically at 00:00 local on 2026-07-12 by a headless Claude agent
(systemd --user unit `adv-review`).
**Scope:** second-round audit — only frames (re)processed under the refined `VLM_PROMPT`
(`processed_at >=` the cutoff in `trial_out/old_prompt_cutoff.txt`, i.e. `2026-07-12T03:23:39Z`),
sampled in random batches of 10 via `review/sample_for_review.py` (`REVIEW_SINCE` set).
**Procedure:** `review/adversarial-review-prompt.md`.

**How to read this file:** per-batch findings are appended below as the run proceeds; the
**last `## Synthesis snapshot`** section is the actionable summary (recurring failure modes +
concrete `VLM_PROMPT` edits). The run stops when the API budget cap is hit, so an abrupt end is
expected and all findings up to that point are safe on disk.

---

<!-- The agent appends `### Batch N` and `## Synthesis snapshot — through batch N` blocks below. -->

---

## Manual interactive round — 24-frame audit (2026-07-12, user-requested)

**Not part of the overnight loop.** A one-off adversarial pass run interactively, following
`review/adversarial-review-prompt.md`. Sample: 24 random `status='ok'` frames (all current-prompt —
every old-prompt row had been reset to `pending`). Reviewer read the 768 px previews directly.

### Headline
Captioning is in good shape, and the two round-1 fixes **held**: **0 confabulated place-names**
across 5+ instantly-recognizable locations (Bonnieux, the Rigi, Skagit Valley tulips, the Schilthorn
— all kept generic), and **0 false `eyes_closed`** (incl. sunglasses, smile-squints, downward gazes).
Text/number reading is excellent ("…GETTING ENGAGED & SHIT" and jersey "521" read verbatim).
**The misses that change a photo's fate are almost all in `derive()`'s CV gate, not the prompt.**

### The 4 that matter — derive() overriding a correct read
| # | File | qwen | pipeline did | should be | cause |
|---|------|------|--------------|-----------|-------|
| 04 | DSC02478 | aes 7, woman / Provence valley | review 3★ | keep 4★ | bright sky → `over` → −1★ + keep-blocked |
| 05 | DSC00763 | aes 6, sapling in snow | review 2★ | review 3★ | snow → `over` → −1★ |
| 16 | DSC01586 | aes 7, couple at night, wine | review 3★ | keep 4★ | dark bg → `under` → −1★ + keep-blocked (flash-lit faces fine) |
| 17 | DSC01567 | aes 7, alpine wildflowers | **REJECT** | keep/review | shallow-DoF macro, `sharp=23.9` → hard reject (aes 7 missed the `≥8` rescue) |

The exposure flag is subject-blind — it fires on bright sky, snow, and dark night backgrounds where
the subject is exposed fine — and the sharpness-rescue threshold (`aesthetic>=8`) is one point too
high to save intentionally-soft frames.

### Secondary (caption) misses — wording-fixable
- **people_count inconsistency:** [14] `people=0` while captioning a face-visible "goalkeeper";
  [23] missed the 2nd player (#510); [08] likely over-counted back-turned players.
- **Gesture / gender over-assertion:** [24] "gives a thumbs-up" (she's throwing a snowball);
  [03] "a man" for a figure ambiguous from behind.
- **Tag drift:** [15] "indoor" for an outdoor turf; [20] "summer" for spring tulips.
- **Missed edge distractions** (recall, not wording): [10] a stray foot bottom-right; [20] an edge
  sign — vs a good catch on [14] (porta-potty + cars). Inconsistent; leave wording alone.

### Fix 1 — derive() (photo_cull.py:541–560)  [HIGH VALUE]
Trust qwen's keeper-grade read over the CV gate; only a *severe* blowout docks a star.
```python
    # A frame qwen rates a keeper (aesthetic >= 7) OR any night frame is "trusted" over the CV
    # gate: its soft/over/under flags are usually SCENE ARTIFACTS, not defects — a bright sky or
    # snow field reads as "over", a flash-lit night portrait as "under", an intentionally
    # shallow-DoF macro as "soft". A trusted frame is never hard-rejected on CV, and only a
    # *severe* blowout docks a star (mild over/under is too noisy to score). Eyes-closed and
    # genuinely weak (aes<=3) frames still reject.
    trusted = vlm["aesthetic"] >= 7 or vlm.get("scene") == "night"

    stars = (vlm["aesthetic"] + 1) // 2   # 9-10->5, 7-8->4, 5-6->3, 3-4->2, 1-2->1
    stars -= 1 if (blurry and not trusted) else 0
    stars -= 1 if severe_exp else 0
    stars -= 1 if closed else 0
    stars = max(1, min(5, stars))

    if closed or vlm["aesthetic"] <= 3:
        verdict = "reject"
    elif (blurry or severe_exp) and not trusted:
        verdict = "reject"
    elif vlm["keep_hint"] and vlm["aesthetic"] >= 7 and not blurry:
        verdict = "keep"
    else:
        verdict = "review"
```
Fixes all 4; regression-checked (motion-blurred snapshot [21] still rejects, eyes-closed still
rejects, clean aes-8 still keeps). **Replayable from stored columns** — a re-derive backfills
without VLM re-inference. Only keep-*promotion* needs `keep_hint`, which isn't persisted → add it as
a column + a `--rederive` subcommand to make every future derive() tweak an instant sweep.

### Fix 2 — VLM_PROMPT wording (photo_cull.py:409)
```text
- caption: … Do NOT state a person's gender or a specific hand gesture (thumbs-up, peace sign,
  pointing) unless unmistakable; if turned away or ambiguous, describe neutrally ("a person raising
  a hand", not "a man giving a thumbs-up").
- people_count: count EVERY person whose face is visible, including secondary people in the
  background; fully turned away (no face) = 0. If your caption names/implies a person, their
  visibility must agree with this count.
- tags: … must match what's visible — no 'indoor' for an outdoor scene (or vice-versa), and no
  season/time-of-day you can't verify from the image.
```

### Held up well
Anti-confabulation, `eyes_closed` discipline, text reading, grounded captions. ~11/24 clean; most of
the rest right with only cosmetic notes. Net: the highest-value change is `derive()`/thresholds, not
prompt wording.
