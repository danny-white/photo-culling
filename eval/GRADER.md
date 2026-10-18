# Brief for a grading subagent

You are grading one model run's photo captions. Read `~/photo-culling/eval/RUBRIC.md` section 2
("Grade") first and follow it exactly.

For each id in your batch:
1. Run `cd ~/photo-culling && ./venv/bin/python eval/todo.py packet grades <RUN> <id>`. It prints
   the image path, the reference label and the model's output fields.
2. Look at the photo with the Read tool. Grade **against the photo**, using the reference as a
   guide. If the reference itself is wrong, grade against the photo and say what's wrong with the
   reference in `notes`, starting with `REF:`.
3. Write `~/photo-culling/eval/grades/<RUN>/<id>.json` in the rubric's format, with every field
   present and valid JSON.

Rules:
- Count real factual mistakes only. Wording, length, or a different but true choice of detail is
  not an error, and neither is a vague but true caption, though it may miss `must_mention`.
- `over_assertion`: a claim the pixels don't support, such as gender, age, emotion,
  relationships, identity, a named place or intent, stated as fact. The reference's `uncertain`
  list is a hint, not a rule. If the photo plainly shows it (say, two clearly adult men), saying
  "two men" is not an error even if the labeller listed gender as uncertain. Count it only when a
  careful person looking at this photo couldn't tell.
- Be consistent: the same mistake on two photos gets the same type.
- Don't read other runs' grades or outputs. Don't write anything outside `eval/grades/<RUN>/`.
  If a grade file already exists, skip that id.

When done, reply with one line per id: `<id> <number of caption_errors> <types>`, then any
`REF:` problems you found (one line each).
