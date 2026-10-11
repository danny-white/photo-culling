# Overnight adversarial review — autonomous driver prompt

You are running **unattended, overnight, with no human watching**. Work fully autonomously:
never ask questions, never wait for confirmation — just execute the loop below until the API
budget cap stops you. Your job is a **second-round adversarial audit** of the local vision model
(qwen) now that its prompt was refined and a full `--force` reprocess is underway.

## Read these first (once)
1. `review/adversarial-review-prompt.md` — the canonical reviewer procedure and the exact
   failure modes to hunt (confabulation, false `eyes_closed`, aesthetic miscalibration, missed
   distractions, wrong subject/scene/people_count, caption over-interpretation, CV-gate errors).
   Follow it.
2. In `photo_cull.py`: the `VLM_PROMPT` string and the `derive()` function — so you know exactly
   what qwen was told and how verdict/stars are computed. Your edit suggestions must be concrete
   against these.

## The single output file
Append everything to `review/adversarial-review-findings.md` (already seeded with a header).
**Persist after every batch. Never hold findings only in memory.** Append with a crash-safe Bash
heredoc so nothing is lost if the budget cap cuts you off mid-run:
```
cat >> review/adversarial-review-findings.md <<'EOF'
...your markdown for this batch...
EOF
```

## The loop (batches of 10)
Repeat until the budget stops you (expected) or the fresh pool is clearly exhausted:
1. Sample 10 fresh frames — **only the NEW prompt's outputs**:
   ```
   REVIEW_SINCE="$(cat trial_out/old_prompt_cutoff.txt)" ./venv/bin/python review/sample_for_review.py 10 trial_out/rev_sample
   ```
2. Read `trial_out/rev_sample/meta.txt` (qwen's calls for this batch), then Read the previews
   `trial_out/rev_sample/01.jpg` … `10.jpg`.
3. For each frame, compare **your** read of the image to qwen's call and hunt the failure modes.
   Be adversarial — look hard for where qwen is *wrong about the actual photo* — but note where
   it's right too (it's mostly good; the value is the specific misses).
4. **Append** a `### Batch N` block: for each frame a one-line verdict (holds up / specific error
   + failure-mode tag), plus any batch-level note. Keep it specific (filename + what's wrong),
   concise, and copy-paste friendly.
5. Next batch (the sample dir is overwritten each time — fine).

## Synthesis (the real deliverable — keep it current)
After **every 5th batch**, and again as your **final action**, append a self-contained:
```
## Synthesis snapshot — through batch N
```
containing (a) the recurring failure modes with rough frequencies, and (b) **concrete,
copy-pasteable edits to `VLM_PROMPT`** (and, where it's a threshold/logic issue rather than
wording, the specific `derive()`/constant change instead). Each snapshot must stand alone — the
**last** one is what the user acts on, and the budget may end the run without warning.

## Guardrails
- **Read-only everywhere except the findings file.** Do NOT modify `photo_cull.py`,
  `sample_for_review.py`, the database, or any other code. Do NOT kill, restart, or interfere
  with the running analysis job (`photo_cull.py run`). You only ever *propose* edits in the file.
- The sample is drawn from frames reprocessed since the prompt cutoff, which skews toward
  earlier-processed shoots — note this caveat once in your findings so the reader weights it.
- Duplicates across batches (same filename twice) are fine; just proceed.
- Work efficiently: modest reasoning per frame; don't re-read the big files each batch.

Begin now.
