"""Day flows that ui_smoke.py (headless Firefox, retired) used to check, on the desktop app: what
Lightroom already did, brackets and the budget, the day grid, Send from the review, Start over,
Practice in detail, and the keys sheet, focus zoom and Enter on a focused button."""
import unittest

from webharness import DAY, BrowserCase

OTHER = "2019/2019-08-13"
# what the plug-in would report from a sync: two stacks picked by hand in Lightroom, one rated
CATALOG = ("2026-10-01\tDSC05062.ARW\t1\t0\tyou\t", "2026-10-01\tDSC05066.ARW\t1\t3\tyou\tyou",
           "2026-10-01\tDSC05063.ARW\t0\t4\t\tyou")


class Lightroom(BrowserCase):
    def test_stacks_done_in_lightroom_are_skipped_and_counted(self):
        self.server.lightroom(*CATALOG)
        self.open_day()
        self.assertIn("13 stacks to go", self.text(".top .t"))
        self.assertEqual(self.text("#budget"), "Kept 3 of 5")
        self.assertIn("st-keep", self.page.get_attribute('.film-thumb[data-stack="10"]', "class"))
        self.page.click('.film-thumb[data-stack="10"]')
        self.assertIn("Picked in Lightroom", self.text(".detail-rail .stline"))

    def test_brackets_and_the_budget(self):
        self.server.lightroom(*CATALOG)
        self.open_day()
        self.key("p")                                   # stack 0 kept: 4 of 5
        self.wait_toast("Kept DSC05036")
        self.page.click('.film-thumb[data-stack="2"]')
        self.assertTrue(self.page.query_selector(".detail-rail .pb-all.sugg"), "a bracket suggests Keep all")
        self.assertIn("Looks like a bracket", self.text(".detail-rail .badges"))
        self.key("a")
        self.wait_toast("Kept all 3 · bracket")
        self.assertEqual(self.text("#budget"), "Kept 5 of 5")
        self.key("a")                                   # stack 3, the sixth keep
        self.wait_toast("1 over this shoot’s 5")
        self.assertEqual(self.text("#budget"), "Kept 6 · 1 over 5")
        self.assertIn("over", self.page.get_attribute("#budget", "class"))


class Grid(BrowserCase):
    def test_the_day_grid(self):
        self.open_day()
        self.key("x")                                   # stack 0 rejected
        self.wait_toast("Rejected")
        self.key("a")                                   # stack 1, a burst: all kept
        self.wait_toast("Kept all 3")
        self.key("g")
        self.wait_screen("grid")
        self.assertEqual(self.page.eval_on_selector_all(".gv-t", "t => t.length"), 32)
        self.assertIn("3 picked · 1 rejected", self.text(".top .t"))
        self.assertIn("grayscale", self.page.eval_on_selector(".gv-t.m-reject img", "i => getComputedStyle(i).filter"))
        self.page.click('[data-act=grid-filter][data-f="picks"]')
        self.assertEqual(self.page.eval_on_selector_all(".gv-t", "t => t.every(x => x.classList.contains('m-pick'))"), True)
        self.assertEqual(self.page.eval_on_selector_all(".gv-t", "t => t.length"), 3)
        self.page.click('[data-act=grid-filter][data-f="all"]')
        self.page.click('.gv-t[data-stack="0"]')
        self.wait_screen("cull")
        self.assertEqual(self.cursor(), 0)
        self.assertIn("st-reject", self.page.get_attribute(".card", "class"))
        self.assertTrue(self.page.query_selector(".detail-rail .pb-rej.on"), "the button that decided shows pressed")


class SendAndStartOver(BrowserCase):
    def test_send_from_the_review(self):
        self.server.reject_all(DAY, stacks=15, finish=False)
        self.open_day()
        self.key("x")
        self.wait_screen("summary")
        self.drain()
        self.assertEqual(self.text("[data-act=send]"), "Send 32 to Lightroom")
        self.page.click("[data-act=send]")
        self.wait_toast("Queued 32 for Lightroom. On the Mac: Sync AI Cull Data.")
        rows = (self.server.inbox / "cull-decisions.tsv").read_text().splitlines()
        self.assertEqual(rows[0], "#cull-decisions v1")
        self.assertGreaterEqual(len(rows) - 1, 32)
        self.assertTrue(self.page.is_disabled("[data-act=send]"))
        self.assertEqual(self.text("[data-act=send]"), "Waiting for Lightroom")

    def test_start_over_is_refused_once_a_decision_is_in_lightroom(self):
        self.server.reject_all(DAY, stacks=1, finish=False)
        self.assertEqual(self.server.write("POST", f"/m/api/day/{DAY}/send", {})[0], 200)
        self.server.receipt("2026-10-01\tDSC05036.ARW\tapplied\t")
        self.open_day()
        self.key("g")
        self.wait_screen("grid")
        self.page.click(".link[data-act=reset-ask]")
        self.page.wait_for_selector("#sheet:not([hidden])")
        self.assertIn("Already in Lightroom", self.text("#sheet"))
        self.assertFalse(self.page.query_selector("[data-act=reset-do]"))

    def test_start_over_clears_the_day(self):
        self.server.reject_all(OTHER, stacks=2, finish=False)
        self.open_day(OTHER)
        self.key("ArrowRight")                          # a position save
        self.page.wait_for_timeout(700)
        self.drain()
        self.key("g")
        self.wait_screen("grid")
        self.page.click(".link[data-act=reset-ask]")
        self.page.click("[data-act=reset-do]")
        self.wait_toast("Started over: cleared 2")
        self.page.wait_for_timeout(1000)                # a stale position save would land in this window
        self.assertEqual(self.server.sql("SELECT COUNT(*) FROM cull_decisions WHERE day=?", OTHER)[0][0], 0)
        self.assertEqual(self.server.sql("SELECT COUNT(*) FROM cull_days WHERE day=?", OTHER)[0][0], 0)
        self.assertEqual(self.cursor(), 0)
        self.assertTrue(self.page.is_disabled(".detail-rail [data-act=undo]"), "Undo went with the taps")


class PracticeInDetail(BrowserCase):
    def test_a_challenge_is_done_with_a_note(self):
        page = self.page
        self.open("/m/practice.html#web-lantern")
        page.wait_for_selector(".p-download")
        page.click(".p-hints summary")
        self.assertTrue(page.eval_on_selector(".p-hints", "d => d.open"))
        page.fill("#practice-note", "Warm light worked.")
        page.click("[data-action=done]")
        page.wait_for_selector(".p-done")
        self.assertEqual(self.server.sql("SELECT status, note FROM practice_state WHERE id='web-lantern'"),
                         [("done", "Warm light worked.")])

    def test_needs_desktop_and_its_companion(self):
        page = self.page
        self.open("/m/practice.html")
        page.wait_for_selector(".challenge-group .companion-row")
        self.assertIn("On the go", self.text(".challenge-group"))
        self.assertEqual(page.eval_on_selector_all(".challenge-card .p-tag-desktop", "t => t.length"), 1)
        page.click(".challenge-group .challenge-card")
        page.wait_for_selector(".p-desktop-box")
        self.assertFalse(page.query_selector(".p-download"))
        box = self.text(".p-desktop-box")
        self.assertIn("Do this one on the Mac in Lightroom Classic", box)
        self.assertIn(DAY, box)
        self.assertIn("Enhance › Denoise", self.text(".p-kind"))
        page.click(".p-companion-link")
        page.wait_for_selector(".p-download")
        self.assertEqual(page.get_attribute(".p-kind .p-pair-link", "href"), "#web-aurora")


class DesktopDetails(BrowserCase):
    def test_keys_sheet_focus_zoom_and_enter_on_a_button(self):
        page = self.page
        self.open_day()
        self.key("?")
        page.wait_for_selector(".key-sheet")
        self.assertIn("Keyboard shortcuts", self.text(".key-sheet"))
        self.key("Escape")
        page.wait_for_selector("#sheet", state="hidden")
        self.key("z")
        self.wait_screen("focus")
        page.wait_for_function("document.querySelector('#fz img').naturalWidth > 0")
        box = page.query_selector("#fz").bounding_box()
        page.mouse.move(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
        page.mouse.wheel(0, -300)
        self.assertFalse(page.eval_on_selector("#fz img", "i => i.style.transform.endsWith('scale(1)')"), "the wheel zooms")
        self.key("Escape")
        self.wait_screen("cull")
        page.focus(".top [data-act=grid]")              # Enter activates only the focused button
        self.key("Enter")
        self.wait_screen("grid")
        self.assertEqual(self.queued(), [])
        last = 15
        self.key("Escape")
        self.wait_screen("cull")
        page.click(f'.film-thumb[data-stack="{last}"]')
        self.assertTrue(page.evaluate("""() => { const s = document.querySelector('.day-filmstrip').getBoundingClientRect(),
            c = document.querySelector('.film-thumb.cur').getBoundingClientRect(); return c.left >= s.left && c.right <= s.right; }"""),
            "the current thumbnail stays in view")


if __name__ == "__main__":
    unittest.main()
