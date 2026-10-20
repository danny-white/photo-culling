import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Cull: days model")
struct CullDaysModelTests {
    let pacific = TimeZone(identifier: "America/Los_Angeles")!
    let english = Locale(identifier: "en_US")

    /// 17 Oct 2026, noon in Pacific.
    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
    }

    private func makeModel(
        _ days: [Day], sleeper: ManualSleeper = ManualSleeper(), openYears: Set<String>? = nil,
        search: String? = nil
    ) -> (CullDaysModel, FakeTransport) {
        let list = daysJSON(days)
        let transport = FakeTransport { request, _ in
            if request.url?.path == "/m/api/search" { return jsonResponse(search ?? "{}", for: request) }
            return jsonResponse(list, for: request)
        }
        let model = CullDaysModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: transport), openYears: openYears,
            now: { today }, timeZone: pacific, sleep: sleeper.sleep)
        return (model, transport)
    }

    private func tag(_ day: Day) async -> CullDayRow.Tag? {
        let (model, _) = makeModel([day])
        await model.load()
        return (model.inProgress + model.years.flatMap(\.months).flatMap(\.rows)).first?.tag
    }

    // MARK: Grouping

    @Test func inProgressComesFirstThenYearsAndMonths() async {
        let days = [
            listDay("2026-10-12", decided: 10),                     // started, not finished: in progress
            listDay("2026-10-10"), listDay("2026-09-30", decided: 5, finished: true), listDay("2026-09-03"),
            listDay("2025-06-01", folder: "2025-06-01"), listDay(nil),
        ]
        let (model, _) = makeModel(days)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.inProgress.map(\.day.day) == ["2026/2026-10-12"])
        #expect(model.years.map(\.year) == ["2026", "2025", "misc"])
        let y2026 = model.years[0]
        #expect(y2026.months.map(\.name) == ["October", "September"])
        #expect(y2026.months.map(\.title) == ["October · 1", "September · 2"])
        #expect(y2026.months[0].rows.map(\.day.day) == ["2026/2026-10-10"])
        #expect(y2026.months[1].rows.map(\.day.day) == ["2026/2026-09-30", "2026/2026-09-03"])
        #expect(model.years[2].months.map(\.name) == ["Other folders"])
    }

    @Test func aYearsSubtitleCountsDaysFramesAndDoneDays() async {
        let days = [
            listDay("2026-10-10", frames: 1000), listDay("2026-10-09", frames: 234, finished: true),
            listDay("2026-10-08", frames: 100, stacks: 50, lrDone: 50),
        ]
        let (model, _) = makeModel(days)
        await model.load()
        #expect(model.years[0].subtitle == "3 days · 1,334 frames · 2 done")
        let one = makeModel([listDay("2025-01-01", frames: 1)]).0
        await one.load()
        #expect(one.years[0].subtitle == "1 day · 1 frames")
    }

    @Test func theNewestYearStartsOpenAndTheRestAreToggled() async {
        let (model, _) = makeModel([listDay("2026-10-10"), listDay("2025-10-10")])
        await model.load()
        #expect(model.openYears == ["2026"])
        #expect(model.isYearOpen("2026") && !model.isYearOpen("2025"))
        model.toggleYear("2025")
        model.toggleYear("2026")
        #expect(model.openYears == ["2025"])
        await model.refresh()                                   // a refresh keeps what you opened
        #expect(model.openYears == ["2025"])
    }

    @Test func restoredOpenYearsAreKept() async {
        let (model, _) = makeModel([listDay("2026-10-10"), listDay("2025-10-10")], openYears: [])
        await model.load()
        #expect(model.openYears.isEmpty)
    }

    @Test func onThisDayListsUnculledEarlierYearsWithinThreeDays() async {
        let days = [
            listDay("2026-10-15"),                                   // this year
            listDay("2025-10-18"), listDay("2024-10-14"), listDay("2023-10-21", decided: 4),     // 1 day, 3 days, decided
            listDay("2022-10-20"), listDay("2021-10-10"), listDay("2020-10-15", finished: true),  // 3 days, 7 days, finished
            listDay("2019-10-17", stacks: 10, lrDone: 10),                                // done in Lightroom
            listDay("2018-10-16"), listDay("2017-10-17"),
        ]
        let (model, _) = makeModel(days)
        await model.load()
        #expect(model.onThisDay.map(\.day.day) == [
            "2025/2025-10-18", "2024/2024-10-14", "2022/2022-10-20", "2018/2018-10-16",
        ])                                                       // at most four, 2017 left off
    }

    // MARK: Rows

    @Test func aRowCarriesWhatDayRowShows() async {
        let d = listDay(
            "2026-10-01", frames: 120, stacks: 84, decided: 30, lrDone: 20, place: "greenwood, washington, us",
            summary: "Dune walk\nand sunset", thumbs: [9, 8, 7])
        let (model, _) = makeModel([d])
        await model.load()
        let row = model.inProgress[0]
        #expect(row.title == "Thu, 1 Oct 2026")
        #expect(row.meta == "120 frames · 84 stacks · 20 done in Lightroom")
        #expect(row.place == "greenwood, washington")
        #expect(row.thumbs == [9, 8, 7])
        #expect(row.percent == 25 && row.showsBar)
        #expect(row.tag == .init(text: "25%", style: .normal))
        #expect(row.summary == "Dune walk\nand sunset" && row.why == nil && row.match == nil)
    }

    @Test func anUndatedRowShowsItsFolderAndId() async {
        let (model, _) = makeModel([listDay(nil, frames: 3, stacks: 3)])
        await model.load()
        let row = model.years[0].months[0].rows[0]
        #expect(row.title == "unsorted")
        #expect(row.meta == "3 frames · 3 stacks · misc/unsorted")
        #expect(!row.showsBar && row.percent == 0)
    }

    @Test func theTagFollowsTheSamePrecedenceAsTheWebApp() async {
        #expect(await tag(listDay("2026-10-01", decided: 5, landed: 3, conflicts: 2)) == .init(text: "2 conflicts", style: .warn))
        #expect(await tag(listDay("2026-10-01", decided: 5, landed: 3)) == .init(text: "Synced", style: .quiet))
        #expect(await tag(listDay("2026-10-01", decided: 5, sentAt: "2026-10-02T08:30:00")) == .init(text: "Sent", style: .quiet))
        #expect(await tag(listDay("2026-10-01", decided: 5, finished: true)) == .init(text: "Done", style: .quiet))
        #expect(await tag(listDay("2026-10-01", stacks: 10, lrDone: 10)) == .init(text: "In Lightroom", style: .quiet))
        #expect(await tag(listDay("2026-10-01", decided: 5)) == .init(text: "5%", style: .normal))
        #expect(await tag(listDay("2026-10-01")) == nil)
        #expect(await tag(listDay("2026-10-01", decided: 1, conflicts: 1))?.text == "1 conflict")
    }

    @Test func aShootUnderFortyEightHoursOldIsResting() async {
        let recent = today.timeIntervalSince1970 - 47 * 3600
        let older = today.timeIntervalSince1970 - 49 * 3600
        #expect(await tag(listDay("2026-10-16", lastTs: recent)) == .init(text: "Resting", style: .quiet))
        #expect(await tag(listDay("2026-10-15", lastTs: older)) == nil)
        #expect(await tag(listDay("2026-10-16", finished: true, lastTs: recent))?.text == "Done")
    }

    // MARK: Search

    private let found = """
    {"query":"chick","days":[
     {"day":"2026/2026-10-01","n":2,"ids":[43203,43214],"match_ids":[43203,43214,43999],"why":"2 photos · “a chick in a burrow”"},
     {"day":"2025/2025-06-02","n":0,"ids":[],"match_ids":[],"why":"Near Greenwood"},
     {"day":"2020/2020-01-01","n":1,"ids":[5],"match_ids":[5],"why":"not in the list"}],
     "photos":1234,"signals":["words","captions","pictures","dates"],"notes":["No picture search."]}
    """

    private func searchModel() async -> (CullDaysModel, ManualSleeper, FakeTransport) {
        let sleeper = ManualSleeper()
        let days = [
            listDay("2026-10-01", summary: "A day", thumbs: [1, 2, 3]), listDay("2025-06-02", summary: "Another", thumbs: [4, 5, 6]),
        ]
        let (model, transport) = makeModel(days, sleeper: sleeper, search: found)
        await model.load()
        return (model, sleeper, transport)
    }

    private func searchRequests(_ transport: FakeTransport) async -> [URLRequest] {
        await transport.requests.filter { $0.url?.path == "/m/api/search" }
    }

    @Test func aSearchRunsAfterTheLastKeystrokeAndGroupsTheHits() async throws {
        let (model, sleeper, transport) = await searchModel()
        #expect(!model.isShowingSearch)
        model.searchText = "chick"
        #expect(model.isShowingSearch && model.isSearching)
        #expect(await sleeper.waitFor(.milliseconds(280)))
        #expect(await searchRequests(transport).isEmpty)           // not before the delay
        await sleeper.release(.milliseconds(280))
        #expect(await eventually { await !model.isSearching })
        let result = try #require(model.searchResult)
        #expect(result.query == "chick")
        #expect(result.summary == "2 days · 1,234 photos, by words, captions and what’s in the pictures.")
        #expect(result.notes == ["No picture search."])
        #expect(result.rows.map(\.day.day) == ["2026/2026-10-01", "2025/2025-06-02"])   // the day we don't have is left out
        #expect(await searchRequests(transport).first?.url?.query == "q=chick")
    }

    @Test func aHitShowsItsPhotosFirstItsReasonAndPassesItsMatchesOn() async throws {
        let (model, sleeper, _) = await searchModel()
        model.searchText = "  chick "
        #expect(await sleeper.waitFor(.milliseconds(280)))
        await sleeper.release(.milliseconds(280))
        #expect(await eventually { await !model.isSearching })
        let rows = try #require(model.searchResult).rows
        #expect(rows[0].thumbs == [43203, 43214, 1])               // hits, topped up from the day's own
        #expect(rows[0].why == "2 photos · “a chick in a burrow”" && rows[0].summary == nil)
        #expect(rows[0].match == CullMatch(ids: [43203, 43214, 43999], label: "“chick”"))
        #expect(rows[1].thumbs == [4, 5, 6])
        #expect(rows[1].why == "Near Greenwood")
        #expect(rows[1].match == nil)                              // nothing matched inside the day
    }

    @Test func typingAgainRestartsTheDelayAndOnlyTheLastQueryIsAsked() async {
        let (model, sleeper, transport) = await searchModel()
        model.searchText = "chi"
        #expect(await sleeper.waitFor(.milliseconds(280)))
        model.searchText = "chick"
        #expect(await sleeper.waitFor(.milliseconds(280)))
        await sleeper.release(.milliseconds(280))
        #expect(await eventually { await !model.isSearching })
        let requests = await searchRequests(transport)
        #expect(requests.count == 1 && requests[0].url?.query == "q=chick")
    }

    @Test func anOlderAnswerIsDroppedWhenTheTextHasMovedOn() async {
        let sleeper = ManualSleeper()
        let found = self.found
        let gated = GatedTransport { request, _ in
            if request.url?.path == "/m/api/search" { return jsonResponse(found, for: request) }
            return jsonResponse(daysJSON([listDay("2026-10-01")]), for: request)
        }
        let model = CullDaysModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: gated), now: { today },
            timeZone: pacific, sleep: sleeper.sleep)
        let loading = Task { await model.load() }
        await gated.waitForRequests(1)
        await gated.release(0)
        await loading.value
        model.searchText = "chick"
        #expect(await sleeper.waitFor(.milliseconds(280)))
        await sleeper.release(.milliseconds(280))
        await gated.waitForRequests(2)                             // the search is in flight
        model.searchText = "owl"                                   // the box moves on
        await gated.release(1)
        for _ in 0..<50 { await Task.yield() }
        #expect(model.searchResult == nil)                         // chick's answer is not shown for owl
        #expect(model.isSearching)
    }

    @Test func aFailedSearchSaysSoAndFindsNothing() async throws {
        let sleeper = ManualSleeper()
        let transport = FakeTransport { request, _ in
            if request.url?.path == "/m/api/search" {
                return jsonResponse(#"{"error":"search is down"}"#, for: request, status: 500)
            }
            return jsonResponse(daysJSON([listDay("2026-10-01")]), for: request)
        }
        let model = CullDaysModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: transport), now: { today },
            timeZone: pacific, sleep: sleeper.sleep)
        await model.load()
        model.searchText = "x"
        #expect(await sleeper.waitFor(.milliseconds(280)))
        await sleeper.release(.milliseconds(280))
        #expect(await eventually { await !model.isSearching })
        let result = try #require(model.searchResult)
        #expect(result.summary == "No days match.")
        #expect(result.notes == ["Search failed: search is down"])
        #expect(result.rows.isEmpty)
    }

    @Test func oneHitAndOnePhotoUseTheSingular() async throws {
        let sleeper = ManualSleeper()
        let body = """
        {"query":"x","days":[{"day":"2026/2026-10-01","n":1,"ids":[1],"match_ids":[1],"why":"1 photo"}],
         "photos":1,"signals":["words"],"notes":[]}
        """
        let (model, _) = makeModel([listDay("2026-10-01")], sleeper: sleeper, search: body)
        await model.load()
        model.searchText = "x"
        #expect(await sleeper.waitFor(.milliseconds(280)))
        await sleeper.release(.milliseconds(280))
        #expect(await eventually { await !model.isSearching })
        #expect(try #require(model.searchResult).summary == "1 day · 1 photo, by words.")
    }

    @Test func clearingTheBoxShowsTheListAgain() async {
        let (model, sleeper, _) = await searchModel()
        model.searchText = "chick"
        #expect(await sleeper.waitFor(.milliseconds(280)))
        model.searchText = ""
        #expect(!model.isShowingSearch && !model.isSearching)
        #expect(await eventually { await sleeper.waiting.isEmpty })        // the pending search was cancelled
    }

    // MARK: Loading

    @Test func aFailedLoadSaysWhyAndARefreshKeepsWhatIsOnScreen() async {
        let fail = FakeTransport { _, _ in throw CullingBayError.transport("offline") }
        let broken = CullDaysModel(client: CullingBayClient(baseURL: testBaseURL, transport: fail))
        await broken.load()
        #expect(broken.phase == .failed("Can’t reach the photo server. Is the PC on and in Ubuntu?"))

        let toggle = FakeTransport { request, index in
            if index == 0 { return jsonResponse(daysJSON([listDay("2026-10-01")]), for: request) }
            throw CullingBayError.transport("offline")
        }
        let model = CullDaysModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: toggle), now: { today }, timeZone: pacific)
        await model.load()
        await model.refresh()
        #expect(model.phase == .loaded)
        #expect(model.years.count == 1)
        #expect(model.refreshError != nil)
    }

    @Test func aRefreshPicksUpNewDays() async {
        let step = FakeTransport { request, index in
            let days = index == 0 ? [listDay("2026-10-01")] : [listDay("2026-10-01"), listDay("2026-10-02", decided: 3)]
            return jsonResponse(daysJSON(days), for: request)
        }
        let model = CullDaysModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: step), now: { today }, timeZone: pacific)
        await model.load()
        #expect(model.inProgress.isEmpty)
        await model.refresh()
        #expect(model.inProgress.map(\.day.day) == ["2026/2026-10-02"])
        #expect(model.refreshError == nil)
    }
}

func listDay(
    _ date: String?, frames: Int = 100, stacks: Int = 80, decided: Int = 0, finished: Bool = false,
    landed: Int = 0, conflicts: Int = 0, lrDone: Int = 0, sentAt: String? = nil, place: String? = nil,
    summary: String? = nil, thumbs: [Int] = [1, 2, 3], lastTs: Double = 1_700_000_000, folder: String? = nil
) -> Day {
    let name = folder ?? date ?? "unsorted"
    return Day(
        day: (date.map { String($0.prefix(4)) } ?? "misc") + "/" + name, folder: name, date: date,
        frames: frames, stacks: stacks, thumbs: thumbs, lastTs: lastTs, place: place, places: [],
        gpsFrames: 0, summary: summary, decided: decided, sent: 0, landed: landed,
        conflicts: conflicts, lrDone: lrDone, finished: finished, sentAt: sentAt)
}
