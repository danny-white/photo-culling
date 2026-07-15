# Feature requests / backlog

Prioritized backlog first, **shipped** at the bottom. Priorities weigh value × cost × sequencing
(some items gate others). Code references use symbol names to survive line drift; snapshot commit
for context is `bc0bda2`.

**Order:** P2 `--reprocess-stale` · P3 prompt-wording pass · P4 semantic search ·
P5 prompt→version changelog · P6 DB reconciliation.
**Shipped:** prompt+harness versioning · star-tier remap · derive() fix + `rederive`.

---

## P2 — `--reprocess-stale`   ← next up

**Value: medium. Cost: low.** Mirror the existing `--reprocess VERDICT` flag: reset rows where
`prompt_version` / `harness_version` != current back to `pending`, so a prompt/code change redrives
exactly the drifted rows. Optionally have plain `run` *warn* when stale rows exist. Not urgent now
(post-run the library is uniformly prompt `99ac55d6`), but it's the tool you'll want the instant you
touch the prompt — so build it immediately before P3.

---

## P3 — Prompt-wording fixes (audit Fix 2), then one reprocess   [newly tracked]

**Value: medium. Cost: high — a prompt edit bumps `prompt_version` → full reprocess of ~15k.**

From the audit (`review/adversarial-review-findings.md`, Fix 2): tighten the `VLM_PROMPT` bullets for
- **people_count** consistency (missed a face-visible subject; miscounts vs the "faces only" rule),
- **gesture / gender over-assertion** ("thumbs-up" for a snowball throw; "a man" for an ambiguous
  back-turned figure),
- **tag drift** ("indoor" for an outdoor field; unverifiable season).

Because every prompt edit forces a reprocess, **batch all wording changes into one revision** and run
it once (via `run --force`, or P2's `--reprocess-stale`). Do this as the lead-in to P4 so embeddings
reflect the final captions.

---

## P4 — Semantic keyword search (phase 2)

**Gated:** build after P3, so embeddings reflect the final prompt's captions.

**Goal:** find photos by *concept*, not exact string — "church interiors", "beach at sunset", or
"more like this" from a photo (finds cathedral / chapel / nave without the exact word).

**Design (fully local):**
- Embed each photo's text (caption + tags + subject) with a local Ollama model (`nomic-embed-text`,
  768-dim, ~10–30 ms/img). Store vectors in an `embeddings` table keyed by `path`.
- Cosine similarity brute-force in NumPy over ~15k vectors (<10 ms) — no vector DB at this scale.
- Modes: text query → top-K; "more like this" → nearest neighbours.
- UI: a semantic search box in the Review toolbar + a "more like this" button on the loupe.

**Steps:** `ollama pull nomic-embed-text` → `photo_cull.py embed` subcommand (populate `embeddings`
for `ok` rows) → `review/server.py` `/api/similar?q=…` and `/api/similar_to/<id>` (cosine in NumPy)
→ frontend.

**Notes:** semantic over the *text qwen wrote*, not pixels — quality rides on caption quality (hence
after P3). For true *visual* similarity, embed the images with a local CLIP-style model — heavier,
separate pass; ship text-first. Complementary to `phash` (near-duplicates / bursts).

---

## P5 — Prompt→version changelog

Trivial, do-whenever: a human-readable note mapping each `prompt_version` hash → what changed and why.
The `prompts` table already stores the exact text; this is just for readability / ordering.

---

## P6 — Reconcile to one DB

**Value: medium (clarity / less foot-gun). Cost: low.** Goal: **one** canonical cull DB — no
`cull.db`-vs-`trial_out/trial.db` split. Today the code defaults (`DB_DEFAULT`/`CSV_DEFAULT` in
`photo_cull.py`, the `--db` defaults in `review/server.py` + `sample_for_review.py`, `dbshell.sh`'s
`DB=`) disagree with where the real run actually lives (`trial_out/trial.db`), and the README documents
`cull.db` throughout — so newcomers (and future-me) can run against the wrong file.

Decide the single canonical path/name, then make every default + all docs point at it:
- `photo_cull.py` (`DB_DEFAULT`, `CSV_DEFAULT`), `review/server.py`, `review/sample_for_review.py`,
  `dbshell.sh`, and `README.md` / `review/README.md` all agree.
- Drop the "trial" framing once it's the real pipeline (it's no longer a trial).

**Open question — `annotations.db`:** it's *deliberately* a separate file (review corrections written
without WAL write-contention against a live run — see `review/server.py` `--annotations`). "One DB in
the limit" could mean either (a) keep it separate but make its *default path* derive cleanly from the
one canonical DB, or (b) fold annotations into a table in the main DB and rely on WAL to avoid
contention. Prefer (a) — the separation earns its keep during multi-night runs; revisit (b) only if the
two-file story still feels like clutter afterward.

---

## Shipped

### Prompt + harness versioning — `bc0bda2` (2026-07-12)

Every processed row is stamped with **`prompt_version`** (`sha256(VLM_PROMPT)[:12]`, auto-derived so
it can't silently drift) and **`harness_version`** (git short SHA of `photo_cull.py`, `-dirty` if
uncommitted). A **`prompts(prompt_version, prompt, first_seen)`** table stores each prompt's exact
text (`register_prompt()`, `INSERT OR IGNORE` at run start) so any version is reconstructable; harness
is reconstructed via git. New columns are in `SCHEMA` for fresh DBs and added by an idempotent `ALTER`
migration in `connect()` for existing ones; both are also in the CSV export.

**Rollout state:** the run was restarted on `bc0bda2` (no `--force`) and is stamping the ~7.9k
`pending` rows as it goes. The ~7k older `ok` rows predate the columns and read NULL — back-fill them
with prompt `99ac55d6344e` / harness `c5e2958` (the `c5e2958` run that produced them; verified same
prompt text, so analysis-equivalent to `bc0bda2`):
```sql
UPDATE images SET prompt_version='99ac55d6344e', harness_version='c5e2958'
WHERE status='ok' AND prompt_version IS NULL;
```

### derive() CV-gate fix + `keep_hint` + `rederive` (2026-07-14)

`derive()` now trusts `aesthetic>=7` (or `scene=="night"`) over the CV gate — never hard-rejected on
CV — and docks a star only on a *severe* blowout, fixing the false over/under demotions and shallow-DoF
false-rejects from the audit. `keep_hint` is now a persisted column (SCHEMA + migration + stamped on
write + in CSV). New **`rederive`** subcommand recomputes base_verdict / quality_stars / verdict /
color_label / reason for `ok` rows from stored columns — no model calls, idempotent; clustering stays
in `export`.

**Safe on the pre-P1 library:** rows lacking a stored `keep_hint` infer it from the existing verdict
(a `keep` implies the hint was set, and the new keep rule is strictly more permissive), so existing
keeps are preserved and nothing is falsely promoted. Verified on a snapshot: keep 3326→3326, reject
3192→2751 (false-rejects rescued), stars corrected, idempotent. review→keep promotions still need a
reprocess to capture real keep_hint.

### Lightroom round-trip: safe export + feedback loop (2026-07-14)

**Export is now merge-by-default** (`export --xmp`): preserves any Rating/Label/Description you set in
LR, adds only the AI fields, and no longer duplicates keywords on re-runs (reads existing
`dc:Subject`/`HierarchicalSubject`, adds only new). `--no-merge` restores fresh-write (skip existing).
New **`--folder DIR…`** writes sidecars for just one shoot (bursts/CSV stay global). Falls back safely
to non-merge if exiftool is missing.

**New `feedback` command** closes the loop (the old "step 6"): reads your final LR star rating + color
label back from each XMP sidecar into `user_rating` / `user_label`, then reports AI-vs-you agreement —
star exact / within-1 / Pearson correlation, and crucially the **false-reject list** (frames the AI
rejected that you rated a keeper — the costly misses). This is the objective quality metric the
original "Option 1" wanted; every future `derive()`/prompt tweak now has a number to move.

**Caveat (workflow):** it reads the `.xmp` sidecar, not LR's catalog — so enable LR's "automatically
write changes into XMP" (or ⌘/Ctrl-S) before analysis/feedback, or catalog-only ratings won't be
seen. Pick/reject flags are catalog-only in LR and never round-trip through XMP.

### Star-tier remap

`stars = (aesthetic + 1) // 2` (9–10→5, 7–8→4, 5–6→3, 3–4→2, 1–2→1), keeping the −1 penalties for
soft / bad-exposure / eyes-closed. Live in `derive()`; 5★ is reachable.
