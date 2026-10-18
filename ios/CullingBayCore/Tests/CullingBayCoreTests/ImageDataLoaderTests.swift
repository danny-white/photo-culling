import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@Suite("Image data loader")
struct ImageDataLoaderTests {
    private let thumb1 = URL(string: "http://100.82.57.4:8000/m/api/img/1?s=thumb")!
    private let thumb2 = URL(string: "http://100.82.57.4:8000/m/api/img/2?s=thumb")!
    private let thumb3 = URL(string: "http://100.82.57.4:8000/m/api/img/3?s=thumb")!

    /// Answers each URL with `size` bytes whose first byte is the photo id.
    private func pictureTransport(size: Int = 4, headers: [String: String] = [:]) -> FakeTransport {
        FakeTransport { request, _ in
            let id = UInt8(request.url?.path.split(separator: "/").last.flatMap { Int($0) } ?? 0)
            return (Data([id] + Array(repeating: 0xAB, count: size - 1)), makeResponse(for: request, headers: headers))
        }
    }

    @Test func loadsThroughTheTransport() async throws {
        let transport = pictureTransport()
        let loader = ImageDataLoader(transport: transport)
        let data = try await loader.data(for: thumb1)
        #expect(data == Data([1, 0xAB, 0xAB, 0xAB]))
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url == thumb1)
        #expect(requests[0].httpMethod == "GET")
    }

    @Test func aSecondRequestIsServedFromMemory() async throws {
        let transport = pictureTransport()
        let loader = ImageDataLoader(transport: transport)
        let first = try await loader.data(for: thumb1)
        let second = try await loader.data(for: thumb1)
        #expect(first == second)
        #expect(await transport.requests.count == 1)
        #expect(await loader.cachedBytes == 4)
    }

    // MARK: De-duplication

    @Test func twoConcurrentRequestsForOneURLShareOneTransportCall() async throws {
        let gate = GatedTransport { request, _ in (Data([9, 9, 9]), makeResponse(for: request)) }
        let loader = ImageDataLoader(transport: gate)
        let a = Task { try await loader.data(for: thumb1) }
        let b = Task { try await loader.data(for: thumb1) }
        #expect(await eventually { await loader.waiterCount(for: thumb1) == 2 })
        await gate.release(0)
        #expect(try await a.value == Data([9, 9, 9]))
        #expect(try await b.value == Data([9, 9, 9]))
        #expect(await gate.requests.count == 1)
        #expect(await loader.flightCount == 0)
    }

    @Test func differentURLsAreSeparateRequests() async throws {
        let transport = pictureTransport()
        let loader = ImageDataLoader(transport: transport)
        async let one = loader.data(for: thumb1)
        async let two = loader.data(for: thumb2)
        let (a, b) = try await (one, two)
        #expect(a.first == 1 && b.first == 2)
        #expect(await transport.requests.count == 2)
    }

    @Test func aFailureReachesEveryWaiterAndIsNotCached() async throws {
        let gate = GatedTransport { request, index in
            index == 0
                ? (Data("{\"error\":\"cannot decode\"}".utf8), makeResponse(for: request, status: 415))
                : (Data([1]), makeResponse(for: request))
        }
        let loader = ImageDataLoader(transport: gate)
        let a = Task { try await loader.data(for: thumb1) }
        let b = Task { try await loader.data(for: thumb1) }
        #expect(await eventually { await loader.waiterCount(for: thumb1) == 2 })
        await gate.release(0)
        for task in [a, b] {
            do {
                _ = try await task.value
                Issue.record("expected a throw")
            } catch let error as CullingBayError {
                #expect(error == .http(status: 415, message: "cannot decode"))
            }
        }
        await gate.release(1)
        #expect(try await loader.data(for: thumb1) == Data([1]))
        #expect(await gate.requests.count == 2)
    }

    @Test func aNon2xxWithoutJSONHasNoMessage() async {
        let loader = ImageDataLoader(transport: fixedTransport(status: 500, body: "oops"))
        do {
            _ = try await loader.data(for: thumb1)
            Issue.record("expected a throw")
        } catch {
            #expect(error as? CullingBayError == .http(status: 500, message: nil))
        }
    }

    @Test func aTransportErrorBecomesATransportError() async {
        let loader = ImageDataLoader(transport: FakeTransport { _, _ in throw URLError(.timedOut) })
        do {
            _ = try await loader.data(for: thumb1)
            Issue.record("expected a throw")
        } catch {
            guard case .transport = error as? CullingBayError else {
                Issue.record("expected .transport, got \(error)")
                return
            }
        }
    }

    // MARK: Cache

    @Test func theCacheEvictsTheLeastRecentlyUsedByTotalBytes() async throws {
        let transport = pictureTransport()
        let loader = ImageDataLoader(transport: transport, cacheLimit: 10)
        _ = try await loader.data(for: thumb1)
        _ = try await loader.data(for: thumb2)
        #expect(await loader.cachedBytes == 8)
        _ = try await loader.data(for: thumb3)          // 12 > 10: thumb1 goes
        #expect(await loader.cachedURLs == [thumb2, thumb3])
        #expect(await loader.cachedBytes == 8)
        _ = try await loader.data(for: thumb2)          // a hit makes thumb2 the newest
        #expect(await loader.cachedURLs == [thumb3, thumb2])
        #expect(await transport.requests.count == 3)
        _ = try await loader.data(for: thumb1)          // back again: thumb3 goes
        #expect(await loader.cachedURLs == [thumb2, thumb1])
        #expect(await transport.requests.count == 4)
    }

    @Test func aPictureBiggerThanTheLimitIsReturnedButNotKept() async throws {
        let loader = ImageDataLoader(transport: pictureTransport(size: 20), cacheLimit: 10)
        #expect(try await loader.data(for: thumb1).count == 20)
        #expect(await loader.cachedBytes == 0)
        #expect(await loader.cachedURLs.isEmpty)
    }

    @Test func theDefaultLimitIs150Megabytes() {
        #expect(ImageDataLoader.defaultCacheLimit == 150_000_000)
    }

    // MARK: Cancellation

    @Test func cancellingOneWaiterLeavesTheOthersTheirData() async throws {
        let gate = GatedTransport { request, _ in (Data([7, 7]), makeResponse(for: request)) }
        let loader = ImageDataLoader(transport: gate)
        let a = Task { try await loader.data(for: thumb1) }
        let b = Task { try await loader.data(for: thumb1) }
        #expect(await eventually { await loader.waiterCount(for: thumb1) == 2 })
        a.cancel()
        #expect(await eventually { await loader.waiterCount(for: thumb1) == 1 })
        do {
            _ = try await a.value
            Issue.record("the cancelled waiter should throw")
        } catch {
            #expect(error is CancellationError)
        }
        await gate.release(0)
        #expect(try await b.value == Data([7, 7]))
        #expect(await gate.requests.count == 1)
        #expect(await loader.cachedURLs == [thumb1])
    }

    @Test func cancellingTheLastWaiterDropsTheRequestAndTheNextCallStartsAFreshOne() async throws {
        let gate = GatedTransport { request, _ in (Data([5]), makeResponse(for: request)) }
        let loader = ImageDataLoader(transport: gate)
        let a = Task { try await loader.data(for: thumb1) }
        #expect(await eventually { await loader.waiterCount(for: thumb1) == 1 })
        a.cancel()
        #expect(await eventually { await loader.flightCount == 0 })
        let b = Task { try await loader.data(for: thumb1) }
        #expect(await eventually { await loader.waiterCount(for: thumb1) == 1 })
        await gate.release(0)
        await gate.release(1)
        #expect(try await b.value == Data([5]))
        #expect(await gate.requests.count == 2)
    }

    @Test func aTaskCancelledBeforeItStartsThrowsAtOnce() async {
        let loader = ImageDataLoader(transport: GatedTransport { request, _ in (Data(), makeResponse(for: request)) })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.data(for: thumb1)
        }
        do {
            _ = try await task.value
            Issue.record("expected a throw")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await eventually { await loader.flightCount == 0 })
    }

    // MARK: Reporting

    @Test func eachNetworkLoadIsReportedAndCacheHitsAreNot() async throws {
        let recorder = ReportRecorder()
        let loader = ImageDataLoader(
            transport: pictureTransport(size: 6, headers: ["Server-Timing": "total;dur=12.5"]),
            report: { recorder.record($0, $1, $2, $3) })
        _ = try await loader.data(for: thumb1)
        _ = try await loader.data(for: thumb1)
        _ = try await loader.data(for: thumb2)
        let reports = recorder.reports
        #expect(reports.map(\.url) == [thumb1, thumb2])
        #expect(reports.allSatisfy { $0.bytes == 6 && $0.ms >= 0 && $0.timing?.total == 12.5 })
    }

    @Test func aFailedLoadIsNotReported() async {
        let recorder = ReportRecorder()
        let loader = ImageDataLoader(
            transport: fixedTransport(status: 404), report: { recorder.record($0, $1, $2, $3) })
        _ = try? await loader.data(for: thumb1)
        #expect(recorder.reports.isEmpty)
    }
}

@Suite("Perf marks")
struct PerfMarksTests {
    let url = URL(string: "http://100.82.57.4:8000/m/api/img/43203?s=view")!

    @Test func theViewerMarksUseTheWebPagesTypeNames() {
        #expect(PerfMarks.viewerFirst(ms: 12, url: url) == PerfItem(type: "viewer_first", ms: 12, name: "/m/api/img/43203?s=view"))
        #expect(PerfMarks.viewerPhoto(ms: 300, url: url).type == "viewer_photo")
        #expect(PerfMarks.viewerHD(ms: 900, url: url).type == "viewer_hd")
    }

    @Test func resultsReadyNamesTheScreenAndCount() {
        let item = PerfMarks.resultsReady(ms: 250, source: .search("x"), count: 40)
        #expect(item == PerfItem(type: "results_ready", ms: 250, screen: "q", n: 40))
        #expect(PerfMarks.resultsReady(ms: 1, source: .like(5, file: nil), count: 1).screen == "like")
        #expect(PerfMarks.resultsReady(ms: 1, source: .day("2026/2026-10-01"), count: 1).screen == "day")
    }

    @Test func saveReadyHasANameAndCount() {
        let item = PerfMarks.saveReady(ms: 800, url: url, count: 3)
        #expect(item == PerfItem(type: "save_ready", ms: 800, name: "/m/api/img/43203?s=view", n: 3))
    }

    @Test func aFetchItemCarriesBytesAndTheServersTime() {
        let timing = ServerTiming(header: "total;dur=59.2")
        let item = PerfMarks.fetch(url: url, ms: 80, bytes: 1234, serverTiming: timing)
        #expect(item.type == "fetch" && item.detail == "network")
        #expect(item.bytes == 1234 && item.serverMs == 59.2)
        #expect(PerfMarks.fetch(url: url, ms: 80, bytes: 1, serverTiming: nil).serverMs == nil)
    }

    @Test func aLongNameIsCutTo300Characters() {
        let long = URL(string: "http://100.82.57.4:8000/m/api/gallery/search?q=" + String(repeating: "a", count: 400))!
        #expect(PerfMarks.name(of: long).count == 300)
    }
}
