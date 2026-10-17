import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@Suite("PerfReporter")
struct PerfReporterTests {
    private func decodeBody(_ request: URLRequest) throws -> [[String: Any]] {
        let data = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["items"])
        return try #require(object["items"] as? [[String: Any]])
    }

    private func n(_ item: [String: Any]?) -> Int? {
        item?["n"] as? Int
    }

    @Test func flushPostsTheBodyAndHeaders() async throws {
        let transport = fixedTransport(body: #"{"ok":true}"#)
        let reporter = PerfReporter(client: testBaseURL, transport: transport)
        await reporter.mark(PerfItem(
            type: "image", ms: 123.5, name: "thumb", screen: "gallery", detail: "cold",
            bytes: 20480, n: 3, serverMs: 59.2, waitMs: 4.5, ttfbMs: 70.1, dlMs: 12.25))
        await reporter.mark(PerfItem(type: "screen", ms: 8))
        await reporter.flush()

        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "http://100.82.57.4:8000/m/api/perf")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Culling-Bay") == "1")

        let items = try decodeBody(request)
        #expect(items.count == 2)
        let first = items[0]
        #expect(first["type"] as? String == "image")
        #expect(first["ms"] as? Double == 123.5)
        #expect(first["name"] as? String == "thumb")
        #expect(first["screen"] as? String == "gallery")
        #expect(first["detail"] as? String == "cold")
        #expect(first["bytes"] as? Int == 20480)
        #expect(first["n"] as? Int == 3)
        #expect(first["server_ms"] as? Double == 59.2)
        #expect(first["wait_ms"] as? Double == 4.5)
        #expect(first["ttfb_ms"] as? Double == 70.1)
        #expect(first["dl_ms"] as? Double == 12.25)
        #expect(Set(first.keys) == [
            "type", "ms", "name", "screen", "detail", "bytes", "n",
            "server_ms", "wait_ms", "ttfb_ms", "dl_ms",
        ])
    }

    @Test func nilFieldsAreOmittedFromTheBody() async throws {
        let transport = fixedTransport()
        let reporter = PerfReporter(client: testBaseURL, transport: transport)
        await reporter.mark(PerfItem(type: "screen", ms: 8))
        await reporter.flush()
        let items = try decodeBody(try #require(await transport.requests.first))
        #expect(Set(items[0].keys) == ["type", "ms"])
    }

    @Test func perfItemRoundTripsAndUsesSnakeCase() throws {
        let item = PerfItem(type: "t", ms: 1, serverMs: 2, waitMs: 3, ttfbMs: 4, dlMs: 5)
        let data = try JSONEncoder().encode(item)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["server_ms", "wait_ms", "ttfb_ms", "dl_ms"] {
            #expect(text.contains("\"\(key)\""))
        }
        #expect(try JSONDecoder().decode(PerfItem.self, from: data) == item)
    }

    @Test func flushWithNothingQueuedSendsNothing() async {
        let transport = fixedTransport()
        let reporter = PerfReporter(client: testBaseURL, transport: transport)
        await reporter.flush()
        #expect(await transport.requests.isEmpty)
    }

    @Test func theQueueIsCappedAt400AndExtraMarksAreDropped() async throws {
        let transport = fixedTransport()
        let reporter = PerfReporter(client: testBaseURL, transport: transport)
        for i in 0..<450 {
            await reporter.mark(PerfItem(type: "t", ms: Double(i), n: i))
        }
        #expect(await reporter.pendingCount == 400)
        #expect(PerfReporter.queueLimit == 400)

        // Drain everything: the survivors are the first 400, in order.
        var seen: [Int] = []
        while await reporter.pendingCount > 0 {
            await reporter.flush()
        }
        for request in await transport.requests {
            seen += try decodeBody(request).compactMap { n($0) }
        }
        #expect(seen == Array(0..<400))
    }

    @Test func flushSendsAtMost300ItemsAndKeepsTheRest() async throws {
        let transport = fixedTransport()
        let reporter = PerfReporter(client: testBaseURL, transport: transport)
        for i in 0..<400 {
            await reporter.mark(PerfItem(type: "t", ms: 1, n: i))
        }
        await reporter.flush()
        #expect(await reporter.pendingCount == 100)
        var requests = await transport.requests
        #expect(requests.count == 1)
        let firstBatch = try decodeBody(requests[0])
        #expect(firstBatch.count == 300)
        #expect(n(firstBatch.first) == 0)
        #expect(n(firstBatch.last) == 299)

        await reporter.flush()
        requests = await transport.requests
        #expect(requests.count == 2)
        let secondBatch = try decodeBody(requests[1])
        #expect(secondBatch.count == 100)
        #expect(n(secondBatch.first) == 300)
        #expect(await reporter.pendingCount == 0)
    }

    @Test func spaceFreesUpAfterAFlush() async {
        let reporter = PerfReporter(client: testBaseURL, transport: fixedTransport())
        for i in 0..<400 { await reporter.mark(PerfItem(type: "t", ms: Double(i))) }
        await reporter.flush()
        await reporter.mark(PerfItem(type: "t", ms: 1))
        #expect(await reporter.pendingCount == 101)
    }

    @Test func aTransportFailureDropsTheBatchSilently() async {
        let transport = FakeTransport { _, _ in throw TestFailure() }
        let reporter = PerfReporter(client: testBaseURL, transport: transport)
        await reporter.mark(PerfItem(type: "t", ms: 1))
        await reporter.mark(PerfItem(type: "t", ms: 2))
        await reporter.flush()
        #expect(await transport.requests.count == 1)
        #expect(await reporter.pendingCount == 0)
        await reporter.flush()
        #expect(await transport.requests.count == 1, "the dropped batch must not be retried")
    }

    @Test func aServerErrorDropsTheBatchToo() async {
        let transport = fixedTransport(status: 500, body: #"{"error":"boom"}"#)
        let reporter = PerfReporter(client: testBaseURL, transport: transport)
        await reporter.mark(PerfItem(type: "t", ms: 1))
        await reporter.flush()
        #expect(await reporter.pendingCount == 0)
        await reporter.flush()
        #expect(await transport.requests.count == 1)
    }

    @Test func marksAfterAFailureStillWork() async throws {
        let transport = FakeTransport { request, index in
            if index == 0 { throw TestFailure() }
            return (Data("{}".utf8), makeResponse(for: request))
        }
        let reporter = PerfReporter(client: testBaseURL, transport: transport)
        await reporter.mark(PerfItem(type: "t", ms: 1, n: 1))
        await reporter.flush()
        await reporter.mark(PerfItem(type: "t", ms: 2, n: 2))
        await reporter.flush()
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(try decodeBody(requests[1]).compactMap { n($0) } == [2])
    }
}
