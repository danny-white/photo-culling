"""The day review: its markup grows with the rejects, not their square (web.md "O(n²)"), and it
reloads the day when it opens, so Lightroom's receipts show (the iPhone's refresh)."""
import json
import unittest

from webharness import DAY, BrowserCase

SYN = "2099/2099-01-01"


def synthetic_day(n):
    """A day of n single frames, every one rejected: served by the browser test, not the server."""
    def frame(i):
        return {"id": 9_000_000 + i, "file": f"SYN{i:05d}.ARW", "partners": [], "partner_ids": [], "sharpness": None,
                "af": None, "badges": [], "lr": None, "lens": None, "caption": None, "place": None,
                "blown_pct": None, "mean_lum": None,
                "decision": {"flag": "reject", "stars": None, "note": "", "state": "draft", "outcome": None}}
    return {"day": SYN, "folder": "2099-01-01", "date": "2099-01-01", "summary": None,
            "budget": {"stacks": 20, "per_hour": 10, "hours": 2.0}, "progress": None,
            "stacks": [{"id": i, "kind": "single", "lead": 9_000_000 + i, "frames": [frame(i)]} for i in range(n)]}


class LargeReview(BrowserCase):
    def test_900_rejects(self):
        body = json.dumps(synthetic_day(900))
        self.page.route("**/m/api/day/" + SYN, lambda route: route.fulfill(
            status=200, content_type="application/json", body=body))
        self.open("/m/#/day/" + SYN)
        self.wait_screen("summary")
        size = self.page.evaluate("document.querySelector('#view').innerHTML.length")
        self.assertLess(size, 300_000, "the review's markup for 900 rejects")
        self.assertEqual(self.page.eval_on_selector_all(".sm-th[data-act=look]", "e => e.length"), 900)
        self.assertFalse(self.page.query_selector("[data-order]"))
        self.page.click('.sm-th[data-id="9000450"]')
        self.wait_screen("large")
        self.assertIn("451 of 900", self.text(".top .t"))
        self.key("ArrowRight")
        self.assertIn("452 of 900", self.text(".top .t"))
        self.assertIn("SYN00451", self.text(".top .t"))
        self.key("ArrowLeft")
        self.key("ArrowLeft")
        self.assertIn("450 of 900", self.text(".top .t"))
        self.key("Escape")
        self.wait_screen("summary")


class ReviewRefresh(BrowserCase):
    def test_the_review_shows_lightrooms_latest_when_it_opens(self):
        d = self.server.reject_all(DAY, stacks=15, finish=False)
        status, sent = self.server.write("POST", f"/m/api/day/{DAY}/send", {})
        self.assertEqual(status, 200, sent)
        self.server.log.clear()                         # count the browser's reads only
        self.open_day()
        self.assertEqual(self.cursor(), 15, "on the last stack, the only one open")
        # Lightroom syncs while the day is open: one decision landed, one lost to your own flag
        first, burst = d["stacks"][0]["frames"][0]["file"], d["stacks"][1]["frames"][0]["file"]
        self.server.receipt(f"2026-10-01\t{first}\tapplied\t", f"2026-10-01\t{burst}\tyour_flag_kept\tyou picked it")
        self.key("x")                                   # the last stack: the day is finished, the review opens
        self.wait_screen("summary")
        self.page.wait_for_selector("text=1 in Lightroom")
        text = self.text(".scroll")
        self.assertIn("Your Lightroom flag won", text)
        self.assertNotIn("Rejected" + burst, text)
        days = [st for m, path, st in self.server.log if path == "/m/api/day/" + DAY]
        self.assertEqual(days, [200, 200], "opened once, and read again by the review")

    def test_a_drop_keeps_the_reviews_place(self):
        d = self.server.get("/m/api/day/" + DAY)
        for st in d["stacks"][:15]:                     # 15 stacks kept: 10 over the budget of 5
            self.server.decide(DAY, [{"id": f["id"], "flag": "pick", "via": "card"} for f in st["frames"]])
        self.page.set_viewport_size({"width": 1280, "height": 600})
        self.open_day()
        self.key("x")
        self.wait_screen("summary")
        self.page.wait_for_selector(".sm-th.kept")
        self.page.evaluate("document.querySelector('#view > .scroll').scrollTop = 150")
        self.page.click(".sm-th.kept >> nth=3")
        self.wait_toast("Dropped")
        top = self.page.evaluate("document.querySelector('#view > .scroll').scrollTop")
        self.assertAlmostEqual(top, 150, delta=2)


if __name__ == "__main__":
    unittest.main()
