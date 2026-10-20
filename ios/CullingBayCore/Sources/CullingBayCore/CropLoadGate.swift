import Foundation

/// Lets only a few full-resolution crops download at once, the rest wait their turn.
///
/// A crop makes the PC decode a whole RAW, a second or more each. The web app sends them one at
/// a time and cancels the ones for frames you have moved past (`CROPS` and `keepCrops` in
/// `app.js`), because a phone opens only a handful of connections to the PC and prefetched
/// crops once starved the decisions of all of them. Every crop in the focus view goes through
/// one gate, so a `decide` write always has a connection free.
///
/// Cancelling a waiting caller removes it from the line at once; cancelling a running one
/// frees its place as soon as its work returns.
public actor CropLoadGate {
    public nonisolated let limit: Int

    private struct Waiter {
        let id: Int
        let urgent: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var running = 0
    private var waiting: [Waiter] = []
    private var nextID = 0

    /// `limit` is how many crops may be in flight; at least 1.
    public init(limit: Int = 2) {
        self.limit = max(1, limit)
    }

    /// Crops in flight now.
    public var activeCount: Int { running }
    /// Callers waiting for a place.
    public var waitingCount: Int { waiting.count }

    /// Runs `work` once a place is free. `urgent` goes ahead of the ordinary callers (what you
    /// are looking at, ahead of what is only being warmed up), in the order the urgent ones came. Throws `CancellationError`, without
    /// running `work`, if the caller is cancelled while waiting.
    public func run<T: Sendable>(
        urgent: Bool = false, _ work: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(urgent: urgent)
        defer { release() }
        return try await work()
    }

    private func acquire(urgent: Bool) async throws {
        try Task.checkCancellation()
        if running < limit && waiting.isEmpty {
            running += 1
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(id: id, urgent: urgent, continuation: continuation)
                // Urgent callers go before the others, but keep their own order among themselves.
                if urgent, let firstOrdinary = waiting.firstIndex(where: { !$0.urgent }) {
                    waiting.insert(waiter, at: firstOrdinary)
                } else {
                    waiting.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.leave(id) }
        }
    }

    /// The place goes straight to the next in line, so `running` does not dip in between.
    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }

    private func leave(_ id: Int) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).continuation.resume(throwing: CancellationError())
    }
}
