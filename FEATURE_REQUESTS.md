# Feature requests / backlog

## Semantic keyword search (parked — phase 2)

**Status:** parked. Build after the library is fully reprocessed on the new prompt, so
embeddings reflect the improved captions.

**Goal:** find photos by *concept*, not exact string — e.g. "church interiors", "beach at
sunset", or "more like this" from a given photo (finds *cathedral / chapel / nave* even
without the exact word).

**Design (fully local, no external services):**
- Embed each photo's text (caption + tags + subject) with a local Ollama embedding model
  (`nomic-embed-text`, 768-dim, ~10–30 ms/image, CPU-light). Store vectors in an
  `embeddings` table keyed by `path`.
- Search by cosine similarity: brute-force in NumPy over ~15k vectors (<10 ms) — **no vector
  DB needed** at this scale.
- Modes: **text query** (embed the query → top-K) and **"more like this"** (a photo's vector
  → nearest neighbours).
- UI: a semantic search box in the Review toolbar + a "more like this" button on the loupe.

**Steps when built:**
1. `ollama pull nomic-embed-text`
2. `photo_cull.py embed --db …` subcommand → populate the `embeddings` table for `ok` rows.
   Run **after** the final prompt-consistent reprocess.
3. `review/server.py`: `/api/similar?q=…` and `/api/similar_to/<id>` (cosine in NumPy).
4. Frontend: semantic search box + "more like this".

**Caveats / notes:**
- Semantic over the **text qwen wrote**, not pixels — quality rides on caption quality.
- For true **visual** similarity (same-looking scene regardless of words), embed the
  **images** with a local CLIP-style model — heavier, separate pass. Ship text-first; add
  visual later if wanted.
- Complementary to the perceptual hash (`phash`), which is for near-**duplicates** / bursts.

---

## Prompt + harness versioning in the DB — SHIPPED (2026-07-12)

Motivated by today's reprocess: after refining `VLM_PROMPT` I had to *manually* reset every
old-prompt row to `pending` because nothing recorded which prompt produced a row. That's now a
`WHERE prompt_version != <current>` query.

**What shipped:**
- **`prompt_version`** — `sha256(VLM_PROMPT)[:12]`, a module constant next to `VLM_PROMPT`. Auto-
  derived, so it changes exactly when the prompt text changes and can never silently drift.
- **`harness_version`** — short git SHA of `photo_cull.py` (+ `-dirty` if uncommitted), via
  `harness_version()`. Captures the *code* identity: `derive()`, the CV thresholds and model params
  affect outputs too, so two rows are only truly comparable when prompt **and** harness match.
- Both are stamped on **every** processed row (ok and error) in the `run` loop, and both are in the
  CSV export.
- **`prompts(prompt_version, prompt, first_seen)`** table — `register_prompt()` upserts the exact
  prompt text (INSERT OR IGNORE) at run start, so any `prompt_version` is fully reconstructable
  (`SELECT prompt FROM prompts …` / `JOIN … USING(prompt_version)`). Harness is reconstructed via
  git (`git checkout <sha>`); a `-dirty` row isn't perfectly reproducible — the documented gap.
- New columns are in `SCHEMA` for fresh DBs and added by an **idempotent `ALTER` migration** in
  `connect()` for existing ones (there was no migration path before).

**Applies to future runs.** Rows already in `trial.db` carry NULL versions (= unknown/old), the
intended back-fill case. The current in-flight run holds old code in memory, so its rows are NULL
too — but we know they used prompt `99ac55d6` / harness `c5e2958`, so they can be back-filled once
it finishes (register the prompt, then stamp the `ok` rows).

**Still open (nice-to-haves, not built):**
- **`--reprocess-stale`** — reset rows where `prompt_version`/`harness_version` != current back to
  `pending`; mirrors the existing `--reprocess VERDICT` (photo_cull.py:1037). Optionally have plain
  `run` *warn* when stale rows exist so a prompt/code edit surfaces the drift.
- **Persist `keep_hint` + a `--rederive` subcommand** so a `derive()` change replays from stored
  columns with no VLM re-inference — see the adversarial-review findings; the exposure/sharpness
  fixes are derive-only and would back-fill instantly.
- Optional human changelog mapping each `prompt_version` hash → what changed and why (the `prompts`
  table already keeps the text; this is just for readability/ordering).

---

## derive() CV-gate fix — parked (2026-07-12)

From the 24-frame interactive audit (full patch + per-frame evidence in
`review/adversarial-review-findings.md`): `derive()` demotes or rejects frames qwen scored
*correctly*, because the CV gate is subject-blind. Recurring:
- bright sky / snow → false `exposure=over` → −1★ + keep blocked (e.g. DSC02478, DSC00763)
- flash-lit night portrait → false `exposure=under` → −1★ + keep blocked (DSC01586)
- intentionally shallow-DoF macro → `sharp` below floor → **hard reject**, and aes 7 just misses
  the `>=8` sharpness rescue (DSC01567)

**Fix** (photo_cull.py:~541): treat a frame with `aesthetic>=7` (or `scene==night`) as *trusted*
over the gate — never hard-rejected on CV — and let only a *severe* blowout dock a star. The patch
is in the findings file and is regression-checked.

**Build it with a cheap backfill, not a reprocess:** the fix is derive-only, computed from
already-stored columns, so it can replay with no VLM re-inference. Blocker: `keep_hint` isn't
persisted, so a bare re-derive can rescue reject→review and fix stars but can't re-promote to keep.
So when built: (1) persist `keep_hint` as a column, (2) add a `--rederive` subcommand that
recomputes verdict/stars/reason from stored columns, (3) apply to the whole library in seconds.

---

## Star-tier remap — SHIPPED

`stars = (aesthetic + 1) // 2` (9–10→5, 7–8→4, 5–6→3, 3–4→2, 1–2→1), keeping the −1 penalties
for soft / bad-exposure / eyes-closed. Committed and applied in the full reprocess, so 5★ is
now reachable.
