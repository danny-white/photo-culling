import Foundation
import Observation

// MARK: Seams

/// The offline settings as they stand when the sync reads them. The app reads them from
/// `UserDefaults` (`OfflinePreferences`); tests set them by hand.
public struct OfflineSettings: Sendable, Hashable {
    public let isEnabled: Bool
    /// How much to keep, in gigabytes.
    public let limitGB: Double
    /// Whether to keep the 1:1 crop at each frame's AF point.
    public let includeCrops: Bool

    public init(isEnabled: Bool, limitGB: Double, includeCrops: Bool) {
        self.isEnabled = isEnabled
        self.limitGB = limitGB
        self.includeCrops = includeCrops
    }
}

/// Where the sync reads the settings and keeps Danny's pins. Read again at each step, so a
/// change made during a sync is seen by the next step.
public protocol OfflineSettingsSource: Sendable {
    /// Whether offline is on now.
    var isEnabled: Bool { get }
    /// Every setting at once.
    func current() -> OfflineSettings
    /// The pins by day id; a day without one is `auto`.
    func loadPins() -> [String: OfflinePin]
    func savePins(_ pins: [String: OfflinePin])
}

/// The days list, which also says whether the PC could be reached: a list that is the phone's
/// saved copy (`servedOffline`) means it could not, and so does a transport error.
/// `CullingBayClient` over an `OfflineTransport` is the real one.
public protocol OfflineDaysSource: Sendable {
    func fetchDays() async throws -> Fetched<[Day]>
}

extension CullingBayClient: OfflineDaysSource {}

/// Fetches one day into the store. `OfflineDownloader` is the real one.
public protocol OfflineDayDownloading: Sendable {
    /// Throws `CancellationError` if the task is cancelled. `topUp`: the day is saved already
    /// and this adds what it lacks; it stays saved meanwhile.
    func download(
        _ day: Day, includeCrops: Bool, topUp: Bool, progress: OfflineDownloader.Progress
    ) async throws
}

extension OfflineDownloader: OfflineDayDownloading {}

/// What the sync asks of the days kept on the phone. `OfflineStore` is the real one.
public protocol OfflineSyncStore: AnyObject, Sendable {
    /// The days that are whole.
    var savedDays: [String] { get }
    /// Every day the store has a record of, whole or not.
    var records: [OfflineDayRecord] { get }
    /// Everything the store holds on disk.
    var totalBytes: Int { get }
    func isSaved(_ day: String) -> Bool
    /// What a whole day takes; 0 for a day that is not whole.
    func bytes(of day: String) -> Int
    /// Forgets a day: its JSON, and every picture no other day uses.
    func remove(_ day: String)
    /// Deletes pictures and day files that no record accounts for.
    func removeOrphans()
    /// Forgets everything.
    func removeAll()
}

extension OfflineStore: OfflineSyncStore {}

// MARK: The sync

/// Keeps days on the phone, if the settings say to: works out which days fit the limit
/// (`OfflinePlanner`), fetches the ones that are missing (the downloader) and deletes the ones
/// that no longer belong. The app's `OfflineManager` owns one and passes the real objects; the
/// Settings screen and the Choose days list read what it says.
///
/// A sync, in order:
/// 1. Reads the days list. If that fails, or the list is the phone's copy, it ends there
///    (`offline`, or `failed` if the PC answered with an error): nothing is fetched, and nothing
///    is deleted that could not be fetched again.
/// 2. Deletes what no record accounts for (`removeOrphans`).
/// 3. Pictures first, for every planned day in plan order, each day tried once. Before each, the
///    plan is made again and the days that left it are deleted.
/// 4. If 1:1 crops are on and nothing went wrong, tops up every saved planned day once, in plan
///    order (`topUp`: the day stays saved meanwhile).
///
/// A transport error (or any error that is not the PC's answer) ends the sync as `offline`. Any
/// other error leaves that day for next time, skips the top-up, and ends the sync as `failed`.
@MainActor
@Observable
public final class OfflineSync {
    public enum State: Equatable, Sendable {
        /// Offline is switched off.
        case off
        /// Nothing to do: the days to keep are on the phone.
        case idle
        case syncing(dayTitle: String, done: Int, total: Int)
        /// The PC cannot be reached; the saved days are what the app shows.
        case offline
        case failed(String)
    }

    public private(set) var state: State
    /// The days whose files are all on the phone.
    public private(set) var savedDays: Set<String>
    /// Everything the saved days take on disk, in bytes. Measured after each day.
    public private(set) var totalBytes = 0
    /// The days chosen for the phone, and those that were candidates but did not fit.
    public private(set) var plan = OfflinePlan.empty
    /// The days list the plan was made from, newest first.
    public private(set) var days: [Day] = []
    /// Danny's pins, by day id; a day without one is `auto`.
    public private(set) var pins: [String: OfflinePin]
    /// The day being fetched now.
    public private(set) var syncingDay: String?

    @ObservationIgnored private let store: any OfflineSyncStore
    @ObservationIgnored private let daysSource: any OfflineDaysSource
    @ObservationIgnored private let downloader: any OfflineDayDownloading
    @ObservationIgnored private let preferences: any OfflineSettingsSource
    @ObservationIgnored private let sleep: CullSleep
    @ObservationIgnored private let excludeFromBackup: @MainActor () -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var wipe: Task<Void, Never>?
    @ObservationIgnored private var markedExcludedFromBackup = false

    /// How long a change to a setting waits for the next one before it syncs, so dragging the
    /// slider is one sync, not twenty.
    public static let settleDelay: Duration = .seconds(1)

    /// `daysSource` is the client the app reads days with (through the saved days); `downloader`
    /// fetches with the real network. `excludeFromBackup` keeps the store's folder out of
    /// backups; it is called once, by the first sync that runs with offline on.
    public init(
        daysSource: any OfflineDaysSource, store: any OfflineSyncStore,
        downloader: any OfflineDayDownloading, settings: any OfflineSettingsSource,
        sleep: @escaping CullSleep = CullClock.system,
        excludeFromBackup: @escaping @MainActor () -> Void = {}
    ) {
        self.daysSource = daysSource
        self.store = store
        self.downloader = downloader
        self.preferences = settings
        self.sleep = sleep
        self.excludeFromBackup = excludeFromBackup
        self.pins = settings.loadPins()
        self.savedDays = Set(store.savedDays)
        self.state = settings.isEnabled ? .idle : .off
    }

    // MARK: Triggers

    /// Brings the phone in line with the plan. Does nothing if offline is off. If a sync is
    /// already running, another follows it, so a change made meanwhile is not lost.
    public func sync() {
        guard preferences.isEnabled else { return }
        if task != nil {
            again = true
            return
        }
        task = Task { [weak self] in
            await self?.run()
            self?.runFinished()
        }
    }

    /// A setting changed: switch off wipes the phone's copies, anything else syncs once the
    /// changes have stopped.
    public func settingsChanged() {
        debounce?.cancel()
        guard preferences.isEnabled else {
            turnOff()
            return
        }
        if state == .off { state = .idle }
        let sleep = sleep
        debounce = Task { [weak self] in
            try? await sleep(Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.restart()
        }
    }

    /// Stops a sync in progress. The app calls it when it goes to the background.
    public func cancel() {
        debounce?.cancel()
        again = false
        task?.cancel()
    }

    /// Saves a pin and syncs again.
    public func pin(_ day: String, _ pin: OfflinePin) {
        pins[day] = pin == .auto ? nil : pin
        preferences.savePins(pins)
        refreshPlan()
        guard preferences.isEnabled else { return }
        restart()
    }

    /// Reads the days list (from the saved copy if the PC cannot be reached) and makes the plan,
    /// without fetching anything. The Choose days list calls it when it opens.
    public func reload() async {
        guard preferences.isEnabled else { return }
        if let fetched = try? await daysSource.fetchDays() { days = fetched.value }
        refreshPlan()
        await measure()
    }

    /// Returns once nothing is running or waiting to run: the settle delay, a wipe, the sync and
    /// any sync queued behind it. For tests; the app never waits for a sync.
    func settled() async {
        repeat {
            await debounce?.value
            await wipe?.value
            await task?.value
        } while task != nil
    }

    // MARK: Running

    private func restart() {
        task?.cancel()
        sync()
    }

    private func runFinished() {
        task = nil
        if again {
            again = false
            sync()
        }
    }

    /// Offline went off: stop, then delete every copy once the fetch in flight has let go of its
    /// files, and before any later sync starts.
    private func turnOff() {
        cancel()
        state = .off
        syncingDay = nil
        let running = task
        let store = store
        wipe = Task { [weak self] in
            await running?.value
            await Task.detached { store.removeAll() }.value
            self?.savedDays = []
            self?.totalBytes = 0
            self?.plan = .empty
        }
    }

    private func run() async {
        await wipe?.value
        let settings = preferences.current()
        guard settings.isEnabled else { return }
        markExcludedFromBackup()
        if state == .off { state = .idle }
        await measure()

        // The days list, which is the saved copy when the PC cannot be reached. Then only the
        // plan is made: nothing is fetched, and nothing is deleted that could not be fetched again.
        let list: Fetched<[Day]>
        do {
            list = try await daysSource.fetchDays()
        } catch {
            if !(error is CancellationError) && !Task.isCancelled {
                setState(Self.isOutOfReach(error) ? .offline : .failed(Self.message(for: error)))
            }
            return
        }
        days = list.value
        refreshPlan()
        if list.servedOffline {
            setState(.offline)
            return
        }

        let store = store
        await Task.detached { store.removeOrphans() }.value
        var tried = Set<String>()
        var problem: String?
        while !Task.isCancelled {
            refreshPlan()
            await removeUnplanned()
            guard let next = plan.kept.first(where: { !store.isSaved($0.day.day) && !tried.contains($0.day.day) })
            else { break }
            tried.insert(next.day.day)
            do {
                // Pictures first, for every planned day: a day opens offline as soon as they are in.
                // The 1:1 crops, slow on the PC (it reads each whole RAW from the NAS), come after.
                try await download(next, includeCrops: false)
            } catch is CancellationError {
                break
            } catch {
                // Out of reach stops the whole sync. Anything else leaves this day for next time.
                if Self.isOutOfReach(error) {
                    syncingDay = nil
                    setState(.offline)
                    await measure()
                    return
                }
                problem = Self.message(for: error)
            }
        }
        // Second pass: the crops of the saved days, each day once per sync (a fetch of its data,
        // then only the files it lacks). The day stays saved meanwhile.
        if settings.includeCrops && !Task.isCancelled && problem == nil {
            var topped = Set<String>()
            while !Task.isCancelled {
                refreshPlan()
                guard let next = plan.kept.first(where: { store.isSaved($0.day.day) && !topped.contains($0.day.day) })
                else { break }
                topped.insert(next.day.day)
                do {
                    try await download(next, includeCrops: true, topUp: true)
                } catch is CancellationError {
                    break
                } catch {
                    if Self.isOutOfReach(error) {
                        syncingDay = nil
                        setState(.offline)
                        await measure()
                        return
                    }
                    problem = Self.message(for: error)
                }
            }
        }
        syncingDay = nil
        await measure()
        setState(problem.map(State.failed) ?? .idle)
    }

    /// A sync that was stopped because offline went off must not put its own state over `off`.
    private func setState(_ new: State) {
        guard preferences.isEnabled else { return }
        state = new
    }

    private func download(_ entry: OfflinePlan.Entry, includeCrops: Bool, topUp: Bool = false) async throws {
        let day = entry.day.day
        let title = CullFormat.dayTitle(date: entry.day.date, folder: entry.day.folder)
        syncingDay = day
        setState(.syncing(dayTitle: title, done: 0, total: 0))
        try await downloader.download(entry.day, includeCrops: includeCrops, topUp: topUp) { [weak self] done, total in
            Task { @MainActor in self?.progress(day: day, title: title, done: done, total: total) }
        }
        await measure()
        refreshPlan()
    }

    /// The hops back to the main actor can arrive out of order or after the day is finished.
    private func progress(day: String, title: String, done: Int, total: Int) {
        guard syncingDay == day else { return }
        if case .syncing(_, let before, _) = state, before > done { return }
        setState(.syncing(dayTitle: title, done: done, total: total))
    }

    /// Deletes the saved days (and half-fetched ones) that are not among the days to keep. Not
    /// when the list came back empty, which is more likely a fault than an empty library.
    private func removeUnplanned() async {
        guard !days.isEmpty else { return }
        let keep = Set(plan.kept.map(\.id))
        let doomed = store.records.map(\.day).filter { !keep.contains($0) }
        guard !doomed.isEmpty else { return }
        let store = store
        await Task.detached { for day in doomed { store.remove(day) } }.value
        await measure()
    }

    // MARK: State

    private func refreshPlan() {
        let settings = preferences.current()
        savedDays = Set(store.savedDays)
        plan = OfflinePlanner.plan(
            days: days, pins: pins, savedBytes: Dictionary(uniqueKeysWithValues: savedDays.map { ($0, store.bytes(of: $0)) }),
            limitBytes: OfflinePlanner.bytes(gigabytes: settings.limitGB), includeCrops: settings.includeCrops)
    }

    /// Counts the files on disk off the main actor.
    private func measure() async {
        let store = store
        let measured = await Task.detached { (days: Set(store.savedDays), bytes: store.totalBytes) }.value
        savedDays = measured.days
        totalBytes = measured.bytes
    }

    /// The saved days are re-downloadable, so they stay out of iCloud and device backups.
    private func markExcludedFromBackup() {
        guard !markedExcludedFromBackup else { return }
        markedExcludedFromBackup = true
        excludeFromBackup()
    }

    // MARK: Errors

    /// The PC did not answer, as opposed to answering with an error.
    static func isOutOfReach(_ error: any Error) -> Bool {
        guard let error = error as? CullingBayError else { return true }
        if case .transport = error { return true }
        return false
    }

    static func message(for error: any Error) -> String {
        guard let error = error as? CullingBayError else { return error.localizedDescription }
        switch error {
        case .http(let status, let message): return "The PC answered: \(message ?? "HTTP \(status)")"
        case .conflict(let message, _), .unavailable(let message): return message ?? "The PC refused."
        case .decoding(let message), .transport(let message): return message
        }
    }
}
