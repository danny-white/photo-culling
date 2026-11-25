"""The web app is for a computer: phones and tablets get a page pointing to the iPhone app, and
there is no service worker or web app manifest any more."""
import unittest
import urllib.error
import urllib.request

from webharness import BASE, DAY, BrowserCase

PAGES = ("/m/", "/m/gallery.html", "/m/practice.html")


class PhoneGetsTheAppPage(BrowserCase):
    device = "iPhone 15"

    def check_pages(self):
        api = []
        self.page.on("request", lambda r: "/m/api/" in r.url and api.append(r.url))
        for path in PAGES:
            with self.subTest(path=path):
                self.open(path)
                self.page.wait_for_selector(".cb-phone")
                self.assertIn("Culling Bay is the app", self.text(".cb-phone h1"))
                self.assertFalse(self.page.evaluate("document.documentElement.classList.contains('wide')"))
                self.assertFalse(self.page.is_visible("#app, header.bar, header.practice-head"))
                self.assertEqual(self.page.get_attribute(".cb-get", "href"), "/m/ios/")
                self.assertIsNone(self.page.evaluate("window.cbPerf"), "nothing is measured on the phone")
        self.assertEqual(api, [], "the app itself never starts on a phone")
        # The link works: /m/ios/ is a server page, untouched by the app's scripts.
        self.page.click(".cb-get")
        self.page.wait_for_url(BASE + "/m/ios/")
        self.assertIn("Culling Bay builds", self.page.text_content("h1"))
        self.assertFalse(self.page.query_selector(".cb-phone"))

    def test_phone_pages(self):
        self.check_pages()


class TabletGetsTheAppPage(PhoneGetsTheAppPage):
    device = "iPad Pro 11"


class DesktopGetsTheApp(BrowserCase):
    def check_width(self, width):
        self.page.set_viewport_size({"width": width, "height": 900})
        self.open("/m/")
        self.page.wait_for_selector(".day")
        self.assertTrue(self.page.evaluate("document.documentElement.classList.contains('wide')"))
        self.assertFalse(self.page.query_selector(".cb-phone"))
        self.open_day()
        self.page.wait_for_selector(".detail-rail .bar [data-act=reject]")
        self.assertTrue(self.page.is_visible(".day-filmstrip"))
        overflow = self.page.evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        self.assertEqual(overflow, 0, "no sideways scroll at %d px" % width)
        self.open("/m/gallery.html#/day/" + DAY)
        self.page.wait_for_selector(".tile")
        self.open("/m/practice.html")
        self.page.wait_for_selector(".challenge-card")

    def test_1000(self):
        self.check_width(1000)

    def test_1280(self):
        self.check_width(1280)

    def test_2560(self):
        self.check_width(2560)

    def test_narrow_window_scrolls_sideways(self):
        """Under the layout's 900 px it keeps the desktop layout and scrolls, never a phone layout."""
        self.page.set_viewport_size({"width": 760, "height": 800})
        self.open_day()
        self.page.wait_for_selector(".detail-rail")
        sizes = self.page.evaluate("[document.documentElement.scrollWidth, document.documentElement.clientWidth,"
                                   " document.querySelector('#app').getBoundingClientRect().width]")
        self.assertEqual(sizes[2], 900)
        self.assertGreater(sizes[0], sizes[1])


class NoServiceWorker(BrowserCase):
    def test_nothing_registers(self):
        self.open("/m/")
        self.page.wait_for_selector(".day")
        self.page.wait_for_timeout(300)
        self.assertTrue(self.page.evaluate("window.isSecureContext"), "127.0.0.1 is where one could register")
        self.assertEqual(self.page.evaluate("navigator.serviceWorker.getRegistrations().then(r => r.length)"), 0)
        self.assertIsNone(self.page.query_selector("link[rel=manifest]"))
        for gone in ("sw.js", "manifest.webmanifest", "wide.js"):
            with self.assertRaises(urllib.error.HTTPError) as e:
                urllib.request.urlopen(BASE + "/m/" + gone, timeout=10)
            e.exception.close()
            self.assertEqual(e.exception.code, 404, gone)

    def test_an_old_registration_is_removed(self):
        """A browser that registered the old service worker on localhost loses it, and its cache."""
        self.context.route("**/m/sw.js", lambda route: route.fulfill(
            status=200, body="self.addEventListener('fetch', () => {});", headers={"Content-Type": "text/javascript"}))
        self.open("/m/")
        self.page.wait_for_selector(".day")
        self.page.evaluate("navigator.serviceWorker.register('/m/sw.js').then(r => r.update && null)")
        self.page.evaluate("caches.open('cbm-shell-v5').then(c => c.put('/m/x', new Response('x')))")
        self.page.wait_for_function("navigator.serviceWorker.getRegistrations().then(r => r.length === 1)")
        self.context.unroute("**/m/sw.js")
        self.page.reload()
        self.page.wait_for_selector(".day")
        self.page.wait_for_function("navigator.serviceWorker.getRegistrations().then(r => r.length === 0)")
        self.page.wait_for_function("caches.keys().then(k => !k.includes('cbm-shell-v5'))")


if __name__ == "__main__":
    unittest.main()
