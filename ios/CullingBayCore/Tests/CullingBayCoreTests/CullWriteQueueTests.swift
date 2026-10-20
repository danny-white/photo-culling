import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Cull: write queue")
struct CullWriteQueueTests {
    let day = "2026/2026-10-01"

    private func decide(_ id: String, frame: Int = 1) -> CullWrite {
        .decide(actionID: id, day: day, label: "Kept \(id)", changes: [CullChange(id: frame, flag: .pick, via: .card)])
    }

    private func progress(_ cursor: Int, finished: Bool = false, lead: Int? = nil) -> CullWrite {
        .progress(day: day, pass: 2, cursor: cursor, finished: finished, lead: lead)
    }

    private func rig() -> CullRig { CullRig(day: cullDay([cullStack(0, .single, [cullFrame(1)])])) }

    // MARK: Order

    @Test func writesGoOutInTheOrderTheyWereQueued() async {
        let rig = rig()
        rig.queue.enqueue(decide("a"))
        rig.queue.enqueue(.undo(actionID: "a"))
        rig.queue.enqueue(progress(3, lead: 77))
        rig.queue.enqueue(decide("b"))
        await rig.settle()
        let calls = rig.server.allCalls
        #expect(calls.map(\.path) == [
            "/m/api/decide", "/m/api/undo", "/m/api/day/2026/2026-10-01/progress", "/m/api/decide",
        ])
        #expect(calls[0].json["action_id"] as? String == "a")
        #expect(calls[1].json["action_id"] as? String == "a")
        #expect(calls[2].json["cursor"] as? Int == 3)
        #expect(calls[2].json["lead"] as? Int == 77)
        #expect(calls[3].json["action_id"] as? String == "b")
        #expect(!rig.queue.isOffline)
    }

    @Test func oneWriteIsInFlightAtATime() async {
        let transport = GatedTransport { request, _ in jsonResponse(#"{"ok":true}"#, for: request) }
        let queue = CullWriteQueue(
            client: CullingBayClient(baseURL: testBaseURL, transport: transport),
            store: InMemoryCullWriteStore(), sleep: ManualSleeper().sleep)
        queue.enqueue(decide("a"))
        queue.enqueue(decide("b"))
        await transport.waitForRequests(1)
        #expect(queue.pending == 2)
        for _ in 0..<50 { await Task.yield() }
        #expect(await transport.requests.count == 1)       // b waits for a
        await transport.release(0)
        await transport.waitForRequests(2)
        #expect(queue.pending == 1)                        // a is out; b is in flight
        await transport.release(1)
        #expect(await eventually { await queue.pending == 0 })
    }

    // MARK: Retry

    @Test func aServerErrorKeepsTheWriteAndRetriesAfterFourSeconds() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { count in count == 0 ? Reply(status: 500, body: #"{"error":"boom"}"#) : Reply() }
        rig.queue.enqueue(decide("a"))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        #expect(rig.queue.isOffline)
        #expect(rig.queue.pending == 1)
        #expect(rig.queue.lastDrop == nil)
        #expect(rig.server.calls("/m/api/decide").count == 1)
        await rig.sleeper.release(.seconds(4))
        await rig.settle()
        #expect(!rig.queue.isOffline)
        let sent = rig.server.calls("/m/api/decide")
        #expect(sent.count == 2)
        #expect(sent[0].body == sent[1].body)              // replayed exactly, action_id and all
    }

    @Test func noConnectionAndAnUnreachableInboxRetryToo() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { count in
            switch count {
            case 0: throw CullingBayError.transport("offline")
            case 1: Reply(status: 503, body: #"{"error":"inbox not mounted"}"#)
            default: Reply()
            }
        }
        rig.queue.enqueue(decide("a"))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        await rig.sleeper.release(.seconds(4))
        #expect(await rig.sleeper.waitFor(.seconds(4), count: 1))
        #expect(rig.queue.isOffline && rig.queue.pending == 1)
        await rig.sleeper.release(.seconds(4))
        await rig.settle()
        #expect(rig.server.calls("/m/api/decide").count == 3)
        #expect(rig.queue.lastDrop == nil)
    }

    @Test func resumeRetriesAtOnceWithoutWaiting() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { count in
            if count == 0 { throw CullingBayError.transport("offline") }
            return Reply()
        }
        rig.queue.enqueue(decide("a"))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        rig.queue.resume()
        await rig.settle()
        #expect(rig.server.calls("/m/api/decide").count == 2)
        #expect(await eventually { await rig.sleeper.waiting.isEmpty })   // the 4 s wait was cancelled
    }

    @Test func aNewTapTriesAtOnceToo() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { count in
            if count == 0 { throw CullingBayError.transport("offline") }
            return Reply()
        }
        rig.queue.enqueue(decide("a"))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        rig.queue.enqueue(decide("b"))
        await rig.settle()
        #expect(rig.server.calls("/m/api/decide").compactMap { $0.json["action_id"] as? String } == ["a", "a", "b"])
    }

    @Test func theBannerCountsWhatIsWaiting() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        rig.queue.enqueue(decide("a"))
        rig.queue.enqueue(decide("b"))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        #expect(rig.queue.isOffline)
        #expect(rig.queue.pending == 2)
    }

    // MARK: Drop

    @Test func aClientErrorDropsTheWriteAndSaysWhy() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { count in
            count == 0 ? Reply(status: 400, body: #"{"error":"unknown frame"}"#) : Reply()
        }
        rig.queue.enqueue(decide("a"))
        rig.queue.enqueue(decide("b"))
        await rig.settle()
        let drop = rig.queue.lastDrop
        #expect(drop?.message == "Not saved: unknown frame")
        #expect(drop?.write == decide("a"))
        #expect(rig.server.calls("/m/api/decide").count == 2)   // b still went, a was not retried
        #expect(!rig.queue.isOffline)
        #expect(await rig.sleeper.waiting.isEmpty)
    }

    @Test func anUndoTheServerRefusesWith409IsDroppedWithItsMessage() async {
        let rig = rig()
        rig.server.on("POST /m/api/undo") { _ in
            Reply(status: 409, body: #"{"error":"already in Lightroom","applied":2}"#)
        }
        rig.queue.enqueue(.undo(actionID: "a"))
        await rig.settle()
        #expect(rig.queue.lastDrop?.message == "Not saved: already in Lightroom")
        #expect(rig.queue.lastDrop?.error == .conflict(message: "already in Lightroom", applied: 2))
    }

    @Test func anUnknownDayIsA404AndDropped() async {
        let rig = rig()
        rig.server.on("PUT progress") { _ in Reply(status: 404, body: #"{"error":"no such day"}"#) }
        rig.queue.enqueue(progress(0))
        await rig.settle()
        #expect(rig.queue.lastDrop?.message == "Not saved: no such day")
        #expect(rig.queue.lastDrop?.id == 1)
    }

    @Test func aRefusalWithoutTextSaysTheStatus() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { _ in Reply(status: 403, body: "") }
        rig.queue.enqueue(decide("a"))
        await rig.settle()
        #expect(rig.queue.lastDrop?.message == "Not saved: HTTP 403")
    }

    @Test func anAnswerThatCannotBeReadStillCountsAsSaved() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { _ in Reply(status: 200, body: "<html>") }
        rig.queue.enqueue(decide("a"))
        await rig.settle()
        #expect(rig.queue.lastDrop == nil)
        #expect(rig.server.calls("/m/api/decide").count == 1)
    }

    @Test func observersHearAboutDropsUntilTheyStopOrGoAway() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { _ in Reply(status: 400, body: #"{"error":"no"}"#) }
        final class Owner {}
        let heard = Heard()
        var owner: Owner? = Owner()
        rig.queue.observeDrops(owner!) { heard.messages.append($0.message) }
        let other = Owner()
        rig.queue.observeDrops(other) { heard.others.append($0.message) }
        rig.queue.enqueue(decide("a"))
        await rig.settle()
        #expect(heard.messages == ["Not saved: no"] && heard.others == ["Not saved: no"])
        rig.queue.stopObservingDrops(other)
        owner = nil
        rig.queue.enqueue(decide("b"))
        await rig.settle()
        #expect(heard.messages.count == 1 && heard.others.count == 1)
        _ = other
    }

    // MARK: Persistence

    @Test func whatIsWaitingSurvivesANewQueue() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        rig.queue.enqueue(decide("a"))
        rig.queue.enqueue(.undo(actionID: "a"))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        #expect(rig.store.writes == [decide("a"), .undo(actionID: "a")])

        // a relaunch: a new queue on the same store, and a server that is back
        let back = CullServer(day: cullDay([]))
        let queue = CullWriteQueue(
            client: CullingBayClient(baseURL: testBaseURL, transport: back.transport()),
            store: rig.store, sleep: ManualSleeper().sleep)
        #expect(queue.pending == 2)
        queue.start()
        #expect(await eventually { await queue.pending == 0 })
        #expect(back.allCalls.map(\.path) == ["/m/api/decide", "/m/api/undo"])
        #expect(back.allCalls[0].json["action_id"] as? String == "a")
        #expect(rig.store.writes.isEmpty)
    }

    @Test func newWritesGoAfterTheOnesFromBefore() async {
        let store = InMemoryCullWriteStore(writes: [decide("old")])
        let server = CullServer(day: cullDay([]))
        let queue = CullWriteQueue(
            client: CullingBayClient(baseURL: testBaseURL, transport: server.transport()),
            store: store, sleep: ManualSleeper().sleep)
        queue.enqueue(decide("new"))
        #expect(await eventually { await queue.pending == 0 })
        #expect(server.calls("/m/api/decide").compactMap { $0.json["action_id"] as? String } == ["old", "new"])
    }

    @Test func theFileStoreKeepsEveryFieldOfAWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cull-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes: [CullWrite] = [
            .decide(actionID: "A-1", day: day, label: "Kept DSC05050 ★3 · 1 rejected with a note", changes: [
                CullChange(id: 5, flag: .pick, stars: 3, note: "", via: .card),
                CullChange(id: 6, flag: .reject, note: "Burst reject · kept DSC05050", via: .burst),
                CullChange(id: 7, flag: .clear, via: .rescue),
            ]),
            .undo(actionID: "A-1"),
            .progress(day: day, pass: 2, cursor: 9, finished: true, lead: 43224),
            .progress(day: day, pass: 2, cursor: 0, finished: false, lead: nil),
        ]
        let store = FileCullWriteStore(directory: directory)
        #expect(store.load().isEmpty)                    // no file yet
        store.save(writes)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(FileCullWriteStore(directory: directory).load() == writes)
        store.save([])
        #expect(FileCullWriteStore(directory: directory).load().isEmpty)
    }

    @Test func aFileThatCannotBeReadIsAnEmptyQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cull-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileCullWriteStore(directory: directory)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load().isEmpty)
    }

    @Test func aFileBackedQueueSurvivesARelaunch() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cull-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let offline = CullServer(day: cullDay([]))
        offline.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        let sleeper = ManualSleeper()
        let first = CullWriteQueue(
            client: CullingBayClient(baseURL: testBaseURL, transport: offline.transport()),
            store: FileCullWriteStore(directory: directory), sleep: sleeper.sleep)
        first.enqueue(decide("a"))
        #expect(await sleeper.waitFor(.seconds(4)))

        let online = CullServer(day: cullDay([]))
        let second = CullWriteQueue(
            client: CullingBayClient(baseURL: testBaseURL, transport: online.transport()),
            store: FileCullWriteStore(directory: directory), sleep: ManualSleeper().sleep)
        #expect(second.pending == 1)
        second.start()
        #expect(await eventually { await second.pending == 0 })
        #expect(online.calls("/m/api/decide").first?.json["action_id"] as? String == "a")
    }

    // MARK: Drain

    @Test func drainReturnsAtOnceWhenNothingIsWaiting() async {
        let rig = rig()
        #expect(await rig.queue.drain(timeout: .seconds(10)))
        #expect(await rig.sleeper.requested.isEmpty)
    }

    @Test func drainWaitsForTheQueueToEmpty() async {
        let transport = GatedTransport { request, _ in jsonResponse(#"{"ok":true}"#, for: request) }
        let sleeper = ManualSleeper()
        let queue = CullWriteQueue(
            client: CullingBayClient(baseURL: testBaseURL, transport: transport),
            store: InMemoryCullWriteStore(), sleep: sleeper.sleep)
        queue.enqueue(decide("a"))
        await transport.waitForRequests(1)
        let drained = Flag()
        let waiter = Task { drained.value = await queue.drain(timeout: .seconds(10)) }
        #expect(await sleeper.waitFor(.seconds(10)))
        #expect(drained.value == nil)
        await transport.release(0)
        await waiter.value
        #expect(drained.value == true)
    }

    @Test func drainGivesUpAfterTheTimeoutWhileOffline() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        rig.queue.enqueue(decide("a"))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        let result = Flag()
        let waiter = Task { result.value = await rig.queue.drain(timeout: .seconds(10)) }
        #expect(await rig.sleeper.waitFor(.seconds(10)))
        await rig.sleeper.release(.seconds(10))
        await waiter.value
        #expect(result.value == false)
        #expect(rig.queue.pending == 1)                    // still there, and still trying
        #expect(rig.queue.isOffline)
    }
}

/// Collects what a callback hears, on the main actor.
@MainActor
final class Heard {
    var messages: [String] = []
    var others: [String] = []
}

/// A value a task sets once.
@MainActor
final class Flag {
    var value: Bool?
}
