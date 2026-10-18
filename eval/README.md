# Caption eval

Measures how accurate the production captioner (`qwen3.5:9b` + `VLM_PROMPT` in `photo_cull.py`) is
on its **factual** fields, and whether a new prompt beats it. `RUBRIC.md` defines the label and
grade formats and the metrics. Run everything from the repo root with `./venv/bin/python`.

Photos, labels, grades and run outputs are private or regenerated, so they are gitignored
(`eval/images/`, `runs/`, `labels/`, `grades/`, `report*`). Only the scripts, RUBRIC and this file
are tracked.

## Steps

1. **Sample.** `eval/sample.py` draws 100 dev + 100 test photos from `trial_out/trial.db` (read-only)
   into `eval/set.json` and `eval/images/<id>.jpg`. It won't overwrite an existing `set.json`
   (`--force`), since labels and grades are keyed by its ids.
2. **Label.** `eval/todo.py labels` prints batches of ids with no `eval/labels/<id>.json`; a Claude
   subagent per batch looks at each image and writes the label (RUBRIC section 1), without seeing
   any model output.
3. **Run the baseline.** `eval/run_qwen.py --name baseline --split all` (resumable, about 6 s a
   photo once the model is loaded). Output goes to `eval/runs/baseline/`.
4. **Grade.** `eval/todo.py grades baseline` lists ids ready to grade. For each,
   `eval/todo.py packet grades baseline ID` prints the image path, the label and the run's factual
   fields; the grader writes `eval/grades/baseline/<id>.json` (RUBRIC section 2).
5. **Score.** `eval/score.py baseline` prints the table (and writes `eval/report.json`).
6. **New prompt.** Write it to a file, reading errors from the **dev** split only.
7. **Run, grade, score it.** `eval/run_qwen.py --name v2 --prompt-file eval/prompts/v2.txt`, grade
   `v2` as in step 4, then `eval/score.py baseline v2` for the paired comparison (photos fixed and
   broken, with a bootstrap interval on the difference).

## The rule

**The test split is never read while writing prompts.** Look at dev outputs, dev grades and dev
errors only. Run `--split test` and score it once the prompt is settled; the test numbers are for
reporting, not for tuning. (Scoring both splits at once is fine; reading the test rows is not.)

## Notes

- `run_qwen.py` imports `photo_cull` and calls `analyze_vlm`, so the schema, `think=False`,
  temperature 0, `num_ctx` and the OOM ladder are production's. Only the prompt text (and, if
  asked, the primary model) can differ. A run name can't be reused with a different prompt or model.
- It waits while another `photo_cull.py run`/`analyze` (the ingest watcher) is running. There is no
  inference lock file in the repo.
- `score.py` leaves low-confidence photos (label `confidence: low`) out of every metric and counts
  them on their own line; a paired difference below zero means the second run has fewer errors.
- Ids are `trial.db` rowids. `set.json` also holds each photo's path, which is the stable key.
- Production rows in `set.json` (`prod`) carry the `prompt_version` that made them; the library mixes
  two prompt versions, so they are not all the current `VLM_PROMPT`.
- Tests: `review/tests/test_eval_tools.py`.
