import CullingBayCore
import Foundation
import Observation

/// Keeps days on the phone, if Settings says to: works out which days fit the limit
/// (`OfflinePlanner`), fetches the ones that are missing (`OfflineDownloader`) and deletes the
/// ones that no longer belong. The Settings screen and the Choose days list read it.
///
/// It syncs when the app starts, when it comes to the foreground, when a setting or a pin changes
/// and after a Send, and stops when the app goes to the background. Downloads run only while the
/// app is open; there is no background session.
@MainActor
@Observable
final class OfflineManager {
    enum State: Equatable, Sendable {
        /// Offline is switched off.
        case off
        /// Nothing to do: the days to keep are on the phone.
        case idle
        case syncing(dayTitle: String, done: Int, total: Int)
        /// The PC cannot be reached; the saved days are what the app shows.
        case offline
        case failed(String)
    }

    private(set) var state: State
    /// The days whose files are all on the phone.
    private(set) var savedDays: Set<String>
    /// Everything the saved days take on disk, in bytes. Measured after each day.
    private(set) var totalBytes = 0
    /// The days chosen for the phone, and those that were candidates but did not fit.
    private(set) var plan = OfflinePlan.empty
    /// The days list the plan was made from, newest first.
    private(set) var days: [Day] = []
    /// Danny's pins, by day id; a day without one is `auto`.
    private(set) var pins: [String: OfflinePin]
    /// The day being fetched now.
    private(set) var syncingDay: String?

    @ObservationIgnored private let store: OfflineStore
    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let downloader: OfflineDownloader
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var wipe: Task<Void, Never>?
    @ObservationIgnored private var markedExcludedFromBackup = false

    /// How long a change to a setting waits for the next one before it syncs, so dragging the
    /// slider is one sync, not twenty.
    private static let settleDelay: Duration = .seconds(1)

    init(client: CullingBayClient, store: OfflineStore, downloader: OfflineDownloader) {
        self.client = client
        self.store = store
        self.downloader = downloader
        self.pins = OfflinePreferences.loadPins()
        self.savedDays = Set(store.savedDays)
        self.state = OfflinePreferences.isEnabled ? .idle : .off
    }

    // MARK: Triggers

    /// Brings the phone in line with the plan. Does nothing if offline is off. If a sync is
    /// already running, another follows it, so a change made meanwhile is not lost.
    func sync() {
        guard OfflinePreferences.isEnabled else { return }
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
    func settingsChanged() {
        debounce?.cancel()
        guard OfflinePreferences.isEnabled else {
            turnOff()
            return
        }
        if state == .off { state = .idle }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.restart()
        }
    }

    /// Stops a sync in progress. The app calls it when it goes to the background.
    func cancel() {
        debounce?.cancel()
        again = false
        task?.cancel()
    }

    /// Saves a pin and syncs again.
    func pin(_ day: String, _ pin: OfflinePin) {
        pins[day] = pin == .auto ? nil : pin
        OfflinePreferences.savePins(pins)
        refreshPlan()
        guard OfflinePreferences.isEnabled else { return }
        restart()
    }

    /// Reads the days list (from the saved copy if the PC cannot be reached) and makes the plan,
    /// without fetching anything. The Choose days list calls it when it opens.
    func reload() async {
        guard OfflinePreferences.isEnabled else { return }
        if let fetched = try? await client.fetchDays() { days = fetched.value }
        refreshPlan()
        await measure()
    }

    /// Whether the phone has a 1:1 crop saved for this frame (a file check, no read).
    func hasSavedCrop(for id: Int) -> Bool {
        OfflinePreferences.isEnabled && store.hasImage(.af, id: id)
    }

    /// The 1:1 crop saved for a frame, for the focus check to show when the PC cannot make one.
    func savedCrop(for id: Int) async -> Data? {
        guard OfflinePreferences.isEnabled else { return nil }
        let store = store
        return await Task.detached { store.readImage(.af, id: id) }.value
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
        let settings = OfflinePreferences.current()
        guard settings.isEnabled else { return }
        excludeFromBackup()
        if state == .off { state = .idle }
        await measure()

        // The days list, which is the saved copy when the PC cannot be reached. Then only the
        // plan is made: nothing is fetched, and nothing is deleted that could not be fetched again.
        let list: Fetched<[Day]>
        do {
            list = try await client.fetchDays()
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
        guard OfflinePreferences.isEnabled else { return }
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
        let settings = OfflinePreferences.current()
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
    private func excludeFromBackup() {
        guard !markedExcludedFromBackup else { return }
        markedExcludedFromBackup = true
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = store.root
        try? root.setResourceValues(values)
    }

    // MARK: Errors

    /// The PC did not answer, as opposed to answering with an error.
    private static func isOutOfReach(_ error: any Error) -> Bool {
        guard let error = error as? CullingBayError else { return true }
        if case .transport = error { return true }
        return false
    }

    private static func message(for error: any Error) -> String {
        guard let error = error as? CullingBayError else { return error.localizedDescription }
        switch error {
        case .http(let status, let message): return "The PC answered: \(message ?? "HTTP \(status)")"
        case .conflict(let message, _), .unavailable(let message): return message ?? "The PC refused."
        case .decoding(let message), .transport(let message): return message
        }
    }
}
