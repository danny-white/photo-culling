"""Taps the PC refuses or hasn't seen yet are never lost (the iPhone's CullWriteQueue and
CullSessionModel.queueDropped / layQueued). Refusals and dropped connections come from Playwright
route interception; everything else reaches the test server."""
import json
import unittest

from webharness import DAY, BrowserCase

REFUSED_UNDO = {"error": "1 decision(s) from this action are already in Lightroom; change those there", "applied": 1}


def answer(status, body):
    return lambda route: route.fulfill(status=status, content_type="application/json", body=json.dumps(body))


class QueueCase(BrowserCase):
    def setUp(self):
        super().setUp()
        self.expect_errors()      # refused and dropped requests log "Failed to load resource"

    def net(self, page=None):
        return self.text("#net", page).strip()

    def wait_net(self, part, page=None, timeout=15000):
        (page or self.page).wait_for_function(
            "t => (document.querySelector('#net') || {}).textContent?.includes(t)", arg=part, timeout=timeout)

    def film(self, stack, page=None):
        return (page or self.page).get_attribute(f'.film-thumb[data-stack="{stack}"]', "class")

    def kinds(self, page=None):
        return [it["kind"] for it in self.queued(page)]


class UndoRefused(QueueCase):
    def test_a_refused_undo_puts_the_decision_and_undo_back(self):
        self.open_day()
        self.key("x")
        self.wait_toast("Rejected DSC05036")
        self.drain()
        self.page.route("**/m/api/undo", answer(409, REFUSED_UNDO))
        self.key("Control+z")
        self.wait_toast("Not undone: 1 decision(s) from this action are already in Lightroom")
        self.assertIn("st-reject", self.page.get_attribute(".card", "class"))
        self.assertIn("st-reject", self.film(0))
        self.assertFalse(self.page.is_disabled(".detail-rail [data-act=undo]"), "the tap is back in Undo")
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.flags()[0], ["reject"])
        self.page.unroute("**/m/api/undo")
        self.key("Control+z")                           # and Undo works once the PC allows it
        self.wait_toast("Undone: Rejected DSC05036")
        self.drain()
        self.assertEqual(self.flags()[0], [None])


class Offline(QueueCase):
    def test_reload_with_taps_queued_lays_them_over_the_day(self):
        self.page.route("**/m/api/decide", lambda route: route.abort())
        self.open_day()
        self.key("x")                                   # stack 0
        self.wait_toast("Rejected DSC05036")
        self.key("x")                                   # stack 1, a burst of 3
        self.wait_toast("Rejected all 3")
        self.wait_net("Offline · 2 waiting to save")
        self.assertNotIn("PC refused", self.net())
        self.page.wait_for_timeout(700)                 # the position save joins the queue
        self.assertEqual(self.kinds().count("decide"), 2)
        self.page.reload()
        self.page.wait_for_selector(".detail-rail")
        self.assertIn("st-reject", self.film(0))
        self.assertIn("st-reject", self.film(1))
        self.assertEqual(self.cursor(), 2, "on the first stack still open")
        self.assertIn("14 stacks to go", self.text(".top .t"))
        self.page.unroute("**/m/api/decide")
        self.page.evaluate("dispatchEvent(new Event('online'))")
        self.drain()
        flags = self.flags()
        self.assertEqual((flags[0], flags[1]), (["reject"], ["reject"] * 3))
        self.assertEqual(self.cursor(), 2)
        self.assertIn("st-reject", self.film(1))
        self.page.wait_for_selector("#net", state="hidden")

    def test_undo_while_offline_takes_back_its_decide_on_reload(self):
        self.page.route("**/m/api/{decide,undo}", lambda route: route.abort())
        self.open_day()
        self.key("x")
        self.wait_toast("Rejected DSC05036")
        self.key("x")
        self.wait_toast("Rejected all 3")
        self.key("Control+z")                           # takes back stack 1
        self.wait_toast("Undone")
        self.page.reload()
        self.page.wait_for_selector(".detail-rail")
        self.assertIn("st-reject", self.film(0))
        self.assertNotIn("st-", self.film(1))
        self.assertEqual(self.cursor(), 1)

    def test_only_the_newest_position_waits(self):
        self.page.route("**/m/api/{decide,progress}", lambda route: route.abort())
        self.open_day()
        self.key("x")
        self.wait_toast("Rejected")
        for _ in range(3):                              # three moves, each saved after 600 ms
            self.key("ArrowRight")
            self.page.wait_for_timeout(750)
        items = self.queued()
        self.assertEqual([it["kind"] for it in items], ["decide", "progress"])
        self.assertEqual(items[1]["body"]["cursor"], 4)
        self.wait_net("Offline · 1 waiting to save")

    def test_a_pc_that_does_not_answer_is_offline_after_15_s(self):
        self.page.clock.install()
        self.page.route("**/m/api/decide", lambda route: None)   # never answers
        self.open_day()
        self.key("x")
        self.wait_toast("Rejected")
        self.page.clock.run_for(5000)
        self.assertEqual(self.net(), "", "still waiting for an answer")
        self.page.clock.run_for(11000)
        self.wait_net("Offline · 1 waiting to save")


class Refused(QueueCase):
    def test_a_refused_decide_goes_back_and_stays_reported(self):
        self.page.route("**/m/api/decide", answer(400, {"error": "unknown frame id 123"}))
        self.open_day()
        self.key("x")
        self.wait_net("1 tap not saved: unknown frame id 123")
        self.assertNotIn("st-reject", self.film(0), "the card is back to undecided")
        self.assertTrue(self.page.is_disabled(".detail-rail [data-act=undo]"))
        self.assertEqual(self.queued(), [])
        self.key("x")                                   # stack 1: refused too
        self.wait_net("2 taps not saved")
        self.page.click('.film-thumb[data-stack="0"]')
        self.assertIn("2 taps not saved", self.net(), "it stays up across screens")
        self.page.reload()
        self.page.wait_for_selector(".detail-rail")
        self.assertIn("2 taps not saved", self.net(), "and a reload")
        self.page.click("#net [data-act=lost-ok]")
        self.page.wait_for_selector("#net", state="hidden")
        self.assertEqual(self.flags()[0], [None])

    def test_503_with_a_reason_is_pc_refused_and_retried(self):
        reason = "/mnt/Passport_AICullInbox is not mounted; nothing was changed"
        self.page.route("**/m/api/decide", answer(503, {"error": reason}))
        self.open_day()
        self.key("x")
        self.wait_net("PC refused: " + reason + " · 1 waiting to save")
        self.assertNotIn("Offline", self.net())
        self.assertIn("st-reject", self.film(0), "the tap is kept while it is retried")
        self.page.unroute("**/m/api/decide")
        self.drain(timeout=10000)                       # the next try, within 4 s
        self.page.wait_for_selector("#net", state="hidden")
        self.assertEqual(self.flags()[0], ["reject"])


class TwoTabs(QueueCase):
    no_locks = False

    def setUp(self):
        super().setUp()
        if self.no_locks:     # plain http, as on the live server: no navigator.locks, so the lease key
            self.context.add_init_script("Object.defineProperty(Navigator.prototype, 'locks', {get: () => undefined})")
            self.page.close()
            self.page = self.new_page()

    def test_tabs_keep_each_others_taps(self):
        self.context.route("**/m/api/{decide,progress}", lambda route: route.abort())
        a = self.open_day("2019/2019-08-13")                     # tab A, on another day
        b = self.open_day(DAY, self.new_page())                  # tab B
        self.assertEqual(a.evaluate("!!navigator.locks"), not self.no_locks)
        self.key("x", b)                                          # B taps while the PC is away
        self.wait_toast("Rejected DSC05036", b)
        self.key("ArrowRight", a)                                 # A moves: a position save
        a.wait_for_timeout(800)
        kinds = [(it["kind"], it.get("day")) for it in self.queued(a)]
        self.assertIn(("decide", DAY), kinds, "A did not wipe B's tap")
        self.assertIn(("progress", "2019/2019-08-13"), kinds)
        self.key("x", a)                                          # A taps too
        self.wait_toast("Rejected", a)
        self.key("x", b)
        self.wait_toast("Rejected all 3", b)
        self.assertEqual([k for k, _ in [(it["kind"], 0) for it in self.queued(b)]].count("decide"), 3)
        b.reload()                                                # B reloads: its taps are still there
        b.wait_for_selector(".detail-rail")
        self.assertIn("st-reject", self.film(1, b))
        self.context.unroute("**/m/api/{decide,progress}")
        for p in (a, b):
            p.evaluate("dispatchEvent(new Event('online'))")
        self.drain(a)
        self.drain(b)
        flags = self.flags()
        self.assertEqual((flags[0], flags[1]), (["reject"], ["reject"] * 3))
        self.assertEqual(self.flags("2019/2019-08-13")[1], ["reject"])
        sent = self.server.sql("SELECT COUNT(*) FROM cull_actions")[0][0]
        self.assertEqual(sent, 3, "each tap reached the PC once")


class TwoTabsWithoutLocks(TwoTabs):
    no_locks = True


if __name__ == "__main__":
    unittest.main()
