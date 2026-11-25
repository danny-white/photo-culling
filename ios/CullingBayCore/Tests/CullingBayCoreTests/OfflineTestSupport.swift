import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import CullingBayCore

/// A folder for a store, made fresh and removed when the test is done.
final class TempRoot: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-test-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func store() -> OfflineStore { OfflineStore(root: url) }
}

/// A Day for the planner. `day` is `2026/<date>`; `unsent` nil leaves the older server's rule
/// (decided minus sent).
func planDay(
    _ date: String, frames: Int = 100, stacks: Int? = nil, decided: Int = 0, sent: Int = 0,
    lrDone: Int = 0, finished: Bool = false, unsent: Int? = nil, thumbs: [Int] = []
) -> Day {
    Day(
        day: "\(date.prefix(4))/\(date)", folder: date, date: date, frames: frames,
        stacks: stacks ?? frames, thumbs: thumbs, lastTs: 0, places: [], gpsFrames: 0,
        decided: decided, sent: sent, landed: 0, conflicts: 0, lrDone: lrDone, finished: finished,
        unsent: unsent)
}

/// The request's query as a dictionary.
func queryItems(_ request: URLRequest) -> [String: String] {
    guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

func getRequest(_ path: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "http://100.82.57.4:8000" + path)!)
    request.httpMethod = "GET"
    return request
}

// MARK: The sync loop's seams

/// Offline settings a test sets by hand. Pins are kept in memory and every save is recorded.
final class FakeOfflineSettings: OfflineSettingsSource {
    private struct State: Sendable {
        var values: OfflineSettings
        var pins: [String: OfflinePin]
        var saves: [[String: OfflinePin]] = []
    }

    private let state: Mutex<State>

    init(enabled: Bool = true, limitGB: Double = 2, crops: Bool = true, pins: [String: OfflinePin] = [:]) {
        state = Mutex(State(
            values: OfflineSettings(isEnabled: enabled, limitGB: limitGB, includeCrops: crops), pins: pins))
    }

    var isEnabled: Bool { state.withLock { $0.values.isEnabled } }
    func current() -> OfflineSettings { state.withLock { $0.values } }
    func loadPins() -> [String: OfflinePin] { state.withLock { $0.pins } }

    func savePins(_ pins: [String: OfflinePin]) {
        state.withLock {
            $0.pins = pins
            $0.saves.append(pins)
        }
    }

    /// Every `savePins`, in order.
    var saves: [[String: OfflinePin]] { state.withLock { $0.saves } }

    /// Changes the settings the way the Settings screen would, before `settingsChanged()`.
    func set(enabled: Bool? = nil, limitGB: Double? = nil, crops: Bool? = nil) {
        state.withLock { state in
            let old = state.values
            state.values = OfflineSettings(
                isEnabled: enabled ?? old.isEnabled, limitGB: limitGB ?? old.limitGB,
                includeCrops: crops ?? old.includeCrops)
        }
    }
}

/// The days list as the client would give it: fresh from the PC, the phone's saved copy (the PC
/// could not be reached), or an error. Counts the calls.
final class FakeDaysSource: OfflineDaysSource {
    enum Answer: Sendable {
        case fresh([Day])
        case savedCopy([Day])
        case failure(any Error)
    }

    private let state: Mutex<(answer: Answer, calls: Int)>

    init(_ answer: Answer) {
        state = Mutex((answer, 0))
    }

    func answer(_ answer: Answer) {
        state.withLock { $0.answer = answer }
    }

    var calls: Int { state.withLock { $0.calls } }

    func fetchDays() async throws -> Fetched<[Day]> {
        let answer = state.withLock { state in
            state.calls += 1
            return state.answer
        }
        switch answer {
        case .fresh(let days): return Fetched(value: days)
        case .savedCopy(let days): return Fetched(value: days, servedOffline: true)
        case .failure(let error): throw error
        }
    }
}

/// Holds calls until the test lets them through, by call index (zero-based, in arrival order).
actor CallGate {
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var opened: Set<Int> = []
    private(set) var arrived = 0

    func pass(_ index: Int) async {
        arrived += 1
        if opened.contains(index) { return }
        await withCheckedContinuation { waiting[index] = $0 }
    }

    /// Lets call `index` through, now or when it arrives.
    func open(_ index: Int) {
        if let continuation = waiting.removeValue(forKey: index) {
            continuation.resume()
        } else {
            opened.insert(index)
        }
    }

    /// Returns once `count` calls have arrived (a few seconds at most).
    func waitForArrivals(_ count: Int) async -> Bool {
        for _ in 0..<5000 {
            if arrived >= count { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

/// Stands in for `OfflineDownloader`. Records each call, reports the progress the test set, waits
/// at the gate if there is one, and then saves the day in the store as a download that found
/// every file would (`begin`, then `finish`, using the row's pictures), or throws what the test
/// set for that day and pass. A stopped task throws `CancellationError`, as the real one does.
final class FakeDayDownloader: OfflineDayDownloading {
    struct Call: Sendable, Hashable {
        let day: String
        let includeCrops: Bool
        let topUp: Bool
        /// The store had the day whole when the call started.
        let wasSaved: Bool
    }

    private struct Failure: Hashable {
        let day: String
        let topUp: Bool
    }

    private struct State: Sendable {
        var calls: [Call] = []
        var failures: [Failure: any Error] = [:]
        var progress: [[Int]] = []
    }

    private let store: OfflineStore
    private let gate: CallGate?
    private let state = Mutex(State())

    init(store: OfflineStore, gate: CallGate? = nil) {
        self.store = store
        self.gate = gate
    }

    var calls: [Call] { state.withLock { $0.calls } }

    /// Every call for `day` in that pass throws `error` until `succeed` is called.
    func fail(_ day: String, topUp: Bool = false, with error: any Error) {
        state.withLock { $0.failures[Failure(day: day, topUp: topUp)] = error }
    }

    func succeed(_ day: String, topUp: Bool = false) {
        state.withLock { _ = $0.failures.removeValue(forKey: Failure(day: day, topUp: topUp)) }
    }

    /// `[done, total]` pairs to report on every call, in order, before the gate.
    func report(_ steps: [[Int]]) {
        state.withLock { $0.progress = steps }
    }

    func download(
        _ day: Day, includeCrops: Bool, topUp: Bool, progress: OfflineDownloader.Progress
    ) async throws {
        let call = Call(day: day.day, includeCrops: includeCrops, topUp: topUp, wasSaved: store.isSaved(day.day))
        let (index, steps, failure) = state.withLock { state in
            state.calls.append(call)
            return (state.calls.count - 1, state.progress, state.failures[Failure(day: day.day, topUp: topUp)])
        }
        for step in steps { progress(step[0], step[1]) }
        if let gate { await gate.pass(index) }
        try Task.checkCancellation()
        if let failure { throw failure }
        try store.begin(day: day.day, frames: day.frames, photos: day.thumbs, keepingComplete: topUp)
        try store.finish(day: day.day)
    }
}

/// How many times the sync asked for the folder to be kept out of backups.
@MainActor
final class Tally {
    var count = 0
}

/// An `OfflineSync` over a store in a temporary folder, with fake settings and a fake days list,
/// and either the fake downloader or, given `network`, the real `OfflineDownloader` over it.
@MainActor
struct SyncRig {
    let root: TempRoot
    let store: OfflineStore
    let settings: FakeOfflineSettings
    let list: FakeDaysSource
    let fake: FakeDayDownloader
    let sleeper = ManualSleeper()
    let backups = Tally()
    let sync: OfflineSync

    /// `root`: a folder the test has already put files in, which the store then reads.
    init(
        _ answer: FakeDaysSource.Answer, settings: FakeOfflineSettings = FakeOfflineSettings(),
        root: TempRoot = TempRoot(), gate: CallGate? = nil, network: (any HTTPTransport)? = nil
    ) {
        self.root = root
        let store = root.store()
        self.store = store
        self.settings = settings
        list = FakeDaysSource(answer)
        fake = FakeDayDownloader(store: store, gate: gate)
        let downloader: any OfflineDayDownloading =
            network.map { OfflineDownloader(baseURL: testBaseURL, transport: $0, store: store) } ?? fake
        let backups = backups
        sync = OfflineSync(
            daysSource: list, store: store, downloader: downloader, settings: settings,
            sleep: sleeper.sleep, excludeFromBackup: { backups.count += 1 })
    }

    /// One sync, run to its end (and any sync it queued behind it).
    func syncNow() async {
        sync.sync()
        await sync.settled()
    }
}

/// A list that escaping `@Sendable` closures (a fake transport's handler) can add to.
final class SendableLog<Element: Sendable>: Sendable {
    private let state = Mutex<[Element]>([])

    func append(_ element: Element) { state.withLock { $0.append(element) } }
    var all: [Element] { state.withLock { $0 } }
}
