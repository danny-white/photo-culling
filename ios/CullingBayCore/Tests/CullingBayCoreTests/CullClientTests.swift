import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@Suite("Client: Cull routes")
struct CullClientTests {
    let day = "2026/2026-10-01"

    private func client(
        status: Int = 200, body: String = #"{"ok":true}"#, headers: [String: String] = [:]
    ) -> (CullingBayClient, FakeTransport) {
        let transport = fixedTransport(status: status, body: body, headers: headers)
        return (CullingBayClient(baseURL: testBaseURL, transport: transport), transport)
    }

    // MARK: Reads

    @Test func cullDayGetsTheDayRouteAndDecodes() async throws {
        let (client, transport) = client(body: cullDayJSON, headers: ["ETag": "\"d1\""])
        let loaded = try await client.cullDay(day)
        #expect(loaded.stacks.count == 3)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "http://100.82.57.4:8000/m/api/day/2026/2026-10-01")
        #expect(request.value(forHTTPHeaderField: "X-Culling-Bay") == nil)
    }

    @Test func cullDayIsRevalidatedWithItsETag() async throws {
        let transport = FakeTransport { request, index in
            index == 0
                ? (Data(cullDayJSON.utf8), makeResponse(for: request, headers: ["ETag": "\"d1\""]))
                : (Data(), makeResponse(for: request, status: 304))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let first = try await client.cullDay(day)
        let second = try await client.cullDay(day)
        #expect(first == second)
        #expect(await transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"d1\"")
    }

    @Test func daySearchSendsTheQueryEncoded() async throws {
        let (client, transport) = client(body: daySearchJSON)
        let result = try await client.daySearch("c++ & fish")
        #expect(result.days.count == 2)
        let url = try #require(await transport.requests.first?.url)
        #expect(url.path == "/m/api/search")
        #expect(url.query == "q=c%2B%2B%20%26%20fish")
    }

    @Test func dayLikeUsesTheLikeRoute() async throws {
        let (client, transport) = client(body: dayLikeJSON)
        let result = try await client.dayLike(43203)
        #expect(result.query == nil)
        #expect(await transport.requests.first?.url?.path == "/m/api/like/43203")
    }

    @Test func aMissingDayIsA404WithTheServersMessage() async throws {
        let (client, _) = client(status: 404, body: #"{"error":"no such day"}"#)
        await #expect(throws: CullingBayError.http(status: 404, message: "no such day")) {
            try await client.cullDay("1999/1999-01-01")
        }
    }

    // MARK: Request building

    @Test func decideSendsAPostWithTheGuardHeaderAndTheChanges() async throws {
        let (client, transport) = client()
        let changes = [
            CullChange(id: 43207, flag: .pick, stars: 4, via: .card),
            CullChange(id: 43224, flag: .reject, note: "Burst reject \u{00B7} kept DSC05037", via: .burst),
        ]
        let ack = try await client.decide(
            actionID: "A-1", day: day, label: "Kept DSC05037 \u{2605} 4", changes: changes)
        #expect(ack == CullAck(ok: true, replay: false))

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://100.82.57.4:8000/m/api/decide")
        #expect(request.value(forHTTPHeaderField: "X-Culling-Bay") == "1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
        let body = try jsonBody(request)
        #expect(Set(body.keys) == ["action_id", "day", "label", "changes"])
        #expect(body["action_id"] as? String == "A-1")
        #expect(body["day"] as? String == day)
        #expect(body["label"] as? String == "Kept DSC05037 \u{2605} 4")
        let sent = try #require(body["changes"] as? [[String: Any]])
        #expect(sent.count == 2)
        #expect(sent[0]["id"] as? Int == 43207)
        #expect(sent[0]["flag"] as? String == "pick")
        #expect(sent[0]["stars"] as? Int == 4)
        #expect(sent[0]["via"] as? String == "card")
        #expect(sent[0]["note"] == nil)
        #expect(sent[1]["flag"] as? String == "reject")
        #expect(sent[1]["stars"] == nil)
        #expect(sent[1]["note"] as? String == "Burst reject \u{00B7} kept DSC05037")
        #expect(sent[1]["via"] as? String == "burst")
    }

    @Test func clearingAFlagSendsNone() async throws {
        let (client, transport) = client()
        try await client.decide(
            actionID: "A-2", day: day, changes: [CullChange(id: 1, flag: .clear, via: .rescue)])
        let request = try #require(await transport.requests.first)
        let sent = try #require(try jsonBody(request)["changes"] as? [[String: Any]])
        #expect(sent[0]["flag"] as? String == "none")
        #expect(sent[0]["via"] as? String == "rescue")
    }

    @Test func decideWithoutAnIdMakesOneAndReturnsIt() async throws {
        let (client, transport) = client()
        let changes = [CullChange(id: 1, flag: .pick, via: .card)]
        let first = try await client.decide(day: day, changes: changes)
        let second = try await client.decide(day: day, changes: changes)
        #expect(first.actionID != second.actionID)
        #expect(UUID(uuidString: first.actionID) != nil)
        #expect(!first.ack.replay)
        let requests = await transport.requests
        #expect(try jsonBody(requests[0])["action_id"] as? String == first.actionID)
        #expect(try jsonBody(requests[1])["action_id"] as? String == second.actionID)
        #expect(try jsonBody(requests[0])["label"] as? String == "")
    }

    @Test func aRetryWithTheSameIdSendsTheSameBodyAndReadsTheReplay() async throws {
        let transport = FakeTransport { request, index in
            (Data((index == 0 ? #"{"ok":true}"# : #"{"ok":true,"replay":true}"#).utf8), makeResponse(for: request))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let changes = [CullChange(id: 1, flag: .pick, via: .card)]
        let first = try await client.decide(actionID: "same", day: day, changes: changes)
        let retry = try await client.decide(actionID: "same", day: day, changes: changes)
        #expect(!first.replay)
        #expect(retry.replay)
        let requests = await transport.requests
        #expect(requests[0].httpBody == requests[1].httpBody)
    }

    @Test func undoPostsTheActionId() async throws {
        let (client, transport) = client(body: #"{"ok":true,"replay":true}"#)
        let ack = try await client.undo(actionID: "A-1")
        #expect(ack.replay)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/m/api/undo")
        #expect(request.value(forHTTPHeaderField: "X-Culling-Bay") == "1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try jsonBody(request)
        #expect(body.count == 1)
        #expect(body["action_id"] as? String == "A-1")
    }

    @Test func saveProgressPutsPassCursorAndFinished() async throws {
        let (client, transport) = client()
        try await client.saveProgress(day: day, pass: 2, cursor: 7)
        try await client.saveProgress(day: day, pass: 2, cursor: 15, finished: true)
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.httpMethod == "PUT" })
        #expect(requests.allSatisfy { $0.url?.path == "/m/api/day/2026/2026-10-01/progress" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Culling-Bay") == "1" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/json" })
        let first = try jsonBody(requests[0])
        #expect(first["pass"] as? Int == 2)
        #expect(first["cursor"] as? Int == 7)
        #expect(first["finished"] as? Bool == false)
        #expect(first["lead"] == nil)
        #expect(try jsonBody(requests[1])["finished"] as? Bool == true)
    }

    @Test func saveProgressSendsTheLeadFrameWhenGiven() async throws {
        let (client, transport) = client()
        try await client.saveProgress(day: day, pass: 2, cursor: 7, lead: 43224)
        let request = try #require(await transport.requests.first)
        let body = try jsonBody(request)
        #expect(Set(body.keys) == ["pass", "cursor", "finished", "lead"])
        #expect(body["lead"] as? Int == 43224)
        #expect(body["cursor"] as? Int == 7)
    }

    @Test func sendPostsAnEmptyObjectAndReadsTheCounts() async throws {
        let (client, transport) = client(body: #"{"ok":true,"queued":2,"file_rows":3}"#)
        let result = try await client.send(day: day)
        #expect(result == SendResult(queued: 2, fileRows: 3))
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/m/api/day/2026/2026-10-01/send")
        #expect(request.value(forHTTPHeaderField: "X-Culling-Bay") == "1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try jsonBody(request).isEmpty)
    }

    @Test func resetPostsAnEmptyObjectAndReadsTheCounts() async throws {
        let (client, transport) = client(body: #"{"ok":true,"cleared":5,"withdrawn":6}"#)
        let result = try await client.reset(day: day)
        #expect(result == ResetResult(cleared: 5, withdrawn: 6))
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/m/api/day/2026/2026-10-01/reset")
        #expect(request.value(forHTTPHeaderField: "X-Culling-Bay") == "1")
        #expect(try jsonBody(request).isEmpty)
    }

    @Test func writesBypassTheSystemCache() async throws {
        let (client, transport) = client()
        try await client.saveProgress(day: day, pass: 2, cursor: 0)
        let request = try #require(await transport.requests.first)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    // MARK: Errors

    @Test func aMissingHeaderOrBadBodyKeepsTheServersMessage() async throws {
        for (status, message) in [
            (403, "missing X-Culling-Bay header or JSON body"),
            (400, "action_id, day and changes are required"),
            (404, "unknown action"),
        ] {
            let (client, _) = client(status: status, body: #"{"error":"\#(message)"}"#)
            await #expect(throws: CullingBayError.http(status: status, message: message)) {
                try await client.undo(actionID: "x")
            }
        }
    }

    @Test func a409OnResetCarriesTheMessageAndTheAppliedCount() async throws {
        let body = #"{"error":"2 decision(s) from this day are already in Lightroom; change those there","applied":2}"#
        let (client, _) = client(status: 409, body: body)
        await #expect(throws: CullingBayError.conflict(
            message: "2 decision(s) from this day are already in Lightroom; change those there", applied: 2)
        ) { try await client.reset(day: day) }
    }

    @Test func a409WithoutDetailsStillMapsToConflict() async throws {
        let (client, _) = client(status: 409, body: "")
        await #expect(throws: CullingBayError.conflict(message: nil, applied: nil)) {
            try await client.reset(day: day)
        }
    }

    @Test func a503MeansTheInboxIsUnavailable() async throws {
        let message = "/mnt/Passport_AICullInbox is not mounted; nothing was sent"
        for call in 0..<2 {
            let (client, _) = client(status: 503, body: #"{"error":"\#(message)"}"#)
            await #expect(throws: CullingBayError.unavailable(message: message)) {
                if call == 0 { _ = try await client.send(day: day) } else { _ = try await client.reset(day: day) }
            }
        }
    }

    @Test func aServerErrorOnADecideIsHTTP() async throws {
        let (client, _) = client(status: 500, body: "<html>oops</html>")
        await #expect(throws: CullingBayError.http(status: 500, message: nil)) {
            try await client.decide(actionID: "x", day: day, changes: [CullChange(id: 1, flag: .pick, via: .card)])
        }
    }

    @Test func aDroppedConnectionIsATransportErrorAndASentRequestWasStillBuilt() async throws {
        let transport = FakeTransport { _, _ in throw TestFailure() }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        do {
            try await client.saveProgress(day: day, pass: 2, cursor: 1)
            Issue.record("expected a throw")
        } catch let error as CullingBayError {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func anAnswerOfTheWrongShapeIsADecodingError() async throws {
        let (client, _) = client(body: #"{"queued":"two"}"#)
        do {
            _ = try await client.send(day: day)
            Issue.record("expected a throw")
        } catch let error as CullingBayError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    // MARK: Cache

    /// Serves cull days with a tag, and answers 304 to any request that offers that tag. Writes
    /// always answer `{"ok":true}`.
    private func taggedTransport() -> FakeTransport {
        FakeTransport { request, _ in
            if request.httpMethod != "GET" {
                return (Data(#"{"ok":true,"queued":0,"file_rows":0,"cleared":0,"withdrawn":0}"#.utf8), makeResponse(for: request))
            }
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"t\"" {
                return (Data(), makeResponse(for: request, status: 304))
            }
            let body = request.url?.path == "/m/api/days" ? daysResponseJSON([]) : cullDayJSON
            return (Data(body.utf8), makeResponse(for: request, headers: ["ETag": "\"t\""]))
        }
    }

    private func lastGet(_ transport: FakeTransport) async -> URLRequest? {
        await transport.requests.last { $0.httpMethod == "GET" }
    }

    @Test func aWriteForADayDropsThatDaysCachedETag() async throws {
        let transport = taggedTransport()
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        _ = try await client.cullDay(day)
        _ = try await client.cullDay("2026/2026-09-30")
        _ = try await client.cullDay(day)
        #expect(await lastGet(transport)?.value(forHTTPHeaderField: "If-None-Match") == "\"t\"")

        try await client.decide(actionID: "A", day: day, changes: [CullChange(id: 1, flag: .pick, via: .card)])
        _ = try await client.cullDay(day)
        #expect(await lastGet(transport)?.value(forHTTPHeaderField: "If-None-Match") == nil)
        // another day's tag is still there
        _ = try await client.cullDay("2026/2026-09-30")
        #expect(await lastGet(transport)?.value(forHTTPHeaderField: "If-None-Match") == "\"t\"")
    }

    @Test func everyDayWriteDropsTheDaysETag() async throws {
        let writes: [(String, @Sendable (CullingBayClient, String) async throws -> Void)] = [
            ("progress", { c, d in try await c.saveProgress(day: d, pass: 2, cursor: 1) }),
            ("send", { c, d in _ = try await c.send(day: d) }),
            ("reset", { c, d in _ = try await c.reset(day: d) }),
        ]
        for (name, write) in writes {
            let transport = taggedTransport()
            let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
            _ = try await client.cullDay(day)
            try await write(client, day)
            _ = try await client.cullDay(day)
            #expect(await lastGet(transport)?.value(forHTTPHeaderField: "If-None-Match") == nil, "after \(name)")
        }
    }

    @Test func undoDropsEveryCachedCullDayButNotTheDaysListOrTheGallery() async throws {
        let transport = taggedTransport()
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        _ = try await client.cullDay(day)
        _ = try await client.cullDay("2026/2026-09-30")
        _ = try await client.days()
        #expect(await client.cachedResponseCount == 3)
        try await client.undo(actionID: "A")
        #expect(await client.cachedResponseCount == 1)
        _ = try await client.days()
        #expect(await lastGet(transport)?.value(forHTTPHeaderField: "If-None-Match") == "\"t\"")
        _ = try await client.cullDay(day)
        #expect(await lastGet(transport)?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func aFailedWriteLeavesTheCacheAlone() async throws {
        let transport = FakeTransport { request, _ in
            request.httpMethod == "GET"
                ? (Data(cullDayJSON.utf8), makeResponse(for: request, headers: ["ETag": "\"t\""]))
                : (Data(#"{"error":"nope"}"#.utf8), makeResponse(for: request, status: 409))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        _ = try await client.cullDay(day)
        await #expect(throws: CullingBayError.self) { try await client.reset(day: day) }
        #expect(await client.cachedResponseCount == 1)
    }

    @Test func writesAreNeverStoredInTheCache() async throws {
        let transport = FakeTransport { request, _ in
            (Data(#"{"ok":true}"#.utf8), makeResponse(for: request, headers: ["ETag": "\"w\""]))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        try await client.saveProgress(day: day, pass: 2, cursor: 1)
        try await client.undo(actionID: "A")
        #expect(await client.cachedResponseCount == 0)
    }
}
