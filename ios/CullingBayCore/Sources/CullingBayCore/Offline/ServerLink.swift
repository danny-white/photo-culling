import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import Synchronization

/// Where Work offline is kept between launches. The app keeps it in `UserDefaults` under a key of
/// its own; tests keep it in memory.
public protocol WorkOfflineSetting: AnyObject {
    var isOn: Bool { get set }
}

/// Whether the PC can be reached, for the whole app: one probe when the app starts, and after
/// that every request fails at once while the PC cannot be reached, instead of each one waiting
/// out its own timeout. Every request goes through `ServerLinkTransport`, which reads `gate`.
///
/// - `checking`: the first probe of a launch is out (or the one after Work offline is turned
///   off). Requests wait for its answer, at most `probeTimeout`, and then follow the state; one
///   that is still waiting by then is failed as out of reach, as the probe is about to be.
/// - `online`: requests go to the PC as they always have.
/// - `unreachable`: the probe or a request failed at the network level, or the phone has no
///   network at all. Saved days and pictures answer from the phone; everything else fails at
///   once. While the app is active and the phone has a network, it probes again after 5, 10 and
///   20 s, and then every 30 s.
/// - `forcedOffline`: Work offline is on. Nothing is sent at all, not even a probe, and it stays
///   on across launches until it is turned off.
///
/// The probe is `GET /m/api/ping`, sent straight to the network (not through the gate), with a
/// 2.5 s limit. Any HTTP answer at all, even a 503, means the PC can be reached; no answer means
/// it cannot.
///
/// Traffic teaches it too: a request that fails at the network level makes it `unreachable` at
/// once, and any HTTP answer makes it `online`, unless Work offline is on. A cancelled request
/// says nothing.
@MainActor
@Observable
public final class ServerLink {
    public enum State: Sendable, Hashable {
        /// The first probe is out. Requests wait for it.
        case checking
        case online
        /// The PC cannot be reached. Requests fail at once.
        case unreachable
        /// Work offline is on. Nothing is sent.
        case forcedOffline
    }

    // MARK: Timing

    /// How long a probe waits for the PC, and how long a request waits for the first probe.
    public nonisolated static let probeTimeout: Duration = .milliseconds(2500)
    /// The waits between probes while the PC cannot be reached, in order; the last one repeats.
    public nonisolated static let pollDelays: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(30)]

    /// What a request fails with while the PC cannot be reached. It is a `.transport` error, so
    /// callers treat it as a lost connection: the write queue keeps the write and tries again.
    public nonisolated static let unreachableMessage = "Can't reach the PC."
    /// What a request fails with while Work offline is on.
    public nonisolated static let forcedMessage = "Work offline is on."

    // MARK: State

    public private(set) var state: State
    /// How many times the PC has been reached again after it could not be. A screen that failed
    /// for want of the PC watches it to load again.
    public private(set) var recoveries = 0

    public var isOnline: Bool { state == .online }
    /// Work offline is on.
    public var isWorkingOffline: Bool { state == .forcedOffline }

    /// Called when the PC can be reached again after it could not, or after Work offline is
    /// turned off: the app sends the taps waiting, syncs the saved days and refreshes the days
    /// list. Not called when the first probe of a launch finds the PC.
    @ObservationIgnored public var onReachable: (@MainActor () -> Void)?
    /// Called when Work offline is turned on: the app stops the offline downloads.
    @ObservationIgnored public var onWorkOffline: (@MainActor () -> Void)?

    /// The state as the transport reads it, from any thread.
    public nonisolated let gate: ServerLinkGate

    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private let network: any HTTPTransport
    @ObservationIgnored private let setting: any WorkOfflineSetting
    @ObservationIgnored private let sleep: CullSleep
    @ObservationIgnored private var hasPath = true
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var isStopped = false
    /// The next reaching of the PC is a recovery (`onReachable`).
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var probeGeneration = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Which of `pollDelays` the next poll waits.
    @ObservationIgnored private var pollStep = 0

    /// `network` is the real transport, which the probe goes out on. `setting` says whether Work
    /// offline was left on; with it on, the link starts `forcedOffline` and never probes.
    public init(
        baseURL: URL, network: any HTTPTransport, setting: any WorkOfflineSetting,
        sleep: @escaping CullSleep = CullClock.system
    ) {
        self.baseURL = baseURL
        self.network = network
        self.setting = setting
        self.sleep = sleep
        let first: State = setting.isOn ? .forcedOffline : .checking
        state = first
        gate = ServerLinkGate(state: first, sleep: sleep)
        gate.setListener { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    // MARK: Triggers

    /// The launch's probe. Returns once it has answered (at once with Work offline on, or with
    /// no network).
    public func start() async {
        probeNow()
        await probeAnswered()
    }

    /// Probes now and starts the waits between polls again from the shortest: "Try now", pull
    /// to refresh. Returns once the probe has answered. Does nothing with Work offline on.
    public func checkNow() async {
        probeNow()
        await probeAnswered()
    }

    /// The app came to the front (probe now) or went to the background (no polling there).
    public func setActive(_ active: Bool) {
        isActive = active
        if active {
            probeNow()
        } else {
            stopPolling()
        }
    }

    /// The phone's network changed. With none at all the PC is out of reach at once and nothing
    /// polls; with one, a probe goes now, since a new network may or may not reach the PC.
    public func pathChanged(hasPath: Bool) {
        self.hasPath = hasPath
        guard state != .forcedOffline, !isStopped else { return }
        if hasPath {
            // A probe already out went on the old network; this one answers for the new.
            cancelProbe()
            probeNow()
        } else {
            cancelProbe()
            stopPolling()
            gate.set(.unreachable)
            follow()
        }
    }

    /// Work offline on: nothing more is sent, the downloads stop (`onWorkOffline`) and so does any
    /// poll. Off: a probe goes at once, and reaching the PC sends the taps waiting (`onReachable`).
    /// Kept across launches.
    public func setWorkingOffline(_ on: Bool) {
        guard on != (state == .forcedOffline) else { return }
        setting.isOn = on
        if on {
            cancelProbe()
            stopPolling()
            gate.set(.forcedOffline)
            follow()
        } else {
            recovering = true
            pollStep = 0
            gate.set(hasPath ? .checking : .unreachable)
            follow()
            probeNow()
        }
    }

    /// For a link the app no longer uses (the server changed): no more probes or polls.
    public func stop() {
        isStopped = true
        cancelProbe()
        stopPolling()
    }

    // MARK: Following the gate

    /// Takes up the gate's state, which traffic may have changed, and does what the change asks.
    private func follow() {
        let now = gate.state
        guard now != state else { return }
        state = now
        switch now {
        case .online:
            stopPolling()
            pollStep = 0
            if recovering {
                recovering = false
                recoveries += 1
                onReachable?()
            }
        case .unreachable:
            recovering = true
            schedulePoll()
        case .forcedOffline:
            recovering = false
            onWorkOffline?()
        case .checking:
            break
        }
    }

    // MARK: Probing

    /// Starts a probe unless one is out already, and puts the polls back to the shortest wait.
    private func probeNow() {
        stopPolling()
        pollStep = 0
        startProbe()
    }

    private func startProbe() {
        guard probeTask == nil, state != .forcedOffline, hasPath, !isStopped else { return }
        probeGeneration += 1
        let mine = probeGeneration
        probeTask = Task { [weak self] in
            guard let self else { return }
            let answered = await self.ping()
            self.probeEnded(mine, answered: answered)
        }
    }

    /// Returns once no probe is out, following a probe that replaced the one it waited for.
    private func probeAnswered() async {
        while let task = probeTask {
            await task.value
            if probeTask == task { return }
        }
    }

    private func probeEnded(_ generation: Int, answered: Bool?) {
        // A probe that was called off says nothing.
        guard generation == probeGeneration else { return }
        probeTask = nil
        guard state != .forcedOffline, !isStopped else { return }
        // Nil here is a probe the system cancelled, not one called off: no answer either way.
        gate.set(answered == true ? .online : .unreachable)
        follow()
        if state == .unreachable { schedulePoll() }
    }

    private func cancelProbe() {
        probeGeneration += 1
        probeTask?.cancel()
        probeTask = nil
    }

    /// `GET /m/api/ping` on the real network: true for any HTTP answer, false for none within
    /// `probeTimeout`, nil if the probe was called off.
    private func ping() async -> Bool? {
        var request = URLRequest(url: URLBuilding.url(base: baseURL, path: "/m/api/ping"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Double(Self.probeTimeout.components.seconds)
            + Double(Self.probeTimeout.components.attoseconds) / 1e18
        return await Self.ping(request, on: network, sleep: sleep)
    }

    private nonisolated static func ping(
        _ request: URLRequest, on network: any HTTPTransport, sleep: @escaping CullSleep
    ) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                do {
                    _ = try await network.send(request)
                    return true
                } catch {
                    return Task.isCancelled || isCancellation(error) ? nil : false
                }
            }
            group.addTask {
                do { try await sleep(probeTimeout) } catch { return nil }
                return Task.isCancelled ? nil : false
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return Task.isCancelled ? nil : first
        }
    }

    // MARK: Polling

    /// The next poll, after the next of `pollDelays`. Only while the PC cannot be reached, the
    /// app is active and the phone has a network, and not while a probe is out.
    private func schedulePoll() {
        guard pollTask == nil, probeTask == nil, state == .unreachable, isActive, hasPath, !isStopped
        else { return }
        let delays = Self.pollDelays
        let delay = delays[min(pollStep, delays.count - 1)]
        pollStep += 1
        let sleep = sleep
        pollTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.pollTask = nil
            self.startProbe()
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Errors

    /// A cancelled request, which says nothing about the PC.
    public nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// A request that got no answer from the network: a timeout, a refused or lost connection, no
    /// network, a name that would not resolve. Not an HTTP status, and not a cancelled request.
    public nonisolated static func isNetworkFailure(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
             .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
             .cannotLoadFromNetwork, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}

/// The link's state as `ServerLinkTransport` reads it on every request, from any thread, behind a
/// lock; and the requests waiting while the first probe is out.
public final class ServerLinkGate: Sendable {
    private struct Shared: Sendable {
        var state: ServerLink.State
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var nextWaiter = 0
        var listener: (@Sendable () -> Void)?
    }

    private let shared: Mutex<Shared>
    private let sleep: CullSleep

    init(state: ServerLink.State, sleep: @escaping CullSleep) {
        shared = Mutex(Shared(state: state))
        self.sleep = sleep
    }

    public var state: ServerLink.State { shared.withLock { $0.state } }

    /// Told when traffic changes the state.
    func setListener(_ listener: @escaping @Sendable () -> Void) {
        shared.withLock { $0.listener = listener }
    }

    /// Sets the state. Leaving `checking` lets the waiting requests go.
    func set(_ new: ServerLink.State) {
        let released = shared.withLock { shared -> [CheckedContinuation<Void, Never>] in
            shared.state = new
            return Self.release(&shared)
        }
        for waiter in released { waiter.resume() }
    }

    /// What a request found: any HTTP answer (`true`) means the PC can be reached, a failure at
    /// the network level (`false`) that it cannot. Work offline is not changed by either.
    func heard(answer: Bool) {
        let (changed, released, listener) = shared.withLock { shared in
            let new: ServerLink.State = answer ? .online : .unreachable
            guard shared.state != .forcedOffline, shared.state != new else {
                return (false, [CheckedContinuation<Void, Never>](), shared.listener)
            }
            shared.state = new
            return (true, Self.release(&shared), shared.listener)
        }
        for waiter in released { waiter.resume() }
        if changed { listener?() }
    }

    private static func release(_ shared: inout Shared) -> [CheckedContinuation<Void, Never>] {
        guard shared.state != .checking, !shared.waiters.isEmpty else { return [] }
        let waiting = Array(shared.waiters.values)
        shared.waiters = [:]
        return waiting
    }

    /// While the first probe is out: waits for its answer, at most `probeTimeout`.
    func waitWhileChecking() async {
        guard state == .checking else { return }
        let sleep = sleep
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.untilDecided() }
            group.addTask { try? await sleep(ServerLink.probeTimeout) }
            await group.next()
            group.cancelAll()
        }
    }

    private func untilDecided() async {
        let id = shared.withLock { shared in
            defer { shared.nextWaiter += 1 }
            return shared.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = shared.withLock { shared -> Bool in
                    if shared.state != .checking || Task.isCancelled { return true }
                    shared.waiters[id] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            shared.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }
}

/// The real network behind the link: while the PC cannot be reached, or Work offline is on, a
/// request fails at once with a `.transport` error and nothing is sent; while the first probe is
/// out it waits for it. What comes back tells the link whether the PC can be reached. Put the
/// phone's saved days (`OfflineTransport`) over it, and the offline downloader on it, so neither
/// waits on a PC that is not there.
public struct ServerLinkTransport: HTTPTransport {
    private let base: any HTTPTransport
    private let gate: ServerLinkGate

    public init(base: any HTTPTransport, gate: ServerLinkGate) {
        self.base = base
        self.gate = gate
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await gate.waitWhileChecking()
        try Task.checkCancellation()
        switch gate.state {
        // Still checking: the probe has had its time with no answer, so the PC is not answering.
        case .unreachable, .checking: throw CullingBayError.transport(ServerLink.unreachableMessage)
        case .forcedOffline: throw CullingBayError.transport(ServerLink.forcedMessage)
        case .online: break
        }
        do {
            let answer = try await base.send(request)
            gate.heard(answer: true)
            return answer
        } catch {
            if !Task.isCancelled, ServerLink.isNetworkFailure(error) { gate.heard(answer: false) }
            throw error
        }
    }
}
