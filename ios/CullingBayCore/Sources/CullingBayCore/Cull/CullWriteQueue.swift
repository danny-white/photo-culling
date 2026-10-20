import Foundation
import Observation

/// How the Cull models wait. Tests pass one that they release by hand.
public typealias CullSleep = @Sendable (Duration) async throws -> Void

public enum CullClock {
    /// Real time.
    public static let system: CullSleep = { try await Task.sleep(for: $0) }
}

/// The write queue, as `Q`, `send` and `pump` keep it in `app.js`. Taps are saved to the PC in
/// order, one at a time, so a decide followed by its undo can never arrive the other way round.
///
/// - A transport error or a 5xx (a 503 included) keeps the write, marks the queue offline and
///   tries again after `retryDelay`, or at once on `resume()`.
/// - Any other error status means the request itself is wrong: the write is dropped and
///   `lastDrop` says why.
/// - What is waiting is kept in the `store`, so it survives the app being closed. Make one
///   queue for the app and share it between the Cull screens.
@MainActor
@Observable
public final class CullWriteQueue {
    /// A write the server refused for good.
    public struct Drop: Sendable, Equatable, Identifiable {
        /// 1, 2, ...: tells one drop from the next.
        public let id: Int
        public let write: CullWrite
        public let error: CullingBayError
        /// `"Not saved: "` and the server's `error` text, or `HTTP <status>`.
        public let message: String
    }

    /// Writes not yet saved, the one in flight included.
    public var pending: Int { writes.count }
    /// The last try failed to reach the server; the banner reads `Offline · N waiting to save`.
    public private(set) var isOffline = false
    /// The latest write the server refused; nil until one is.
    public private(set) var lastDrop: Drop?

    private var writes: [CullWrite]

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let store: any CullWriteStore
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let sleep: CullSleep
    @ObservationIgnored private var isPumping = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var nextWaiter = 0
    @ObservationIgnored private var dropCount = 0
    @ObservationIgnored private var observers: [DropObserver] = []

    private struct DropObserver {
        weak var owner: AnyObject?
        let handler: @MainActor (Drop) -> Void
    }

    /// Takes what the store holds; `start()` sends it. `retryDelay` is the web app's 4 s.
    public init(
        client: CullingBayClient, store: any CullWriteStore, retryDelay: Duration = .seconds(4),
        sleep: @escaping CullSleep = CullClock.system
    ) {
        self.client = client
        self.store = store
        self.retryDelay = retryDelay
        self.sleep = sleep
        self.writes = store.load()
    }

    /// Sends what was left from an earlier run. Call it when the app launches.
    public func start() { resume() }

    /// Adds a write to the end and tries to send.
    public func enqueue(_ write: CullWrite) {
        writes.append(write)
        store.save(writes)
        resume()
    }

    /// Tries now instead of waiting out the retry. The app calls it when it comes to the foreground.
    public func resume() {
        retryTask?.cancel()
        retryTask = nil
        guard !isPumping else { return }
        Task { await pump() }
    }

    /// Tries to send everything, then waits until nothing is waiting. False if `timeout` ran out
    /// first (still offline); the queue keeps trying. Send needs it, so the day goes whole.
    public func drain(timeout: Duration) async -> Bool {
        resume()
        guard !writes.isEmpty else { return true }
        let id = nextWaiter
        nextWaiter += 1
        let sleep = self.sleep
        let timer = Task {
            do { try await sleep(timeout) } catch { return }
            finishWaiter(id, drained: false)
        }
        let drained = await withCheckedContinuation { waiters[id] = $0 }
        timer.cancel()
        return drained
    }

    /// Calls `handler` for each write the server refuses, until `owner` goes away or calls
    /// `stopObservingDrops(_:)`. The Cull session uses it to put back an undo the server refused.
    public func observeDrops(_ owner: AnyObject, _ handler: @escaping @MainActor (Drop) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(DropObserver(owner: owner, handler: handler))
    }

    public func stopObservingDrops(_ owner: AnyObject) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
    }

    // MARK: Sending

    private enum Outcome {
        case sent
        case retry
        case drop(CullingBayError)
    }

    private func pump() async {
        guard !isPumping else { return }
        isPumping = true
        defer { isPumping = false }
        while let write = writes.first {
            switch await attempt(write) {
            case .sent:
                removeFirst()
            case .drop(let error):
                removeFirst()
                report(write, error)
            case .retry:
                isOffline = true
                scheduleRetry()
                return
            }
        }
    }

    private func attempt(_ write: CullWrite) async -> Outcome {
        do {
            switch write {
            case .decide(let actionID, let day, let label, let changes):
                try await client.decide(actionID: actionID, day: day, label: label, changes: changes)
            case .undo(let actionID):
                try await client.undo(actionID: actionID)
            case .progress(let day, let pass, let cursor, let finished, let lead):
                try await client.saveProgress(
                    day: day, pass: pass, cursor: cursor, finished: finished, lead: lead)
            }
            return .sent
        } catch let error as CullingBayError {
            switch error {
            case .transport, .unavailable: return .retry
            case .http(let status, _): return status >= 500 ? .retry : .drop(error)
            case .conflict: return .drop(error)
            case .decoding: return .sent      // a 2xx whose answer we can't read: the server took it
            }
        } catch {
            return .retry
        }
    }

    private func removeFirst() {
        writes.removeFirst()
        store.save(writes)
        if writes.isEmpty {
            isOffline = false
            for id in Array(waiters.keys) { finishWaiter(id, drained: true) }
        }
    }

    private func scheduleRetry() {
        let delay = retryDelay, sleep = self.sleep
        retryTask = Task {
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            retryTask = nil
            await pump()
        }
    }

    private func finishWaiter(_ id: Int, drained: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: drained)
    }

    private func report(_ write: CullWrite, _ error: CullingBayError) {
        dropCount += 1
        let drop = Drop(
            id: dropCount, write: write, error: error,
            message: "Not saved: " + CullFormat.errorText(error))
        lastDrop = drop
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handler(drop) }
    }
}
