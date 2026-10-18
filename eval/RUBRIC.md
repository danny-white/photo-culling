# Caption eval rubric

The production captioner is `qwen3.5:9b` with `VLM_PROMPT` in `photo_cull.py`. This eval asks
whether a better prompt (or later, a better model or adapter) makes its **factual** fields more
accurate. Judgement fields (`aesthetic`, `keep_hint`, `issues`, `eyes_closed`) are out of scope:
the AI's keep/reject judgement is not used anywhere.

Two passes, done by Claude. Each looks at the photo itself (`eval/images/<id>.jpg`, the 1616 px
preview):

1. **Label**: write the reference answer, without seeing any model's output.
2. **Grade**: compare one model's output with the photo and the reference, and list its errors.

## 1. Label (reference answer)

Write `eval/labels/<id>.json`:

```json
{
  "id": 123,
  "caption": "One sentence, only what is visibly present.",
  "subject": "the single main subject, a few words",
  "scene": "portrait | landscape | wildlife | street | macro | architecture | food | event | sports | night | other",
  "people_count": 2,
  "tags": ["4-8", "lowercase", "keywords"],
  "activity": "what the subject is doing, or empty",
  "indoor_outdoor": "indoor | outdoor | unknown",
  "time_of_day": "day | golden_hour | blue_hour | night | unknown",
  "animals": ["dog"],
  "content_type": "photo | screenshot | document | graphic",
  "visible_text": "only text you can actually read, else empty",
  "uncertain": ["things a careful captioner should NOT assert, e.g. 'gender of the far-left person', 'whether the object thrown is a snowball or a ball'"],
  "must_mention": ["the 1-3 things a search for this photo would most likely use"],
  "confidence": "high | medium | low"
}
```

Rules. These match what the production prompt asks for, so the reference answers the same question:
- `people_count` is **people whose faces are visible**, as the prompt defines it. Count carefully.
  Use an exact number up to 10; for a crowd, give your best estimate and add "exact crowd size" to
  `uncertain`.
- Name no specific city, landmark, brand or art style unless signage in the image says so.
- Hedge rather than guess: if gender, age, emotion, relationships, species or an action can't
  really be told from the pixels, leave it out of the caption and list it in `uncertain`.
- `must_mention` is for search. It's the thing a person would type to find this photo ("snowball
  fight", "birthday cake", "heron").
- `confidence: low` when the photo is too dark, blurred or abstract to label well. Low-confidence
  photos are reported separately.

## 2. Grade (one model output against the reference)

Write `eval/grades/<run>/<id>.json`:

```json
{
  "id": 123,
  "run": "baseline-99ac55d6",
  "caption_errors": [
    {"type": "hallucination | misidentification | wrong_count | over_assertion | wrong_setting | missed_subject",
     "detail": "short, concrete: 'says thumbs-up; the hand is throwing a snowball'"}
  ],
  "tags_total": 6,
  "tags_wrong": 1,
  "tags_wrong_list": ["wedding"],
  "people_count_ok": true,
  "activity": "ok | wrong | missing | n/a",
  "indoor_outdoor_ok": true,
  "time_of_day_ok": true,
  "scene_ok": true,
  "animals_ok": true,
  "visible_text": "ok | invented | missed | n/a",
  "must_mention_hit": 2,
  "must_mention_total": 3,
  "notes": ""
}
```

Error types for `caption_errors`. Count each distinct mistake once, and judge against **the photo**:
the reference is a guide, not the truth, so if the reference is wrong, say so in `notes` and grade
against the photo.
- `hallucination`: something stated that isn't there (an object, a person, an animal, an action).
- `misidentification`: something that is there, called the wrong thing (wrong animal, wrong
  object, wrong action, or the snowball read as a thumbs-up).
- `wrong_count`: a stated number of people or things that is wrong. For people, also fill in
  `people_count_ok`: the field must equal the reference exactly, or be within 20% for a crowd that
  the reference marks uncertain.
- `over_assertion`: something stated as fact that the pixels can't support, usually anything in
  the reference's `uncertain`: gender, age, emotion, relationship, identity, a named place, or
  intent.
- `wrong_setting`: indoor/outdoor, season, weather, time of day or kind of place that is plainly
  wrong in the caption.
- `missed_subject`: the caption is about something minor and misses the main subject.

Style isn't an error: wording, length, or a different but true choice of detail.

`tags_wrong` counts tags that are false or unsupported for this photo; filler and vague tags are
not wrong. `must_mention_hit` counts reference `must_mention` items that appear (same meaning, any
wording) in the caption or tags.

## Metrics (`eval/score.py`)

Per run and split (dev, test), with bootstrap 95% intervals:
- **Primary:** share of photos with at least one caption error of type hallucination,
  misidentification, wrong_count or over_assertion.
- The rate of each error type; tag precision (1 − wrong/total); people_count exact rate; activity
  ok rate; enum accuracies; invented visible text; must_mention recall.
- Low-confidence photos are excluded from the primary metric and reported separately.

The dev split is for reading errors and writing the prompt. The test split is only scored, never
read while writing prompts.
