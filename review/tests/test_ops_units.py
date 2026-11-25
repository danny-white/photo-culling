"""The systemd units in ops/ keep the settings the live setup depends on. These are plain-file
checks: nothing here starts, reloads or reads a real unit. Run from the repo root:
    ./venv/bin/python -m unittest discover -s review/tests -t .
"""
import configparser
import unittest
from pathlib import Path

OPS = Path(__file__).resolve().parents[2] / "ops"


def unit(name: str) -> configparser.ConfigParser:
    """A unit file read as ini (systemd's format is close enough for the keys checked here)."""
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str          # systemd keys are case-sensitive
    cp.read(OPS / name, encoding="utf-8")
    return cp


class OpsUnits(unittest.TestCase):
    def test_review_server_unit_is_in_the_repo_with_the_live_flags(self):
        s = unit("photo-review.service")["Service"]
        self.assertEqual(s["Type"], "simple")
        self.assertEqual(s["WorkingDirectory"], "/home/danny/photo-culling")
        exe = s["ExecStart"].split()
        self.assertEqual(exe[:2], ["/home/danny/photo-culling/venv/bin/python",
                                   "/home/danny/photo-culling/review/server.py"])
        for flag, value in (("--db", "/home/danny/photo-culling/trial_out/trial.db"),
                            ("--annotations", "/home/danny/photo-culling/trial_out/annotations.db"),
                            ("--host", "0.0.0.0"), ("--port", "8000")):
            self.assertEqual(exe[exe.index(flag) + 1], value, flag)
        # a tagging run started from the monitor must survive a server restart
        self.assertEqual(s["KillMode"], "process")
        self.assertEqual(s["Restart"], "on-failure")
        self.assertEqual(s["RestartSec"], "5")
        self.assertEqual(unit("photo-review.service")["Install"]["WantedBy"], "default.target")

    def test_ingest_unit_times_out_instead_of_hanging_on_a_stale_mount(self):
        s = unit("photo-cull-ingest.service")["Service"]
        self.assertEqual(s["Type"], "oneshot")
        self.assertEqual(s["TimeoutStartSec"], "12h")

    def test_ingest_timer_has_no_persistent(self):
        t = unit("photo-cull-ingest.timer")["Timer"]
        self.assertEqual(t["OnUnitActiveSec"], "15min")
        self.assertNotIn("Persistent", t)


if __name__ == "__main__":
    unittest.main()
