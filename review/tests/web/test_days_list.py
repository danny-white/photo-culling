"""The Days list: unsent decisions on each row, Send all (the iPhone's CullSendAllModel), coming
back to the same place, revalidated reads, and escaping (web.md "Back to Days", "Escaping" and the
Send all drift)."""
import json
import unittest

from webharness import DAY, BrowserCase

OTHER = "2019/2019-08-13"
NOT_MOUNTED = {"error": "/mnt/Passport_AICullInbox is not mounted; nothing was sent"}


class Unsent(BrowserCase):
    def setUp(self):
        super().setUp()
        self.server.reject_all(DAY)                          # finished, nothing sent: 32 frames' decisions
        self.unsent = sum(len(s["frames"]) for s in self.server.get("/m/api/day/" + DAY)["stacks"])
        self.server.reject_all(OTHER, stacks=1, finish=False)  # started: one decision
        self.open("/m/")
        self.page.wait_for_selector(".send-all")

    def row(self, day):
        return f'#days-list .day[data-day="{day}"]'

    def show(self, day):
        y = day[:4]
        if not self.page.query_selector(self.row(day)):
            self.page.click(f'.yearbar [data-year="{y}"]')
        self.page.wait_for_selector(self.row(day))
        return self.text(self.row(day))

    def test_rows_show_what_is_not_sent(self):
        finished = self.show(DAY)
        self.assertIn(f"{self.unsent} unsent", finished)
        self.assertEqual(self.text(self.row(DAY) + " .tag"), "Finished, not sent")
        started = self.show(OTHER)
        self.assertIn("1 unsent", started)
        self.assertRegex(self.text(self.row(OTHER) + " .tag"), r"^\d+%$")
        self.assertIn("2 days with decisions not sent yet", self.text(".send-all"))

    def test_send_all(self):
        page = self.page
        page.click(".send-all")
        page.wait_for_selector(".send-sheet")
        ticks = page.eval_on_selector_all(".sa-row", "rs => rs.map(r => [r.dataset.day, r.getAttribute('aria-checked')])")
        self.assertEqual(ticks, [[DAY, "true"], [OTHER, "false"]], "finished days ticked, the rest listed")
        self.assertIn(f"{self.unsent} decisions", self.text(f'.sa-row[data-day="{DAY}"]'))
        self.assertIn("1 decision", self.text(f'.sa-row[data-day="{OTHER}"]'))
        self.assertEqual(self.text("[data-act=sa-send]"), "Send 1 day to Lightroom")
        page.click(f'.sa-row[data-day="{OTHER}"]')
        self.assertEqual(self.text("[data-act=sa-send]"), "Send 2 days to Lightroom")
        self.assertEqual(self.text(".sa-msg"), f"{self.unsent + 1} decisions from 2 days")
        page.click("[data-act=sa-all]")                        # None
        self.assertTrue(page.is_disabled("[data-act=sa-send]"))
        self.assertEqual(self.text("[data-act=sa-send]"), "Pick the days to send")
        page.click(f'.sa-row[data-day="{DAY}"]')
        with page.expect_request("**/m/api/send") as req:
            page.click("[data-act=sa-send]")
        self.assertEqual(req.value.post_data_json, {"days": [DAY]})
        self.assertEqual(req.value.headers.get("x-culling-bay"), "1")
        page.wait_for_selector("text=On the Mac: Sync AI Cull Data")
        self.assertEqual(self.text(".sa-msg"),
                         f"Queued {self.unsent} decisions from 1 day for Lightroom. On the Mac: Sync AI Cull Data.")
        self.assertTrue((self.server.inbox / "cull-decisions.tsv").exists())
        page.click(".send-sheet [data-act=close-sheet]")
        page.wait_for_function("d => !document.querySelector(`#days-list .day[data-day='${d}'] em.unsent`)", arg=DAY)
        self.assertEqual(self.text(self.row(DAY) + " .tag"), "Sent")
        self.assertIn("1 day with decisions not sent yet", self.text(".send-all"))

    def test_send_all_when_the_inbox_is_not_mounted(self):
        self.expect_errors()
        self.page.route("**/m/api/send", lambda route: route.fulfill(
            status=503, content_type="application/json", body=json.dumps(NOT_MOUNTED)))
        self.page.click(".send-all")
        self.page.click("[data-act=sa-send]")
        self.page.wait_for_selector(".sa-msg.warn")
        self.assertEqual(self.text(".sa-msg"), "Not sent: the Lightroom inbox share is not mounted on the PC, "
                                               "so nothing was sent. Try again once it is.")
        self.assertFalse(self.page.is_disabled("[data-act=sa-send]"), "it can be tried again")
        self.assertFalse((self.server.inbox / "cull-decisions.tsv").exists())


class BackToDays(BrowserCase):
    no_pictures = True

    def test_coming_back_keeps_the_place_and_revalidates(self):
        page = self.page
        statuses = lambda: [st for m, path, st in self.server.log if path == "/m/api/days"]   # noqa: E731
        self.open("/m/")
        page.wait_for_selector(".yearbar")
        for y in ("2024", "2022", "2019"):
            page.click(f'.yearbar [data-year="{y}"]')
        page.evaluate("document.querySelector('#days-list').scrollTop = 3000")
        target = page.evaluate("""() => { const l = document.querySelector('#days-list'), r = l.getBoundingClientRect();
            return [...l.querySelectorAll('.day')].find(d => d.getBoundingClientRect().top > r.top + 50).dataset.day; }""")
        page.click(f'#days-list .day[data-day="{target}"]')
        page.wait_for_selector(".detail-rail, .counts")
        page.click(".top [data-act=days]")
        self.wait_screen("days")
        page.evaluate("document.querySelector('#days-list').dataset.mark = 'kept'")
        for _ in range(100):
            if len(statuses()) >= 2:
                break
            page.wait_for_timeout(50)
        page.wait_for_timeout(300)
        self.assertEqual(statuses(), [200, 304], "the server's ETag answers the second read")
        self.assertEqual(page.evaluate("document.querySelector('#days-list').dataset.mark"), "kept",
                         "an unchanged list is not drawn again")
        self.assertAlmostEqual(page.evaluate("document.querySelector('#days-list').scrollTop"), 3000, delta=2)
        for y in ("2024", "2022", "2019"):
            self.assertEqual(page.get_attribute(f'#year-{y}', "aria-expanded"), "true")

    def test_a_changed_list_is_redrawn_in_place(self):
        page = self.page
        self.open("/m/")
        page.wait_for_selector(".yearbar")
        page.click('.yearbar [data-year="2019"]')
        page.evaluate("document.querySelector('#days-list').scrollTop = 1500")
        self.open_day(DAY)
        self.key("x")                                   # the day changes: it is now In progress
        self.wait_toast("Rejected")
        self.drain()
        page.click(".top [data-act=days]")
        page.wait_for_selector(f'#days-list .day[data-day="{DAY}"] em.unsent')
        self.assertAlmostEqual(page.evaluate("document.querySelector('#days-list').scrollTop"), 1500, delta=2)


class Escaping(BrowserCase):
    def test_a_malformed_hash_shows_the_app(self):
        self.open("/m/#/day/100%25%")
        self.page.wait_for_selector("#days-list .day")
        self.assertEqual(self.screen(), "days")
        self.open("/m/gallery.html#/q/100%")
        self.page.wait_for_selector(".yhead")

    def test_the_day_hash_is_written_encoded(self):
        self.open_day(DAY)
        self.assertTrue(self.page.url.endswith("#/day/2026/2026-10-01"))
        weird = "2019/2019 & co"
        self.page.route("**/m/api/day/**", lambda route: route.fulfill(
            status=404, content_type="application/json", body='{"error": "no such day"}'))
        self.expect_errors()
        self.page.evaluate("d => { location.hash = '#/day/' + d.split('/').map(encodeURIComponent).join('/'); }", weird)
        self.page.wait_for_selector("text=Could not load 2019/2019 & co")

    def test_odd_year_keys_are_escaped(self):
        odd = {"day": "\"<b>x/odd", "folder": "odd", "date": None, "frames": 1, "stacks": 1, "thumbs": [],
               "last_ts": 0, "place": None, "places": [], "gps_frames": 0, "summary": None, "decided": 0,
               "sent": 0, "landed": 0, "conflicts": 0, "lr_done": 0, "finished": False, "sent_at": None, "unsent": 0}

        def days(route):
            body = route.fetch().json()
            body["days"].append(odd)
            route.fulfill(status=200, content_type="application/json", body=json.dumps(body))
        self.page.route("**/m/api/days", days)
        self.open("/m/")
        self.page.wait_for_selector(".yearbar")
        self.page.click('.yearbar [data-year="\\"<b>"]')
        self.page.wait_for_selector('#days-list .day[data-day="\\"<b>x/odd"]')
        self.assertEqual(self.page.eval_on_selector_all("#days-list .year b", "bs => bs.map(b => b.textContent)")[-1], '"<b>')
        self.assertFalse(self.page.query_selector("#days-list .year b b"), "no markup from the folder name")


if __name__ == "__main__":
    unittest.main()
