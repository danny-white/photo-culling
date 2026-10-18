import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

/// Set CB_LIVE_URL (e.g. http://100.82.57.4:8000) to run these against the real server.
/// They only GET. Nothing here posts, least of all to /m/api/perf, which writes to real logs.
private let liveURL: URL? = ProcessInfo.processInfo.environment["CB_LIVE_URL"]
    .flatMap { URL(string: $0) }

@Suite("Live server (GET only)", .enabled(if: liveURL != nil, "CB_LIVE_URL is not set"))
struct LiveTests {
    let day = "2026/2026-10-01"

    private func makeClient() throws -> CullingBayClient {
        CullingBayClient(baseURL: try #require(liveURL))
    }

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await URLSessionTransport().send(request)
    }

    private func firstPhoto(of client: CullingBayClient) async throws -> Photo {
        let gallery = try await client.galleryDay(day, bursts: true)
        return try #require(gallery.photos.first)
    }

    @Test func daysDecodesMoreThan300Days() async throws {
        let client = try makeClient()
        let fetched: Fetched<DaysEnvelope> = try await client.fetch(path: "/m/api/days")
        let days = fetched.value.days
        #expect(days.count > 300, "got \(days.count) days")
        #expect(Set(days.map(\.day)).count == days.count)
        #expect(fetched.serverTiming?.total != nil)
        #expect(try await client.days().count == days.count)
    }

    @Test func galleryDayHas16RawPhotosInTimeOrder() async throws {
        let gallery = try await makeClient().galleryDay(day, bursts: true)
        #expect(gallery.day == day)
        #expect(gallery.date == "2026-10-01")
        #expect(gallery.photos.count == 16)
        #expect(gallery.photos.allSatisfy { $0.raw })
        let stamps = gallery.photos.compactMap(\.ts)
        #expect(stamps.count == gallery.photos.count)
        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func searchByFileNameMatchesOnWords() async throws {
        let list = try await makeClient().search("DSC05040")
        #expect(list.query == "DSC05040")
        #expect(!list.photos.isEmpty)
        #expect(list.photos.allSatisfy { $0.file == "DSC05040.ARW" })
        #expect(list.signals == ["words"])
    }

    @Test func searchHandlesPlusAmpersandAndUnicode() async throws {
        let client = try makeClient()
        for q in ["c++", "fish & chips", "Gruyère"] {
            let list = try await client.search(q)
            #expect(list.query == q, "server echoed a different query for \(q)")
        }
    }

    @Test func likeOfTheFirstPhotoWorks() async throws {
        let client = try makeClient()
        let first = try await firstPhoto(of: client)
        let list = try await client.like(first.id)
        #expect(list.query == nil)
        #expect(!list.photos.isEmpty)
        #expect(list.total >= list.photos.count)
    }

    @Test func cullDayDecodesWithSixteenStacks() async throws {
        let cull = try await makeClient().cullDay(day)
        #expect(cull.day == day)
        #expect(cull.date == "2026-10-01")
        #expect(cull.stacks.count == 16)
        #expect(cull.stacks.map(\.id) == Array(0..<16))
        #expect(cull.stacks.allSatisfy { stack in stack.frames.contains { $0.id == stack.lead } })
        #expect(cull.stacks.contains { $0.kind == .bracket } && cull.stacks.contains { $0.kind == .burst })
        // an unknown value would decode as .other; the server's known sets should all be named
        #expect(cull.stacks.allSatisfy { if case .other = $0.kind { false } else { true } })
        let decisions = cull.stacks.flatMap(\.frames).compactMap(\.decision)
        #expect(decisions.allSatisfy { d in
            if case .other = d.flag { return false }
            if case .other = d.state { return false }
            return true
        })
        #expect(cull.budget.stacks >= 5 && cull.budget.perHour == 10)
    }

    @Test func daySearchByFileNameFindsTheDay() async throws {
        let result = try await makeClient().daySearch("DSC05040")
        #expect(result.query == "DSC05040")
        #expect(result.signals == ["words"])
        let hit = try #require(result.days.first { $0.day == day })
        #expect(hit.n >= 1 && !hit.matchIDs.isEmpty)
        #expect(hit.ids == Array(hit.matchIDs.prefix(4)))
    }

    @Test func dayLikeDecodesAndLeavesOutItsOwnDay() async throws {
        let client = try makeClient()
        let first = try await firstPhoto(of: client)
        let result = try await client.dayLike(first.id)
        #expect(result.query == nil)
        #expect(!result.days.contains { $0.day == day })
    }

    @Test func anUnknownDayIsA404WithAMessage() async throws {
        let client = try makeClient()
        do {
            _ = try await client.galleryDay("1900/1900-01-01")
            Issue.record("expected a throw")
        } catch let error as CullingBayError {
            guard case .http(let status, let message) = error else {
                Issue.record("expected .http, got \(error)")
                return
            }
            #expect(status == 404)
            #expect(message != nil)
        }
    }

    @Test func theFirstThumbIsAJPEG() async throws {
        let client = try makeClient()
        let first = try await firstPhoto(of: client)
        let (data, response) = try await get(client.imageURL(id: first.id, size: .thumb))
        #expect(response.statusCode == 200)
        #expect(Array(data.prefix(2)) == [0xFF, 0xD8])
        #expect(timingHeader(response) != nil)
    }

    @Test func aCropIsAJPEGWithACropBoxHeader() async throws {
        let client = try makeClient()
        let first = try await firstPhoto(of: client)
        let url = client.cropURL(id: first.id, centerX: 0.5, centerY: 0.5, width: 800, height: 800)
        let (data, response) = try await get(url)
        #expect(response.statusCode == 200)
        #expect(Array(data.prefix(2)) == [0xFF, 0xD8])
        let box = try #require(response.value(forHTTPHeaderField: "X-Crop-Box"))
        #expect(box.contains(" of "), "unexpected X-Crop-Box: \(box)")
    }

    @Test @MainActor func homeModelLoadsAndGroupsTheRealDays() async throws {
        let settings = InMemoryGallerySettings()
        let model = HomeModel(client: try makeClient(), settings: settings)
        await model.load()
        #expect(model.phase == .loaded)
        let index = model.index
        #expect(index.dayCount > 300)
        #expect(index.years.flatMap(\.days).count == index.dayCount)
        #expect(index.years.contains { $0.year == "2026" })
        #expect(index.years.flatMap(\.months).flatMap(\.days).count == index.dayCount)
        #expect(index.years.allSatisfy { !$0.months.isEmpty && $0.photoCount > 0 })
        // first visit opens the newest year and its newest month
        let newest = try #require(index.years.first)
        #expect(model.openYears == [newest.year])
        #expect(model.openMonths == [try #require(newest.months.first).key])
        #expect(settings.hasOpenState)
    }

    @Test func aSecondGalleryDayCallIsNotModified() async throws {
        let client = try makeClient()
        let first: Fetched<GalleryDay> = try await client.fetch(
            path: "/m/api/gallery/day/\(day)", query: [("best", "0"), ("bursts", "1")])
        #expect(!first.notModified)
        let second: Fetched<GalleryDay> = try await client.fetch(
            path: "/m/api/gallery/day/\(day)", query: [("best", "0"), ("bursts", "1")])
        #expect(second.notModified)
        #expect(second.value == first.value)
    }
}

private func timingHeader(_ response: HTTPURLResponse) -> ServerTiming? {
    ServerTiming.parse(response.value(forHTTPHeaderField: "Server-Timing"))
}
