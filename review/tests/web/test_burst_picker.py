"""The burst picker works like the iPhone's (CullPickerModel): a filmstrip for every burst, opening
on the sharpest frame with nothing ticked; what is ticked is kept and the rest rejected with the
burst note; and the 1:1 focus check's Keep on a burst opens the picker (card B3, web half)."""
import unittest

from webharness import BrowserCase

# 8 stacks: [1, 1, 2, 1, 1, 1, 10, 10] frames; the 2-frame burst's lead is its 2nd frame, the first
# 10-frame burst's its 7th. Leads not first in shooting order prove the picker opens on the lead.
BURSTS = "2019/2019-08-13"
TWO, TEN = 2, 6


class BurstPicker(BrowserCase):
    def setUp(self):
        super().setUp()
        self.day = self.server.get("/m/api/day/" + BURSTS)
        self.assertEqual([len(s["frames"]) for s in self.day["stacks"]][TWO], 2)
        self.assertEqual([len(s["frames"]) for s in self.day["stacks"]][TEN], 10)

    def lead_index(self, stack):
        s = self.day["stacks"][stack]
        return [f["id"] for f in s["frames"]].index(s["lead"])

    def go_to(self, stack):
        self.open_day(BURSTS)
        self.page.click(f'.film-thumb[data-stack="{stack}"]')
        self.assertEqual(self.cursor(), stack)

    def picker_state(self):
        return self.page.evaluate("""() => ({
            cur: +document.querySelector('.pk-th.cur').dataset.i,
            ticked: document.querySelectorAll('.pk-th b').length,
            tick: document.querySelector('.pk-tick').classList.contains('on'),
            keep: document.querySelector('[data-act=pk-keep]').textContent,
            disabled: document.querySelector('[data-act=pk-keep]').disabled,
            strip: document.querySelectorAll('.pk-th').length,
            grid: !!document.querySelector('.ko, .ko-t'),
        })""")

    def test_two_and_ten_frame_bursts_open_as_a_strip_on_the_lead(self):
        for stack, n in ((TWO, 2), (TEN, 10)):
            for how in ("choose", "p", "Enter"):
                with self.subTest(stack=stack, how=how):
                    self.go_to(stack)
                    if how == "choose":
                        self.page.click(".detail-rail [data-act=choose]")
                    else:
                        self.key(how)
                    self.wait_screen("picker")
                    st = self.picker_state()
                    self.assertEqual(st["strip"], n)
                    self.assertFalse(st["grid"])
                    self.assertEqual(st["cur"], self.lead_index(stack), "opens on the sharpest frame")
                    self.assertEqual((st["ticked"], st["tick"]), (0, False), "nothing ticked")
                    self.assertEqual(st["keep"], "Tick a keeper")
                    self.assertTrue(st["disabled"])
                    self.assertIn("Sharpest", self.text(".detail-rail .pk-bd"))

    def test_enter_enter_does_nothing(self):
        self.go_to(TEN)
        self.key("Enter")
        self.wait_screen("picker")
        self.key("Enter")
        self.page.wait_for_timeout(300)
        self.assertEqual(self.screen(), "picker")
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.flags(BURSTS)[TEN], [None] * 10)

    def test_tick_two_and_save(self):
        self.go_to(TEN)
        self.key("p")
        self.wait_screen("picker")
        lead = self.lead_index(TEN)
        self.key("p")                                   # tick the lead
        self.key("ArrowRight")
        self.page.click(".detail-rail .pk-tick")        # and the next frame, with the mouse
        st = self.picker_state()
        self.assertEqual((st["cur"], st["ticked"], st["keep"]), (lead + 1, 2, "Keep 2 · reject 8"))
        self.key("ArrowLeft")
        self.key("4")                                   # stars on a ticked frame
        self.page.click("[data-act=pk-keep]")
        self.wait_toast("Kept 2 frames · 8 rejected with a note")
        self.wait_screen("cull")
        self.drain()
        frames = self.server.get("/m/api/day/" + BURSTS)["stacks"][TEN]["frames"]
        kept = [f for f in frames if f["decision"]["flag"] == "pick"]
        self.assertEqual([f["id"] for f in kept], [frames[lead]["id"], frames[lead + 1]["id"]])
        self.assertEqual([f["decision"]["stars"] for f in kept], [4, None])
        note = "Burst reject · kept " + ", ".join(f["file"].rsplit(".", 1)[0] for f in kept)
        rejects = [f for f in frames if f["decision"]["flag"] == "reject"]
        self.assertEqual(len(rejects), 8)
        self.assertEqual({f["decision"]["note"] for f in rejects}, {note})
        # back on the decided burst, the picker starts with those two ticked, and the stars
        self.key("ArrowLeft")
        self.assertEqual(self.cursor(), TEN)
        self.key("b")
        self.wait_screen("picker")
        st = self.picker_state()
        self.assertEqual((st["cur"], st["ticked"], st["tick"]), (lead, 2, True))
        self.assertEqual(self.page.eval_on_selector_all(".detail-rail .stars .on", "e => e.length"), 4)

    def test_focus_keep_on_a_burst_opens_the_picker(self):
        self.go_to(TEN)
        self.page.click(".card .photo")                 # the 1:1 focus check on the frame shown
        self.wait_screen("focus")
        self.assertEqual(self.text(".foot [data-act=reject]"), "Reject all 10")
        self.page.click(".foot [data-act=keep]")         # the button, not only the key
        self.wait_screen("picker")
        st = self.picker_state()
        self.assertEqual((st["cur"], st["ticked"]), (self.lead_index(TEN), 0))
        self.assertEqual(self.queued(), [])
        self.key("Escape")
        self.wait_screen("cull")
        self.key("z")                                   # the key does the same
        self.wait_screen("focus")
        self.key("p")
        self.wait_screen("picker")
        self.assertEqual(self.flags(BURSTS)[TEN], [None] * 10, "nothing decided")

    def test_focus_reject_on_a_burst_rejects_all(self):
        self.go_to(TWO)
        self.key("z")
        self.wait_screen("focus")
        self.assertEqual(self.text(".foot [data-act=reject]"), "Reject all 2")
        self.page.click(".foot [data-act=reject]")
        self.wait_toast("Rejected all 2")
        self.drain()
        self.assertEqual(self.flags(BURSTS)[TWO], ["reject", "reject"])

    def test_focus_keep_on_a_single_keeps_it(self):
        self.go_to(0)
        self.key("z")
        self.wait_screen("focus")
        self.assertEqual(self.text(".foot [data-act=reject]"), "Reject")
        self.page.click(".foot [data-act=keep]")
        self.wait_toast("Kept ")
        self.drain()
        self.assertEqual(self.flags(BURSTS)[0], ["pick"])


if __name__ == "__main__":
    unittest.main()
