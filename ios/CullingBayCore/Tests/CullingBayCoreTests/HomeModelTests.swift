import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Home model")
struct HomeModelTests {
    let pacific = TimeZone(identifier: "America/Los_Angeles")!

    private func days() -> [Day] {
        [
            libraryDay("2026-10-17", frames: 100, place: "seattle, washington, us"),
            libraryDay("2026-10-01", frames: 20),
            libraryDay("2026-08-09", frames: 30),
            libraryDay("2025-10-16", frames: 40, place: "greenwood, washington, us", thumbs: [77]),
        ]
    }

    private func makeModel(
        transport: any HTTPTransport, settings: InMemoryGallerySettings = InMemoryGallerySettings()
    ) -> HomeModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
        return HomeModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: transport), settings: settings,
            now: { today }, timeZone: pacific)
    }

    private func daysTransport(_ days: [Day]) -> FakeTransport {
        let body = daysJSON(days)
        return FakeTransport { request, _ in jsonResponse(body, for: request) }
    }

    @Test func loadsAndGroupsTheDays() async {
        let model = makeModel(transport: daysTransport(days()))
        #expect(model.phase == .idle)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.index.years.map(\.year) == ["2026", "2025"])
        #expect(model.onThisDay.map(\.year) == [2025])
        #expect(model.onThisDay.first?.thumb == 77)
    }

    @Test func theFirstVisitOpensTheNewestYearAndMonth() async {
        let settings = InMemoryGallerySettings()
        let model = makeModel(transport: daysTransport(days()), settings: settings)
        await model.load()
        #expect(model.openYears == ["2026"])
        #expect(model.openMonths == ["2026-10"])
        #expect(model.isYearOpen("2026") && !model.isYearOpen("2025"))
        #expect(model.isMonthOpen("2026-10") && !model.isMonthOpen("2026-08"))
        #expect(settings.hasOpenState)
        #expect(settings.openYears == ["2026"])
    }

    @Test func savedOpenStateIsKeptEvenWhenEmpty() async {
        let settings = InMemoryGallerySettings(openYears: [], openMonths: [])
        let model = makeModel(transport: daysTransport(days()), settings: settings)
        await model.load()
        #expect(model.openYears.isEmpty && model.openMonths.isEmpty)
    }

    @Test func anEmptyLibraryOpensNothing() async {
        let settings = InMemoryGallerySettings()
        let model = makeModel(transport: daysTransport([]), settings: settings)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.index.years.isEmpty)
        #expect(!settings.hasOpenState)
    }

    @Test func togglesAreRememberedInTheSettings() async {
        let settings = InMemoryGallerySettings()
        let model = makeModel(transport: daysTransport(days()), settings: settings)
        await model.load()
        model.toggleYear("2025")
        model.toggleMonth("2026-08")
        #expect(model.openYears == ["2026", "2025"])
        #expect(settings.openYears == ["2026", "2025"])
        #expect(settings.openMonths == ["2026-10", "2026-08"])
        model.toggleYear("2026")
        model.toggleMonth("2026-10")
        #expect(model.openYears == ["2025"])
        #expect(settings.openYears == ["2025"])
        #expect(!model.isMonthOpen("2026-10"))
        #expect(settings.openMonths == ["2026-08"])
    }

    @Test func aFailedFirstLoadSaysWhy() async {
        let model = makeModel(transport: fixedTransport(status: 500, body: "{\"error\":\"disk\"}"))
        await model.load()
        #expect(model.phase == .failed("Couldn’t load the library: disk"))
    }

    @Test func refreshFetchesAgainAndUsesTheETag() async {
        let body = daysJSON(days())
        let transport = FakeTransport { request, index in
            index == 0
                ? (Data(body.utf8), makeResponse(for: request, headers: ["ETag": "\"v1\""]))
                : (Data(), makeResponse(for: request, status: 304))
        }
        let model = makeModel(transport: transport)
        await model.load()
        await model.refresh()
        #expect(model.phase == .loaded)
        #expect(model.index.dayCount == 4)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    }

    @Test func aFailedRefreshKeepsWhatIsOnScreen() async {
        let body = daysJSON(days())
        let transport = FakeTransport { request, index in
            if index == 0 { return (Data(body.utf8), makeResponse(for: request)) }
            throw URLError(.notConnectedToInternet)
        }
        let model = makeModel(transport: transport)
        await model.load()
        await model.refresh()
        #expect(model.phase == .loaded)
        #expect(model.index.dayCount == 4)
        #expect(model.refreshError == "Can’t reach the photo server. Is the PC on and in Ubuntu?")
    }

    @Test func aGoodRefreshClearsTheRefreshError() async {
        let body = daysJSON(days())
        let transport = FakeTransport { request, index in
            if index == 1 { throw URLError(.timedOut) }
            return (Data(body.utf8), makeResponse(for: request))
        }
        let model = makeModel(transport: transport)
        await model.load()
        await model.refresh()
        #expect(model.refreshError != nil)
        await model.refresh()
        #expect(model.refreshError == nil)
    }

    @Test func aFailedFirstLoadCanBeRetried() async {
        let body = daysJSON(days())
        let transport = FakeTransport { request, index in
            if index == 0 { throw URLError(.timedOut) }
            return (Data(body.utf8), makeResponse(for: request))
        }
        let model = makeModel(transport: transport)
        await model.load()
        #expect(model.phase == .failed("Can’t reach the photo server. Is the PC on and in Ubuntu?"))
        await model.load()
        #expect(model.phase == .loaded)
    }
}
