import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import CullingBayCore

@Suite("Offline: downloader")
struct OfflineDownloaderTests {
    let dayID = "2026/2026-10-01"

    /// Frame 1 has an AF point, frames 2 and 3 (a burst) have one and none.
    private let dayBody = cullJSON(cullDay([
        cullStack(0, .single, [cullFrame(1, af: [0.25, 0.75])]),
        cullStack(1, .burst, [cullFrame(2, af: [0.5, 0.5]), cullFrame(3)]),
    ]))

    private var listDay: Day { planDay("2026-10-01", frames: 3, decided: 1) }

    /// The PC: the day, then a body for every picture and crop, unless `answer` says otherwise.
    private func server(
        answer: @escaping @Sendable (URLRequest) throws -> (Int, Data)? = { _ in nil }
    ) -> FakeTransport {
        let body = dayBody
        return FakeTransport { request, _ in
            let path = request.url?.path ?? ""
            if let (status, data) = try answer(request) {
                return (data, makeResponse(for: request, status: status))
            }
            if path.hasPrefix("/m/api/day/") { return (Data(body.utf8), makeResponse(for: request)) }
            let tag = path.hasPrefix("/m/api/crop/") ? "crop" : (queryItems(request)["s"] ?? "?")
            let id = path.split(separator: "/").last ?? ""
            return (Data("\(tag)-\(id)".utf8), makeResponse(for: request))
        }
    }

    private func downloader(_ base: any HTTPTransport, _ store: OfflineStore, concurrency: Int = 4) -> OfflineDownloader {
        OfflineDownloader(baseURL: testBaseURL, transport: base, store: store, concurrency: concurrency)
    }

    // MARK: A whole day

    @Test func aDayComesDownWholeAndIsRecorded() async throws {
        let root = TempRoot()
        let store = root.store()
        let base = server()
        try await downloader(base, store).download(listDay, includeCrops: true)

        for id in 1...3 {
            #expect(store.readImage(.thumb, id: id) == Data("thumb-\(id)".utf8))
            #expect(store.readImage(.view, id: id) == Data("view-\(id)".utf8))
            #expect(store.readImage(.af, id: id) == Data("crop-\(id)".utf8))
        }
        #expect(store.isSaved(dayID))
        let record = try #require(store.record(for: dayID))
        #expect(record.frames == 3)
        #expect(record.photos == [1, 2, 3])
        #expect(record.bytes == store.totalBytes - (try Data(contentsOf: root.url.appendingPathComponent("manifest.json"))).count)
        #expect(store.readDay(dayID) == Data(dayBody.utf8))
        #expect(await base.requests.count == 1 + 9)         // the day, then 3 frames of 3 files
    }

    @Test func picturesAreAskedForWithoutWarmingAndCropsAtTheAFPointWithoutKeeping() async throws {
        let store = TempRoot().store()
        let base = server()
        try await downloader(base, store).download(listDay, includeCrops: true)
        let requests = await base.requests

        let pictures = requests.filter { $0.url?.path.hasPrefix("/m/api/img/") == true }
        #expect(pictures.count == 6)
        #expect(pictures.allSatisfy { queryItems($0)["warm"] == "0" })
        #expect(Set(pictures.compactMap { queryItems($0)["s"] }) == ["thumb", "view"])

        let crops = requests.filter { $0.url?.path.hasPrefix("/m/api/crop/") == true }
        func crop(_ id: Int) -> [String: String] {
            queryItems(crops.first { $0.url?.path == "/m/api/crop/\(id)" }!)
        }
        #expect(crop(1) == ["x": "0.25", "y": "0.75", "w": "1200", "h": "1200", "keep": "0"])
        #expect(crop(2) == ["x": "0.5", "y": "0.5", "w": "1200", "h": "1200", "keep": "0"])
        #expect(crop(3) == ["x": "0.5", "y": "0.5", "w": "1200", "h": "1200", "keep": "0"])   // no AF: the centre
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func withoutCropsNoCropIsAskedForOrKept() async throws {
        let store = TempRoot().store()
        let base = server()
        try await downloader(base, store).download(listDay, includeCrops: false)
        #expect(await base.requests.filter { $0.url?.path.hasPrefix("/m/api/crop/") == true }.isEmpty)
        #expect(!store.hasImage(.af, id: 1))
        #expect(store.isSaved(dayID))
    }

    @Test func theRowsOwnPicturesAreKeptToo() async throws {
        let store = TempRoot().store()
        // 99 is on the row but is not a frame of any stack; 1 is both.
        let day = planDay("2026-10-01", frames: 3, decided: 1, thumbs: [1, 99])
        try await downloader(server(), store).download(day, includeCrops: false)
        #expect(store.readImage(.thumb, id: 99) == Data("thumb-99".utf8))
        #expect(!store.hasImage(.view, id: 99))
        #expect(store.record(for: dayID)?.photos == [1, 2, 3, 99])
    }

    // MARK: Skipping, progress

    @Test func filesAlreadyInTheStoreAreNotFetchedAgain() async throws {
        let store = TempRoot().store()
        try store.writeImage(Data("kept".utf8), kind: .view, id: 2)
        try store.writeImage(Data("kept".utf8), kind: .af, id: 1)
        let base = server()
        try await downloader(base, store).download(listDay, includeCrops: true)
        #expect(await base.requests.count == 1 + 9 - 2)
        #expect(store.readImage(.view, id: 2) == Data("kept".utf8))
        #expect(store.isSaved(dayID))
    }

    @Test func progressCountsFilesIncludingThoseAlreadyThere() async throws {
        let store = TempRoot().store()
        try store.writeImage(Data("kept".utf8), kind: .thumb, id: 1)
        let seen = Mutex<[[Int]]>([])
        try await downloader(server(), store).download(listDay, includeCrops: true) { done, total in
            seen.withLock { $0.append([done, total]) }
        }
        let calls = seen.withLock { $0 }
        #expect(calls.first == [1, 9])
        #expect(calls.last == [9, 9])
        #expect(calls.count == 9)                           // once at the start, then once per file fetched
        #expect(calls.map { $0[0] } == Array(1...9))
    }

    @Test func noMoreThanFourFilesAreInFlight() async throws {
        let store = TempRoot().store()
        let counter = Counter()
        let frames = (1...10).map { cullFrame($0) }
        let body = cullJSON(cullDay(frames.map { cullStack($0.id, .single, [$0]) }))
        let base = FakeCountingTransport(counter: counter, day: body)
        let day = planDay("2026-10-01", frames: 10, decided: 1)
        try await OfflineDownloader(baseURL: testBaseURL, transport: base, store: store)
            .download(day, includeCrops: true)
        #expect(counter.peak <= 4)
        #expect(counter.peak >= 2)                          // and they do overlap
        #expect(counter.total == 1 + 30)
        #expect(store.isSaved(dayID))
    }

    // MARK: Refusals and failures

    @Test func aFileTheServerRefusesIsLeftOutAndTheDayStillCompletes() async throws {
        let store = TempRoot().store()
        let base = server { request in
            request.url?.path == "/m/api/crop/2" ? (415, Data(#"{"error":"cannot decode"}"#.utf8)) : nil
        }
        try await downloader(base, store).download(listDay, includeCrops: true)
        #expect(!store.hasImage(.af, id: 2))
        #expect(store.hasImage(.af, id: 1) && store.hasImage(.af, id: 3))
        #expect(store.isSaved(dayID))
    }

    @Test func aServerErrorStopsTheDayAndALaterTryOnlyFetchesWhatIsMissing() async throws {
        let store = TempRoot().store()
        let broken = server { request in
            request.url?.path == "/m/api/img/3" && queryItems(request)["s"] == "view"
                ? (500, Data()) : nil
        }
        await #expect(throws: CullingBayError.http(status: 500, message: nil)) {
            try await downloader(broken, store, concurrency: 1).download(listDay, includeCrops: true)
        }
        #expect(!store.isSaved(dayID))
        #expect(store.record(for: dayID)?.complete == false)
        #expect(store.hasImage(.thumb, id: 1))              // what came is kept for the next try
        let had = (1...3).flatMap { id in OfflineImageKind.allCases.filter { store.hasImage($0, id: id) }.map { ($0, id) } }.count
        #expect(had > 0 && had < 9)

        let fixed = server()
        try await downloader(fixed, store).download(listDay, includeCrops: true)
        #expect(store.isSaved(dayID))
        #expect(await fixed.requests.count == 1 + (9 - had))
    }

    @Test func aLostConnectionStopsTheDayAsATransportError() async throws {
        let store = TempRoot().store()
        let base = server { request in
            if request.url?.path.hasPrefix("/m/api/img/") == true { throw CullingBayError.transport("offline") }
            return nil
        }
        await #expect(throws: CullingBayError.transport("offline")) {
            try await downloader(base, store).download(listDay, includeCrops: true)
        }
        #expect(!store.isSaved(dayID))
    }

    @Test func aPlainURLErrorIsATransportErrorToo() async throws {
        let store = TempRoot().store()
        let base = server { _ in throw TestFailure() }
        await #expect(throws: CullingBayError.self) {
            try await downloader(base, store).download(listDay, includeCrops: true)
        }
        #expect(store.record(for: dayID) == nil)            // the day itself never came
    }

    @Test func aDayThatIsGoneIsAnHTTPError() async throws {
        let store = TempRoot().store()
        let base = server { request in
            request.url?.path.hasPrefix("/m/api/day/") == true ? (404, Data(#"{"error":"no such day"}"#.utf8)) : nil
        }
        await #expect(throws: CullingBayError.http(status: 404, message: nil)) {
            try await downloader(base, store).download(listDay, includeCrops: true)
        }
    }

    @Test func aDayBodyThatIsNotADayIsADecodingError() async throws {
        let store = TempRoot().store()
        let base = server { request in
            request.url?.path.hasPrefix("/m/api/day/") == true ? (200, Data("<html>".utf8)) : nil
        }
        do {
            try await downloader(base, store).download(listDay, includeCrops: true)
            Issue.record("should have thrown")
        } catch let error as CullingBayError {
            guard case .decoding = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
    }

    // MARK: Stopping

    @Test func aStoppedDownloadWritesNothingMoreAndLeavesTheDayUnfinished() async throws {
        let store = TempRoot().store()
        let body = dayBody
        let gate = GatedTransport { request, _ in
            let path = request.url?.path ?? ""
            let data = path.hasPrefix("/m/api/day/") ? Data(body.utf8) : Data("picture".utf8)
            return (data, makeResponse(for: request))
        }
        let loader = downloader(gate, store)
        let day = listDay
        let task = Task { try await loader.download(day, includeCrops: true) }
        await gate.release(0)                               // the day's JSON
        await gate.waitForRequests(5)                       // then four files in flight
        task.cancel()
        for index in 1...4 { await gate.release(index) }    // their answers arrive after the stop
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!store.isSaved(dayID))
        let written = (1...3).flatMap { id in OfflineImageKind.allCases.filter { store.hasImage($0, id: id) } }
        #expect(written.isEmpty)
    }
}

/// How many requests are in flight, and the most there were.
final class Counter: Sendable {
    private let state = Mutex((current: 0, peak: 0, total: 0))
    func enter() { state.withLock { $0.current += 1; $0.total += 1; $0.peak = max($0.peak, $0.current) } }
    func leave() { state.withLock { $0.current -= 1 } }
    var peak: Int { state.withLock { $0.peak } }
    var total: Int { state.withLock { $0.total } }
}

/// A server that takes a moment over each picture, so overlapping requests show.
struct FakeCountingTransport: HTTPTransport {
    let counter: Counter
    let day: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        counter.enter()
        defer { counter.leave() }
        try await Task.sleep(for: .milliseconds(10))
        let data = request.url?.path.hasPrefix("/m/api/day/") == true ? Data(day.utf8) : Data("x".utf8)
        return (data, makeResponse(for: request))
    }
}
