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

## Star-tier remap — SHIPPED

`stars = (aesthetic + 1) // 2` (9–10→5, 7–8→4, 5–6→3, 3–4→2, 1–2→1), keeping the −1 penalties
for soft / bad-exposure / eyes-closed. Committed and applied in the full reprocess, so 5★ is
now reachable.
