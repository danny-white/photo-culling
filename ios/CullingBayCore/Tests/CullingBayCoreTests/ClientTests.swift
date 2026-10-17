import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@Suite("Client: caching, errors, decoding")
struct ClientTests {
    // MARK: ETag

    @Test func secondRequestSendsIfNoneMatchAndA304IsServedFromCache() async throws {
        let body = daysResponseJSON([dayFullJSON, dayNullsJSON])
        let transport = FakeTransport { request, index in
            if index == 0 {
                return (Data(body.utf8), makeResponse(
                    for: request, headers: ["ETag": "\"v1\"", "Server-Timing": "total;dur=59.2, cache;desc=\"miss\""]))
            }
            return (Data(), makeResponse(
                for: request, status: 304, headers: ["ETag": "\"v1\"", "Server-Timing": "total;dur=1.5"]))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)

        let first: Fetched<DaysEnvelope> = try await client.fetch(path: "/m/api/days")
        #expect(!first.notModified)
        #expect(first.value.days.count == 2)
        #expect(first.serverTiming?.total == 59.2)

        let second: Fetched<DaysEnvelope> = try await client.fetch(path: "/m/api/days")
        #expect(second.notModified)
        #expect(second.value == first.value)
        #expect(second.serverTiming?.total == 1.5)

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(requests[1].httpMethod == "GET")
    }

    @Test func daysUsesTheCacheTransparently() async throws {
        let transport = FakeTransport { request, index in
            index == 0
                ? (Data(daysResponseJSON([dayFullJSON]).utf8), makeResponse(for: request, headers: ["ETag": "W/\"a\""]))
                : (Data(), makeResponse(for: request, status: 304))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let first = try await client.days()
        let second = try await client.days()
        #expect(first == second)
        #expect(first.count == 1)
        #expect(await transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == "W/\"a\"")
    }

    @Test func aChangedETagReplacesTheCachedBody() async throws {
        let transport = FakeTransport { request, index in
            switch index {
            case 0:
                return (Data(daysResponseJSON([dayFullJSON]).utf8), makeResponse(for: request, headers: ["ETag": "\"v1\""]))
            case 1:
                return (Data(daysResponseJSON([dayFullJSON, dayNullsJSON]).utf8), makeResponse(for: request, headers: ["ETag": "\"v2\""]))
            default:
                return (Data(), makeResponse(for: request, status: 304))
            }
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let first: Fetched<DaysEnvelope> = try await client.fetch(path: "/m/api/days")
        let second: Fetched<DaysEnvelope> = try await client.fetch(path: "/m/api/days")
        let third: Fetched<DaysEnvelope> = try await client.fetch(path: "/m/api/days")
        #expect(first.value.days.count == 1 && !first.notModified)
        #expect(second.value.days.count == 2 && !second.notModified)
        #expect(third.value.days.count == 2 && third.notModified)
        let requests = await transport.requests
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(requests[2].value(forHTTPHeaderField: "If-None-Match") == "\"v2\"")
    }

    @Test func theCacheIsKeyedByFullURL() async throws {
        let transport = FakeTransport { request, _ in
            (Data(#"{"query":"","total":0,"signals":[],"notes":[],"photos":[]}"#.utf8),
             makeResponse(for: request, headers: ["ETag": "\"e\""]))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        _ = try await client.search("owl")
        _ = try await client.search("fox")
        _ = try await client.search("owl", best: true)
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
        _ = try await client.search("owl")
        #expect(await transport.requests[3].value(forHTTPHeaderField: "If-None-Match") == "\"e\"")
    }

    @Test func theETagCacheKeepsOnlyTheNewestResponses() async throws {
        let empty = #"{"query":"q","total":0,"signals":[],"notes":[],"photos":[]}"#
        let transport = FakeTransport { request, _ in
            (Data(empty.utf8), makeResponse(for: request, headers: ["ETag": "\"x\""]))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        for i in 0..<(CullingBayClient.maxCachedResponses + 20) {
            _ = try await client.search("query \(i)")
        }
        #expect(await client.cachedResponseCount == CullingBayClient.maxCachedResponses)
    }

    @Test func aResponseWithoutAnETagDropsTheCacheEntry() async throws {
        let transport = FakeTransport { request, index in
            let headers = index == 0 ? ["ETag": "\"v1\""] : [:]
            return (Data(daysResponseJSON([]).utf8), makeResponse(for: request, headers: headers))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        _ = try await client.days()
        _ = try await client.days()
        _ = try await client.days()
        let requests = await transport.requests
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(requests[2].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func a304WithNothingCachedIsAnError() async throws {
        let client = CullingBayClient(baseURL: testBaseURL, transport: fixedTransport(status: 304, body: ""))
        await #expect(throws: CullingBayError.self) { try await client.days() }
    }

    @Test func requestsAcceptJSONAndBypassTheSystemCache() async throws {
        let transport = fixedTransport(body: daysResponseJSON([]))
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        _ = try await client.days()
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    // MARK: Errors

    @Test func a404WithAJSONErrorGivesHTTPWithMessage() async throws {
        let transport = fixedTransport(status: 404, body: #"{"error":"no such day"}"#)
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        await #expect(throws: CullingBayError.http(status: 404, message: "no such day")) {
            try await client.galleryDay("1999/1999-01-01")
        }
    }

    @Test func statusCodes400And415CarryTheirMessages() async throws {
        for (status, message) in [(400, "missing q"), (415, "cannot decode")] {
            let transport = fixedTransport(status: status, body: #"{"error":"\#(message)"}"#)
            let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
            await #expect(throws: CullingBayError.http(status: status, message: message)) {
                try await client.search("")
            }
        }
    }

    @Test func anErrorWithoutAJSONBodyHasNoMessage() async throws {
        for body in ["", "<html>Bad gateway</html>", #"{"detail":"x"}"#, #"{"error":42}"#] {
            let client = CullingBayClient(
                baseURL: testBaseURL, transport: fixedTransport(status: 502, body: body))
            await #expect(throws: CullingBayError.http(status: 502, message: nil)) {
                try await client.days()
            }
        }
    }

    @Test func invalidJSONGivesDecoding() async throws {
        let client = CullingBayClient(
            baseURL: testBaseURL, transport: fixedTransport(body: "this is not json"))
        do {
            _ = try await client.days()
            Issue.record("expected a throw")
        } catch let error as CullingBayError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test func wellFormedJSONOfTheWrongShapeGivesDecodingNamingTheKey() async throws {
        let client = CullingBayClient(
            baseURL: testBaseURL, transport: fixedTransport(body: #"{"days":[{"day":"x"}]}"#))
        do {
            _ = try await client.days()
            Issue.record("expected a throw")
        } catch let error as CullingBayError {
            guard case .decoding(let message) = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
            #expect(message.contains("folder"))
        }
    }

    @Test func aFailedDecodeDoesNotPoisonTheCache() async throws {
        let transport = FakeTransport { request, index in
            index == 0
                ? (Data("garbage".utf8), makeResponse(for: request, headers: ["ETag": "\"bad\""]))
                : (Data(daysResponseJSON([]).utf8), makeResponse(for: request))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        await #expect(throws: CullingBayError.self) { try await client.days() }
        _ = try await client.days()
        #expect(await transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func transportFailuresBecomeTransportErrors() async throws {
        let transport = FakeTransport { _, _ in throw TestFailure() }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        do {
            _ = try await client.days()
            Issue.record("expected a throw")
        } catch let error as CullingBayError {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
        }
    }

    @Test func aTransportThatThrowsCullingBayErrorPassesItThrough() async throws {
        let transport = FakeTransport { _, _ in throw CullingBayError.transport("offline") }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        await #expect(throws: CullingBayError.transport("offline")) { try await client.days() }
    }

    @Test func errorsAreEquatable() {
        #expect(CullingBayError.http(status: 404, message: "a") == .http(status: 404, message: "a"))
        #expect(CullingBayError.http(status: 404, message: "a") != .http(status: 404, message: nil))
        #expect(CullingBayError.decoding("x") != .transport("x"))
    }

    // MARK: Server-Timing on the result

    @Test func serverTimingIsNilWhenTheHeaderIsMissing() async throws {
        let client = CullingBayClient(baseURL: testBaseURL, transport: fixedTransport(body: daysResponseJSON([])))
        let fetched: Fetched<DaysEnvelope> = try await client.fetch(path: "/m/api/days")
        #expect(fetched.serverTiming == nil)
    }
}

/// The `/m/api/days` envelope, for tests that use the generic `fetch`.
struct DaysEnvelope: Decodable, Sendable, Hashable {
    let days: [Day]
}
