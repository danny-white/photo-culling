"""photo_cull's day summaries: what the model is given (day_facts) and the clean-up of its
answer. No model call. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import sys
import unittest
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import photo_cull as pc  # noqa: E402


def ts(h, m):
    return datetime(2026, 9, 29, h, m).timestamp()


class DayFacts(unittest.TestCase):
    rows = [
        {"path": "a", "capture_ts": ts(7, 42), "caption": "A misty forest trail", "subject": "trail",
         "tags": '["forest", "trail", "mist", "morning", "extra"]', "place": "Lyons, Colorado, United States", "burst_id": 1},
        {"path": "b", "capture_ts": ts(7, 42), "caption": "A misty forest trail, again", "subject": "trail",
         "tags": "[]", "place": "Lyons, Colorado, United States", "burst_id": 1},           # same burst: one line
        {"path": "c", "capture_ts": ts(20, 15), "caption": "Sunset over the plains", "subject": "sunset",
         "tags": "not json", "place": None, "burst_id": None},
    ]

    def test_facts(self):
        f = pc.day_facts(self.rows)
        self.assertIn("Shooting 07:42 to 20:15; 3 photos in 2 groups.", f)
        self.assertIn("Places (from GPS): Lyons, Colorado, United States (2 photos).", f)
        self.assertIn("Most common subjects: trail (2), sunset (1).", f)
        self.assertIn("07:42 A misty forest trail [forest, trail, mist, morning]", f)   # first 4 tags
        self.assertIn("20:15 Sunset over the plains", f)
        self.assertNotIn("again", f)

    def test_no_gps(self):
        self.assertIn("Places (from GPS): none recorded.", pc.day_facts(self.rows[2:]))

    def test_busy_days_are_sampled(self):
        rows = [{"path": str(i), "capture_ts": ts(8, 0) + i * 60, "caption": f"photo {i}", "burst_id": i} for i in range(300)]
        lines = pc.day_facts(rows).split("Photos in order:\n")[1].splitlines()
        self.assertEqual(len(lines), pc.DAYSUM_MAX_LINES)
        self.assertTrue(lines[0].endswith("photo 0") and lines[-1].endswith("photo 299"))

    def test_weekday_lead_is_dropped(self):
        for raw, want in (("Sunday in Mammoth Lakes featuring hiking", "Mammoth Lakes featuring hiking"),
                          ("On Tuesday, coastal cliffs at dusk", "coastal cliffs at dusk"),
                          ("Coastal cliffs at dusk", "Coastal cliffs at dusk")):
            self.assertEqual(pc._WEEKDAY_LEAD.sub("", raw).strip(), want)


if __name__ == "__main__":
    unittest.main()
