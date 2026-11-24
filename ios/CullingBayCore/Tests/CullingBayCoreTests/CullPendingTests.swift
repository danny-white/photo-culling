import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import Synchronization
import Testing
@testable import CullingBayCore

/// Which decisions are only on the phone: the queue's `pendingFrameIDs`, `pendingByDay` and
/// `isPending(frameID:)`.
@MainActor
@Suite("Cull: taps only on the phone")
struct CullPendingTests {
    let dayA = "2026/2026-10-01"
    let dayB = "2026/2026-10-02"

    private func decide(_ id: String, day: String, frames: [Int]) -> CullWrite {
        .decide(
            actionID: id, day: day, label: "Kept \(id)",
            changes: frames.map { CullChange(id: $0, flag: .pick, via: .card) })
    }

    private func rig() -> CullRig { CullRig(day: cullDay([cullStack(0, .single, [cullFrame(1)])])) }

    private func goOffline(_ rig: CullRig) {
        rig.server.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        rig.server.on("POST /m/api/undo") { _ in throw CullingBayError.transport("offline") }
    }

    @Test func nothingIsPendingOnAnEmptyQueue() {
        let queue = rig().queue
        #expect(queue.pendingFrameIDs.isEmpty)
        #expect(queue.pendingByDay.isEmpty)
        #expect(!queue.isPending(frameID: 1))
    }

    @Test func tapsQueuedOfflineMarkTheirFramesAndDays() async {
        let rig = rig()
        goOffline(rig)
        rig.queue.enqueue(decide("a", day: dayA, frames: [10, 11, 12]))
        rig.queue.enqueue(decide("b", day: dayB, frames: [20]))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        #expect(rig.queue.isOffline)
        #expect(rig.queue.pendingFrameIDs == [10, 11, 12, 20])
        #expect(rig.queue.pendingByDay == [dayA: 3, dayB: 1])
        #expect(rig.queue.isPending(frameID: 11))
        #expect(rig.queue.isPending(frameID: 20))
        #expect(!rig.queue.isPending(frameID: 99))
    }

    @Test func theMarksClearOnceTheServerHasTheTaps() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { count in
            if count == 0 { throw CullingBayError.transport("offline") }
            return Reply()
        }
        rig.queue.enqueue(decide("a", day: dayA, frames: [10, 11]))
        rig.queue.enqueue(decide("b", day: dayB, frames: [20]))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        #expect(rig.queue.pendingByDay == [dayA: 2, dayB: 1])
        await rig.sleeper.release(.seconds(4))
        await rig.settle()
        #expect(rig.queue.pendingFrameIDs.isEmpty)
        #expect(rig.queue.pendingByDay.isEmpty)
        #expect(!rig.queue.isPending(frameID: 10))
    }

    @Test func oneDayClearsWhileTheNextStaysMarked() async {
        let rig = rig()
        let gate = GatedTransport { request, _ in
            (Data(#"{"ok":true}"#.utf8), makeResponse(for: request))
        }
        let queue = CullWriteQueue(
            client: CullingBayClient(baseURL: testBaseURL, transport: gate),
            store: InMemoryCullWriteStore(), sleep: rig.sleeper.sleep)
        queue.enqueue(decide("a", day: dayA, frames: [10]))
        queue.enqueue(decide("b", day: dayB, frames: [20]))
        await gate.waitForRequests(1)
        #expect(queue.pendingByDay == [dayA: 1, dayB: 1])     // a is in flight, still on the phone
        await gate.release(0)
        let expected = [dayB: 1]
        #expect(await eventually { await queue.pendingByDay == expected })
        #expect(queue.pendingFrameIDs == [20])
        await gate.release(1)
        #expect(await eventually { await queue.pendingByDay.isEmpty })
    }

    @Test func aFrameDecidedTwiceCountsOnce() async {
        let rig = rig()
        goOffline(rig)
        rig.queue.enqueue(decide("a", day: dayA, frames: [10, 11]))
        rig.queue.enqueue(decide("b", day: dayA, frames: [11, 12]))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        #expect(rig.queue.pendingByDay == [dayA: 3])
        #expect(rig.queue.pendingFrameIDs == [10, 11, 12])
    }

    @Test func aQueuedUndoOfAQueuedDecideStaysOnThatDecidesDay() async {
        let rig = rig()
        goOffline(rig)
        rig.queue.enqueue(decide("a", day: dayA, frames: [10, 11]))
        rig.queue.enqueue(decide("b", day: dayB, frames: [20]))
        rig.queue.enqueue(.undo(actionID: "a"))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        #expect(rig.queue.pending == 3)
        #expect(rig.queue.pendingByDay == [dayA: 2, dayB: 1])
        #expect(rig.queue.pendingFrameIDs == [10, 11, 20])
    }

    @Test func anUndoWhoseDecideWasAlreadySavedIsIgnored() async {
        let rig = rig()
        rig.server.on("POST /m/api/undo") { _ in throw CullingBayError.transport("offline") }
        rig.queue.enqueue(decide("a", day: dayA, frames: [10]))
        await rig.settle()                                     // the decide was saved
        rig.queue.enqueue(.undo(actionID: "a"))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        #expect(rig.queue.pending == 1)
        #expect(rig.queue.pendingByDay.isEmpty)
        #expect(rig.queue.pendingFrameIDs.isEmpty)
    }

    @Test func progressWritesAreNotTaps() async {
        let rig = rig()
        rig.server.on("PUT progress") { _ in throw CullingBayError.transport("offline") }
        rig.queue.enqueue(.progress(day: dayA, pass: 2, cursor: 3, finished: false, lead: nil))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        #expect(rig.queue.pending == 1)
        #expect(rig.queue.pendingByDay.isEmpty)
        #expect(rig.queue.pendingFrameIDs.isEmpty)
    }

    @Test func tapsLeftOnDiskByAnEarlierRunCountAtOnce() {
        let store = InMemoryCullWriteStore(writes: [
            decide("a", day: dayA, frames: [10, 11]),
            decide("b", day: dayB, frames: [20]),
            .undo(actionID: "b"),
        ])
        let queue = CullWriteQueue(
            client: CullingBayClient(baseURL: testBaseURL, transport: fixedTransport()),
            store: store, sleep: ManualSleeper().sleep)
        // Nothing has been started or sent: the marks are there from the first frame of the app.
        #expect(queue.pendingByDay == [dayA: 2, dayB: 1])
        #expect(queue.pendingFrameIDs == [10, 11, 20])
        #expect(queue.isPending(frameID: 10))
    }

    @Test func aViewWatchingThemIsToldWhenTheyChange() async {
        let rig = rig()
        rig.server.on("POST /m/api/decide") { count in
            if count == 0 { throw CullingBayError.transport("offline") }
            return Reply()
        }
        let queue = rig.queue

        let enqueued = Changed()
        withObservationTracking {
            _ = queue.pendingByDay
            _ = queue.pendingFrameIDs
            _ = queue.isPending(frameID: 10)
        } onChange: { enqueued.set() }
        queue.enqueue(decide("a", day: dayA, frames: [10]))
        #expect(enqueued.isSet)                                // told when a tap is queued

        #expect(await rig.sleeper.waitFor(.seconds(4)))
        let saved = Changed()
        withObservationTracking {
            _ = queue.pendingByDay
            _ = queue.pendingFrameIDs
            _ = queue.isPending(frameID: 10)
        } onChange: { saved.set() }
        await rig.sleeper.release(.seconds(4))
        #expect(await eventually { saved.isSet })              // and when the server has it
        await rig.settle()
        #expect(queue.pendingByDay.isEmpty)
    }
}

/// Set from an observation callback, which can run on any thread.
final class Changed: Sendable {
    private let flag = Mutex(false)
    func set() { flag.withLock { $0 = true } }
    var isSet: Bool { flag.withLock { $0 } }

    // MARK: A day reopened before its taps are saved

    @MainActor @Test func aDayReopenedOfflineShowsItsQueuedTapsAndPosition() async {
        let day = cullDay((0..<4).map { cullStack($0, .single, [cullFrame(100 + $0, file: "S\(100 + $0).ARW")]) })
        let rig = CullRig(day: day)
        rig.server.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        rig.server.on("PUT progress") { _ in throw CullingBayError.transport("offline") }
        let first = rig.session()
        await first.load()
        first.keep()                                   // 100 kept, on to 101
        first.reject()                                 // 101 rejected, on to 102
        #expect(await rig.sleeper.waitFor(CullSessionModel.progressDelay))   // the position, saved after a pause
        await rig.sleeper.release(CullSessionModel.progressDelay)
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.queue.pendingFrameIDs == [100, 101])
        // the same day opened again: the server (or the phone's copy) has none of it
        let again = rig.session()
        await again.load()
        #expect(again.decisions[100]?.flag == .pick && again.decisions[100]?.state == .draft)
        #expect(again.decisions[101]?.flag == .reject)
        #expect(again.cursor == 2)                     // where the queued position left it
    }

    @MainActor @Test func aQueuedUndoTakesBackItsDecideOnReopening() async {
        let day = cullDay((0..<3).map { cullStack($0, .single, [cullFrame(100 + $0, file: "S\(100 + $0).ARW")]) })
        let rig = CullRig(day: day)
        rig.server.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        rig.server.on("POST /m/api/undo") { _ in throw CullingBayError.transport("offline") }
        let first = rig.session()
        await first.load()
        first.keep()
        first.undo()
        let again = rig.session()
        await again.load()
        #expect(again.decisions[100] == nil)
    }
}
