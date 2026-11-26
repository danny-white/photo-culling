import CullingBayCore
import Foundation
import Observation

/// Keeps days on the phone, if Settings says to. The decisions (which days fit the limit, what
/// to fetch and in what order, what to delete, how a sync ends) are `OfflineSync` in
/// CullingBayCore, where they are tested. This is the app's side: it owns the real store, client
/// and downloader, reads the settings from `UserDefaults`, keeps the folder out of backups, and
/// answers the focus check's questions about saved crops. The Settings screen and the Choose
/// days list read it.
///
/// It syncs when the app starts (once the PC has answered), when it comes to the foreground, when
/// the PC can be reached again, when a setting or a pin changes and after a Send, and stops when
/// the app goes to the background or Work offline is turned on. Nothing is fetched while the PC
/// cannot be reached. Downloads run only while the app is open; there is no background session.
@MainActor
@Observable
final class OfflineManager {
    typealias State = OfflineSync.State

    /// What the views read, as `OfflineSync` keeps it (it is `@Observable` too, so a view that
    /// reads one of these is redrawn when it changes).
    var state: State { core.state }
    /// The days whose files are all on the phone.
    var savedDays: Set<String> { core.savedDays }
    /// Everything the saved days take on disk, in bytes. Measured after each day.
    var totalBytes: Int { core.totalBytes }
    /// The days chosen for the phone, and those that were candidates but did not fit.
    var plan: OfflinePlan { core.plan }
    /// The days list the plan was made from, newest first.
    var days: [Day] { core.days }
    /// Danny's pins, by day id; a day without one is `auto`.
    var pins: [String: OfflinePin] { core.pins }
    /// The day being fetched now.
    var syncingDay: String? { core.syncingDay }

    @ObservationIgnored private let store: OfflineStore
    @ObservationIgnored private let core: OfflineSync

    /// `canReachPC` is the link being online: nothing is fetched while it is not.
    init(
        client: CullingBayClient, store: OfflineStore, downloader: OfflineDownloader,
        canReachPC: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.core = OfflineSync(
            daysSource: client, store: store, downloader: downloader,
            settings: UserDefaultsOfflineSettings(),
            excludeFromBackup: { excludeFromBackup(store.root) }, canReachPC: canReachPC)
    }

    // MARK: Triggers

    /// Brings the phone in line with the plan. Does nothing if offline is off. If a sync is
    /// already running, another follows it, so a change made meanwhile is not lost.
    func sync() { core.sync() }

    /// A setting changed: switch off wipes the phone's copies, anything else syncs once the
    /// changes have stopped.
    func settingsChanged() { core.settingsChanged() }

    /// Stops a sync in progress. The app calls it when it goes to the background.
    func cancel() { core.cancel() }

    /// Holds back the 1:1 crop top-up while a day is open in the Cull tab, so the PC decodes the
    /// RAWs of the 1:1 checks first. Letting go syncs again if a top-up was held back.
    func setCropsPaused(_ paused: Bool) { core.setCropsPaused(paused) }

    /// Saves a pin and syncs again.
    func pin(_ day: String, _ pin: OfflinePin) { core.pin(day, pin) }

    /// Reads the days list (from the saved copy if the PC cannot be reached) and makes the plan,
    /// without fetching anything. The Choose days list calls it when it opens.
    func reload() async { await core.reload() }

    // MARK: Saved crops

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
}

/// The saved days are re-downloadable, so they stay out of iCloud and device backups.
private func excludeFromBackup(_ folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var root = folder
    try? root.setResourceValues(values)
}
