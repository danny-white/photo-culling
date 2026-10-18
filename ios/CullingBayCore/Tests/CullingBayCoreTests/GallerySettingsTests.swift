import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Gallery settings")
struct GallerySettingsTests {
    @Test func inMemoryStartsWithTheDefaults() {
        let settings = InMemoryGallerySettings()
        #expect(settings.best == false)
        #expect(settings.bursts == true)
        #expect(settings.openYears.isEmpty && settings.openMonths.isEmpty)
        #expect(settings.hasOpenState == false)
        #expect(settings.serverURL == URL(string: "http://100.82.57.4:8000"))
    }

    @Test func settingOpenYearsOrMonthsMakesOpenStateExist() {
        let years = InMemoryGallerySettings()
        years.openYears = ["2026"]
        #expect(years.hasOpenState)
        let months = InMemoryGallerySettings()
        months.openMonths = []
        #expect(months.hasOpenState)
        #expect(InMemoryGallerySettings(openYears: ["2025"]).hasOpenState)
    }

    /// A UserDefaults suite that is removed when the test is done.
    private func withSuite(_ body: (UserDefaults, String) -> Void) {
        let name = "CullingBayCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults, name)
    }

    @Test func userDefaultsStartsWithTheDefaults() {
        withSuite { defaults, _ in
            let settings = UserDefaultsGallerySettings(defaults: defaults)
            #expect(settings.best == false)
            #expect(settings.bursts == true)
            #expect(settings.hasOpenState == false)
            #expect(settings.openYears.isEmpty)
            #expect(settings.serverURL == GalleryDefaults.serverURL)
        }
    }

    @Test func userDefaultsKeepsValuesUnderTheDocumentedKeys() {
        withSuite { defaults, _ in
            let settings = UserDefaultsGallerySettings(defaults: defaults)
            settings.best = true
            settings.bursts = false
            settings.serverURL = URL(string: "http://example.test:9000")!
            settings.openYears = ["2026", "2025"]
            settings.openMonths = ["2026-10"]
            #expect(defaults.bool(forKey: "gallery.best"))
            #expect(defaults.object(forKey: "gallery.bursts") as? Bool == false)
            #expect(defaults.string(forKey: "server.url") == "http://example.test:9000")
            #expect(defaults.data(forKey: "gallery.open") != nil)

            let again = UserDefaultsGallerySettings(defaults: defaults)
            #expect(again.best && !again.bursts)
            #expect(again.serverURL.absoluteString == "http://example.test:9000")
            #expect(again.hasOpenState)
            #expect(again.openYears == ["2026", "2025"])
            #expect(again.openMonths == ["2026-10"])
        }
    }

    @Test func settingYearsKeepsTheMonthsAndTheWebFormat() throws {
        withSuite { defaults, _ in
            let settings = UserDefaultsGallerySettings(defaults: defaults)
            settings.openMonths = ["2026-10"]
            settings.openYears = ["2026"]
            #expect(settings.openMonths == ["2026-10"])
            let data = defaults.data(forKey: "gallery.open") ?? Data()
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
            #expect(object == ["years": ["2026"], "months": ["2026-10"]])
        }
    }

    @Test func aBadSavedValueFallsBackToTheDefault() {
        withSuite { defaults, _ in
            defaults.set(Data("not json".utf8), forKey: "gallery.open")
            defaults.set("", forKey: "server.url")
            let settings = UserDefaultsGallerySettings(defaults: defaults)
            #expect(settings.hasOpenState == false)
            #expect(settings.serverURL == GalleryDefaults.serverURL)
        }
    }

    @Test func theSuiteIsGoneAfterwards() {
        var name = ""
        withSuite { defaults, suite in
            name = suite
            UserDefaultsGallerySettings(defaults: defaults).best = true
        }
        let reopened = UserDefaults(suiteName: name)!
        defer { reopened.removePersistentDomain(forName: name) }
        #expect(reopened.object(forKey: "gallery.best") == nil)
    }
}
