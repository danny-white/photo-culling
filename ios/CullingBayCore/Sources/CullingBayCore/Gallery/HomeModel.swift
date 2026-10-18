import Foundation
import Observation

/// State of the home screen: the library's years and months, On this day, and which are open.
/// Mirrors `renderHome` in `gallery.js`.
@MainActor
@Observable
public final class HomeModel {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var index = LibraryIndex.empty
    public private(set) var onThisDay: [LibraryIndex.OnThisDay] = []
    /// Years and months that are open. Copied from the settings so that a view tracks them.
    public private(set) var openYears: Set<String>
    public private(set) var openMonths: Set<String>
    /// Why the last `refresh()` failed while an earlier result is still on screen; nil otherwise.
    public private(set) var refreshError: String?

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let settings: any GallerySettings
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasLoaded = false

    /// `now` and `timeZone` decide what On this day means; tests pin them.
    public init(
        client: CullingBayClient, settings: any GallerySettings,
        now: @escaping () -> Date = { Date() }, timeZone: TimeZone = .current
    ) {
        self.client = client
        self.settings = settings
        self.now = now
        self.timeZone = timeZone
        self.openYears = settings.openYears
        self.openMonths = settings.openMonths
    }

    public func isYearOpen(_ year: String) -> Bool { openYears.contains(year) }
    public func isMonthOpen(_ key: String) -> Bool { openMonths.contains(key) }

    /// Loads the days. Shows `.loading` unless a result is already on screen.
    public func load() async {
        if !hasLoaded { phase = .loading }
        await fetch()
    }

    /// Fetches again (a 304 makes it cheap). The current result stays on screen meanwhile and,
    /// if the fetch fails, afterwards; `refreshError` says why.
    public func refresh() async {
        await fetch()
    }

    public func toggleYear(_ year: String) {
        if !openYears.insert(year).inserted { openYears.remove(year) }
        settings.openYears = openYears
    }

    public func toggleMonth(_ key: String) {
        if !openMonths.insert(key).inserted { openMonths.remove(key) }
        settings.openMonths = openMonths
    }

    private func fetch() async {
        generation += 1
        let mine = generation
        do {
            let days = try await client.days()
            guard mine == generation else { return }
            apply(days)
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled {
                if !hasLoaded { phase = .idle }
                return
            }
            let message = GalleryMessages.failure(error, loading: "the library")
            if hasLoaded {
                refreshError = message
            } else {
                phase = .failed(message)
            }
        }
    }

    private func apply(_ days: [Day]) {
        index = LibraryIndex(days: days)
        onThisDay = index.onThisDay(today: now(), timeZone: timeZone)
        if !settings.hasOpenState, let newest = index.years.first, let month = newest.months.first {
            // First visit: the newest year and its newest month.
            settings.openYears = [newest.year]
            settings.openMonths = [month.key]
        }
        openYears = settings.openYears
        openMonths = settings.openMonths
        hasLoaded = true
        refreshError = nil
        phase = .loaded
    }
}
