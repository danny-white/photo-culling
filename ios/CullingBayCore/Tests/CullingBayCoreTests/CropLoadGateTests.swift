import Foundation
import Synchronization
import Testing
@testable import CullingBayCore

/// Work that stays running until the test lets it go.
private actor Latch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

@Suite("Crops: the load gate")
struct CropLoadGateTests {
    private final class Tally: Sendable {
        private struct State { var running = 0; var peak = 0; var order: [Int] = [] }
        private let state = Mutex(State())

        func enter(_ id: Int) {
            state.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running); $0.order.append(id) }
        }
        func leave() { state.withLock { $0.running -= 1 } }
        var peak: Int { state.withLock { $0.peak } }
        var order: [Int] { state.withLock { $0.order } }
    }

    @Test func atMostTheLimitRunAtOnceAndEveryoneGetsATurn() async throws {
        let gate = CropLoadGate(limit: 2)
        let tally = Tally()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for id in 0..<8 {
                group.addTask {
                    try await gate.run {
                        tally.enter(id)
                        defer { tally.leave() }
                        try await Task.sleep(for: .milliseconds(10))
                        return id
                    }
                }
            }
            var done: [Int] = []
            for try await id in group { done.append(id) }
            return done
        }
        #expect(results.sorted() == Array(0..<8))
        #expect(tally.peak == 2)
        #expect(await gate.activeCount == 0)
        #expect(await gate.waitingCount == 0)
    }

    @Test func aLimitBelowOneIsOne() async throws {
        let gate = CropLoadGate(limit: 0)
        #expect(gate.limit == 1)
    }

    @Test func urgentWorkJumpsTheLineButNotTheRunningWork() async throws {
        let gate = CropLoadGate(limit: 1)
        let tally = Tally()
        let hold = Latch()
        let first = Task { try await gate.run { tally.enter(0); await hold.wait(); tally.leave() } }
        #expect(await eventually { await gate.activeCount == 1 })
        var queued: [Task<Void, any Error>] = []
        for (id, urgent) in [(1, false), (2, false), (3, true), (4, true)] {
            queued.append(Task { try await gate.run(urgent: urgent) { tally.enter(id); tally.leave() } })
            let expected = queued.count
            #expect(await eventually { await gate.waitingCount == expected })
        }
        await hold.release()
        try await first.value
        for task in queued { try await task.value }
        #expect(tally.order == [0, 3, 4, 1, 2])                           // the urgent two first, each in its turn
        #expect(tally.peak == 1)
    }

    @Test func aCancelledWaiterLeavesTheLineWithoutRunning() async throws {
        let gate = CropLoadGate(limit: 1)
        let tally = Tally()
        let hold = Latch()
        let running = Task { try await gate.run { tally.enter(0); await hold.wait(); tally.leave() } }
        #expect(await eventually { await gate.activeCount == 1 })
        let waiter = Task { try await gate.run { tally.enter(1); tally.leave() } }
        #expect(await eventually { await gate.waitingCount == 1 })
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await gate.waitingCount == 0)
        await hold.release()
        try await running.value
        #expect(tally.order == [0])                                        // the cancelled one never ran
        #expect(await gate.activeCount == 0)
    }

    @Test func aCallerCancelledBeforeItStartsNeverRuns() async throws {
        let gate = CropLoadGate(limit: 2)
        let tally = Tally()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await gate.run { tally.enter(1); tally.leave() }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(tally.order.isEmpty)
        #expect(await gate.activeCount == 0)
    }

    @Test func aCancelledRunningCropFreesItsPlaceForTheNext() async throws {
        let gate = CropLoadGate(limit: 1)
        let tally = Tally()
        let slow = Task {
            try await gate.run { tally.enter(0); defer { tally.leave() }; try await Task.sleep(for: .seconds(30)) }
        }
        #expect(await eventually { await gate.activeCount == 1 })
        let next = Task { try await gate.run { tally.enter(1); tally.leave() } }
        #expect(await eventually { await gate.waitingCount == 1 })
        slow.cancel()
        try await next.value
        #expect(tally.order == [0, 1])
        await #expect(throws: CancellationError.self) { try await slow.value }
        #expect(await gate.activeCount == 0)
    }

    @Test func aThrowingCropStillFreesItsPlace() async throws {
        let gate = CropLoadGate(limit: 1)
        await #expect(throws: TestFailure.self) { try await gate.run { throw TestFailure() } as Int }
        #expect(await gate.activeCount == 0)
        #expect(try await gate.run { 7 } == 7)
    }
}
