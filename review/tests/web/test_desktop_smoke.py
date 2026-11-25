"""A desktop pass through the app with keys and the mouse, the gallery and Practice, at 1280 px.
Any console error or uncaught exception fails the test (BrowserCase)."""
import unittest
from pathlib import Path

from webharness import DAY, BrowserCase


class CullADay(BrowserCase):
    def test_keys_and_mouse(self):
        page = self.page
        self.open("/m/")
        page.click(f'.day[data-day="{DAY}"]')
        self.wait_screen("cull")
        self.assertEqual(self.cursor(), 0)
        self.assertIn("DSC05036.ARW", self.text(".detail-rail .sh-id"))
        self.assertFalse(page.query_selector(".strip, .chip, .stamp, .ov, .fname, [data-act=info]"),
                         "no phone controls on the card")

        self.key("x")                                   # reject the single, and move on
        self.wait_toast("Rejected DSC05036")
        self.assertEqual(self.cursor(), 1)
        page.click(".detail-rail [data-act=undo]")      # Undo with the mouse
        self.wait_toast("Undone: Rejected DSC05036")
        self.assertEqual(self.cursor(), 0)
        self.key("3")                                   # keep with three stars
        self.wait_toast("Kept DSC05036 ★★★")

        # a mouse drag on the photo decides nothing and opens nothing
        box = page.query_selector(".card .photo").bounding_box()
        x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
        page.mouse.move(x, y)
        page.mouse.down()
        page.mouse.move(x, y + 160, steps=8)
        page.mouse.up()
        self.assertEqual(self.screen(), "cull")
        self.assertEqual(self.cursor(), 1)

        # a burst: P opens the picker; tick the second frame and save with Enter
        self.key("p")
        self.wait_screen("picker")
        self.assertTrue(page.is_visible(".detail-rail .pk-tick"))
        self.key("ArrowRight")
        self.key("p")
        self.key("Enter")
        self.wait_toast("rejected with a note")
        self.assertEqual(self.cursor(), 2)

        # a click on the photo opens the 1:1 focus check; Esc goes back
        page.click(".card .photo")
        self.wait_screen("focus")
        self.key("Escape")
        self.wait_screen("cull")
        page.click(".detail-rail .bar [data-act=reject]")   # Reject with the mouse...
        self.wait_toast("Rejected")
        self.key("Control+z")                               # ...and Ctrl+Z takes it back
        self.wait_toast("Undone")
        self.assertEqual(self.cursor(), 2)

        self.key("g")                                   # the day grid and back
        self.wait_screen("grid")
        self.key("Escape")
        self.wait_screen("cull")

        last = len(self.server.get("/m/api/day/" + DAY)["stacks"]) - 1
        page.click(f'.film-thumb[data-stack="{last}"]')
        self.assertEqual(self.cursor(), last)
        self.key("ArrowRight")                          # on past the last stack: the review
        self.wait_screen("summary")
        self.assertIn("Kept", self.text(".counts"))
        page.click(".foot [data-act=days]")             # back to Days
        self.wait_screen("days")
        page.wait_for_selector(f'.day[data-day="{DAY}"]')

        self.drain()
        flags = self.flags()
        self.assertEqual(flags[0], ["pick"])
        self.assertEqual(sorted(flags[1]), ["pick", "reject", "reject"])
        self.assertTrue(all(f is None for f in flags[2]), flags[2])
        d = self.server.get("/m/api/day/" + DAY)
        self.assertEqual(d["stacks"][0]["frames"][0]["decision"]["stars"], 3)
        kept = next(f for f in d["stacks"][1]["frames"] if f["decision"]["flag"] == "pick")
        notes = {f["decision"]["note"] for f in d["stacks"][1]["frames"] if f["decision"]["flag"] == "reject"}
        self.assertEqual(notes, {"Burst reject · kept " + kept["file"].rsplit(".", 1)[0]})


class GalleryAndPractice(BrowserCase):
    def test_gallery_search_and_viewer(self):
        page = self.page
        self.open("/m/gallery.html")
        page.wait_for_selector(".yhead")
        page.fill("#q", "2026-10-01")
        page.press("#q", "Enter")
        page.wait_for_selector(".tile")
        self.assertIn("2026-10-01", page.url.replace("%2D", "-"))
        page.click(".tile")
        page.wait_for_selector("#viewer:not([hidden]) .gallery-details")
        self.assertEqual(page.get_attribute(".vbottom", "aria-label"), "Photo details")
        self.assertIn("File", self.text(".gallery-details"))
        first = self.text("#v-count")
        self.key("ArrowRight")
        page.wait_for_function("c => document.querySelector('#v-count').textContent !== c", arg=first)
        page.click("#v-save")
        page.wait_for_selector("#sheet:not([hidden])")
        self.assertIn("Download JPEG", self.text("#sheet"))
        self.assertNotIn("Press and hold", self.text("#sheet"))
        self.key("Escape")                              # the sheet, then the viewer
        self.key("Escape")
        page.wait_for_selector("#viewer", state="hidden")

    def test_practice_lists_challenges(self):
        page = self.page
        self.open("/m/practice.html")
        page.wait_for_selector(".challenge-card")
        self.assertIn("Web challenge", self.text(".practice-list"))
        self.assertEqual(self.text(".challenge-group .p-tag-desktop"), "Needs Desktop")
        width = page.evaluate("document.querySelector('#practice').getBoundingClientRect().width")
        self.assertLessEqual(width, 1000)
        page.click('.challenge-card[href="#web-lantern"]')
        page.wait_for_selector(".p-download")
        self.assertIn("Downloads folder", self.text(".p-howto"))
        self.assertNotIn("Safari", self.text(".practice-detail"))
        self.assertTrue(page.get_attribute(".p-download", "href").endswith("?s=original"))


@unittest.skipUnless(Path("/mnt/passport/Pictures").is_dir(), "needs the NAS for the real pictures")
class RealPictures(BrowserCase):
    real_pictures = True

    def test_a_card_shows_the_real_photo(self):
        self.open_day()
        self.page.wait_for_function("[...document.querySelectorAll('.card img, .day-filmstrip img')].slice(0, 4)"
                                    ".every(i => i.complete && i.naturalWidth > 0)", timeout=60000)
        self.assertGreater(self.page.eval_on_selector(".card img", "i => i.naturalWidth"), 600)


if __name__ == "__main__":
    unittest.main()
