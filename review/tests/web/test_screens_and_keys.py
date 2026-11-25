"""Screens that switched at the wrong moment, and keys that did the wrong thing (web.md §1, §5, §11):
a day opening after you left it, Esc throwing away Undo, Backspace undoing from the review,
browser shortcuts deciding, and input acting on the next card."""
import unittest

from webharness import DAY, BrowserCase

OTHER = "2019/2019-08-13"


class Hold:
    """Holds the requests matching a pattern until released, as a slow PC would."""

    def __init__(self, page, pattern):
        self.page, self.pattern, self.routes = page, pattern, []
        page.route(pattern, lambda route: self.routes.append(route))

    def wait(self, n=1):
        for _ in range(100):
            if len(self.routes) >= n:
                return
            self.page.wait_for_timeout(50)
        raise AssertionError("no request for " + self.pattern)

    def release(self):
        for r in self.routes:
            r.continue_()
        self.routes = []
        self.page.unroute(self.pattern)


class ScreensSwitch(BrowserCase):
    def test_back_while_a_day_loads_stays_on_days(self):
        self.open("/m/")
        self.page.wait_for_selector(f'.day[data-day="{DAY}"]')
        hold = Hold(self.page, "**/m/api/day/" + DAY)
        self.page.click(f'.day[data-day="{DAY}"]')
        hold.wait()
        self.wait_screen("loading")
        self.page.click(".top [data-act=days]")         # Back from the loading screen
        self.wait_screen("days")
        hold.release()
        self.page.wait_for_timeout(600)
        self.assertEqual(self.screen(), "days", "the late answer does not open the day")
        self.assertTrue(self.page.url.endswith("#/"))

    def test_two_quick_opens_show_the_last_one(self):
        self.open("/m/")
        self.page.wait_for_selector(".day")
        hold = Hold(self.page, "**/m/api/day/" + DAY)
        self.page.evaluate("d => { location.hash = '#/day/' + d; }", DAY)
        hold.wait()
        self.page.evaluate("d => { location.hash = '#/day/' + d; }", OTHER)
        self.page.wait_for_selector(".detail-rail")
        title = self.text(".top .t")
        hold.release()                                  # the first day's answer comes last
        self.page.wait_for_timeout(600)
        self.assertEqual(self.text(".top .t"), title)
        self.assertIn("Aug 2019", title)
        self.assertTrue(self.page.url.endswith("#/day/" + OTHER))


class Keys(BrowserCase):
    def test_esc_on_a_card_stays_and_undo_survives_leaving(self):
        self.open_day()
        self.key("x")
        self.wait_toast("Rejected DSC05036")
        self.key("Escape")
        self.page.wait_for_timeout(200)
        self.assertEqual(self.screen(), "cull", "Esc on a card does nothing")
        self.assertEqual(self.cursor(), 1)
        self.page.click(".top [data-act=days]")         # leave the day, and come back
        self.wait_screen("days")
        self.page.click(f'.day[data-day="{DAY}"]')
        self.wait_screen("cull")
        self.assertFalse(self.page.is_disabled(".detail-rail [data-act=undo]"), "Undo is kept for the session")
        self.key("Control+z")
        self.wait_toast("Undone: Rejected DSC05036")
        self.assertEqual(self.cursor(), 0)
        self.drain()
        self.assertEqual(self.flags()[0], [None])

    def test_backspace_undoes_only_on_the_card_and_the_picker(self):
        self.open_day()
        self.key("x")
        self.wait_toast("Rejected DSC05036")
        self.drain()
        last = len(self.server.get("/m/api/day/" + DAY)["stacks"]) - 1
        self.page.click(f'.film-thumb[data-stack="{last}"]')
        self.key("ArrowRight")                          # the review
        self.wait_screen("summary")
        for where in ("summary", "large", "grid"):
            if where == "large":
                self.page.click(".sm-th[data-act=look]")
            if where == "grid":
                self.key("Escape")
                self.wait_screen("summary")
                self.key("g")
            self.wait_screen(where)
            self.key("Backspace")
            self.page.wait_for_timeout(200)
            self.assertEqual(self.screen(), where, "Backspace leaves " + where + " alone")
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.flags()[0], ["reject"])
        self.key("Escape")                              # grid -> review -> card
        self.wait_screen("summary")
        self.key("Escape")
        self.wait_screen("cull")
        self.page.click('.film-thumb[data-stack="1"]')
        self.key("p")                                   # in the picker Backspace undoes
        self.wait_screen("picker")
        self.key("Backspace")
        self.wait_toast("Undone: Rejected DSC05036")
        self.wait_screen("cull")
        self.drain()
        self.assertEqual(self.flags()[0], [None])

    def test_browser_shortcuts_decide_nothing(self):
        self.open_day()
        self.page.click('.film-thumb[data-stack="1"]')  # a burst
        for combo in ("Control+a", "Control+1", "Control+5", "Meta+1", "Control+k", "Alt+x", "Control+x", "Control+p",
                      "Meta+Enter", "Control+Backspace"):
            with self.subTest(combo=combo):
                self.key(combo)
                self.page.wait_for_timeout(50)
                self.assertEqual(self.screen(), "cull")
                self.assertEqual(self.cursor(), 1)
        self.page.click('.film-thumb[data-stack="0"]')  # a single
        for combo in ("Control+1", "Meta+3", "Alt+p"):
            with self.subTest(combo=combo):
                self.key(combo)
                self.page.wait_for_timeout(50)
                self.assertEqual(self.cursor(), 0)
        self.assertEqual(self.queued(), [])
        self.page.wait_for_timeout(700)
        self.assertEqual(self.server.sql("SELECT COUNT(*) FROM cull_decisions")[0][0], 0)

    def test_reject_then_an_arrow_at_once_rejects_the_card_shown(self):
        self.open_day()
        self.page.keyboard.press("x")
        self.page.keyboard.press("ArrowRight", delay=0)
        self.wait_toast("Rejected DSC05036")
        self.assertEqual(self.cursor(), 2)
        self.drain()
        flags = self.flags()
        self.assertEqual(flags[0], ["reject"])
        self.assertTrue(all(f is None for f in flags[1]), flags[1])


if __name__ == "__main__":
    unittest.main()
