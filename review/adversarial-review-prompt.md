# Adversarial review of qwen's photo descriptions — reviewer prompt

You are auditing the local vision model (qwen3.5:9b) that captioned and culled this photo
library. Your stance is **adversarial**: actively hunt for where qwen is **wrong about the
actual photo** — do not just confirm it. Then turn the failures into concrete edits to
`VLM_PROMPT` in `photo_cull.py`.

## Orient first
- **DB** (source of truth): `trial_out/trial.db` (SQLite). Each `ok` row holds qwen's outputs
  — `caption, subject, scene, tags, issues, people_count, eyes_closed, aesthetic` (1–10) — plus
  measured CV: `sharpness, exposure_flag, blown_pct, crushed_pct`. Verdict/stars are derived.
- Read the current **`VLM_PROMPT`** string in `photo_cull.py` so you know exactly what qwen was
  told to produce, and read `derive()` for how verdict/stars come from those fields.
- You **may read the images** for this task (normally the tool does the looking; here the user
  explicitly wants your second opinion).

## Procedure
1. Render a random sample + dump qwen's calls:
   ```
   ./venv/bin/python review/sample_for_review.py 15 /tmp/rev_sample
   ```
   (arg1 = N frames, arg2 = out dir, arg3 = db. Writes `NN.jpg` previews at 768px + `meta.txt`.)
2. Read `/tmp/rev_sample/meta.txt` (qwen's calls), then Read the `NN.jpg` previews. Keep the
   batch small (~15) and previews modest — respect the token budget.
3. For each photo, compare **your** read to qwen's and look hard for these failure modes:
   - **Confabulation** — invented specifics it cannot know: city / landmark / brand / art-style
     names (e.g. calling a Toledo street "Granada"). Check any legible signage.
   - **False `eyes_closed`** — flagged on a downward gaze / smile-squint / singing / turned-away
     face → wrongly rejects good candids.
   - **Aesthetic miscalibration** — over-generous, clustered high; rating soft/blurry frames
     high; not using the low end.
   - **Missed distractions** — cables/power lines, poles, cranes, signs, a merge (pole out of a
     head), a horizon through a person → should be in `issues`, often empty.
   - **Wrong subject / scene / people_count** — subject isn't the main thing; wrong genre;
     miscount (note: `people_count` = visible **faces**, so back-turned people = 0 by design).
   - **Caption over-interpretation** — asserting intent/relationships not actually visible.
4. Also sanity-check the measured fields: flag where the **CV gate** looks wrong for the scene
   (a night/astro or intentionally-soft frame the sharpness metric misreads → false reject).

## Output
- A brief per-frame verdict: does qwen's read hold up? What's wrong, with specifics.
- Aggregate the patterns (which failure modes recur, and roughly how often).
- **Concrete, copy-pasteable edits to `VLM_PROMPT`.** If a problem is a threshold/logic issue,
  not a wording issue, say so and propose the `derive()` / constant change instead.
- Be honest about what qwen got **right** — it's mostly good; the value is the specific misses.
- If you change the prompt, note that only NEW inferences use it: a running process holds the
  old prompt in memory, so applying it means restarting the run (resumable) and/or
  `run … --reprocess reject` / `--force`.

## Context (as of this file)
The prompt was already refined once from a 25-frame review (anti-confabulation, tighter
`eyes_closed`, aesthetic 1–10 rubric, hunt distractions, added `night`/`sports` scenes), and
`derive()` now trusts strong (aesthetic≥8) or `night` frames over the CV sharpness gate; stars
use `(aesthetic+1)//2`. A full ~15k `--force` reprocess on that new prompt was launched. So this
is a **second-round audit** — verify those fixes held on real frames and find what's left.
