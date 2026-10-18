# Brief for a labelling subagent

You are writing **reference labels** for a photo-caption eval. Read `~/photo-culling/eval/RUBRIC.md`
section 1 ("Label") first and follow it exactly.

For each id in your batch:
1. Look at the photo with the Read tool: `~/photo-culling/eval/images/<id>.jpg`. Look properly,
   since this is the reference answer. Check counts, hands, what objects actually are, and any
   readable text.
2. Write `~/photo-culling/eval/labels/<id>.json` in the rubric's format. Valid JSON, `id` as an
   int, and every field present.

Rules:
- Do **not** open `eval/set.json`, `eval/runs/` or `eval/grades/`. You must not see any model's
  caption, because the label has to be independent.
- Be literal and careful rather than evocative. A careful archivist's sentence, not marketing.
- Put anything you're unsure of in `uncertain` and keep it out of the caption. Don't guess gender,
  age, emotion, relationships or place names.
- If a file already exists for an id, skip it.
- Don't write anything outside `eval/labels/`.

When done, reply with one line per id: `<id> <confidence> <people_count> <subject>`, then any
photos you found hard to label and why (one line each).
