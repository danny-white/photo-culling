import Foundation
import Observation

/// The stacks a search found in a day, which come first when the day opens. `label` finishes
/// "N stacks matched …" (`“sunset”`).
public struct CullMatch: Sendable, Hashable {
    public let ids: [Int]
    public let label: String

    public init(ids: [Int], label: String) {
        self.ids = ids
        self.label = label
    }
}

/// One day in the Cull tab's list: what `dayRow` in `app.js` shows.
public struct CullDayRow: Sendable, Hashable, Identifiable {
    /// The small label at the end of the row.
    public struct Tag: Sendable, Hashable {
        public enum Style: Sendable, Hashable {
            /// `3 conflicts`.
            case warn
            /// `Synced`, `Sent`, `Done`, `In Lightroom`, `Resting`.
            case quiet
            /// The percent decided.
            case normal
        }

        public let text: String
        public let style: Style
    }

    public let day: Day
    /// `Sat, 17 Oct 2026`, or the folder for an undated day.
    public let title: String
    /// `120 frames · 84 stacks · 50 done in Lightroom`; an undated day adds its id.
    public let meta: String
    /// The first two parts of the place as stored, such as `greenwood, washington`; nil without one.
    public let place: String?
    /// Up to three photos for the row. For a search hit its matching photos come first.
    public let thumbs: [Int]
    public let tag: Tag?
    /// Percent of frames decided, 0 to 100.
    public let percent: Int
    /// Whether to draw the progress bar (`percent` wide): some frames are decided.
    public let showsBar: Bool
    /// For a search hit, its one line (`3 photos · “a chick in a burrow”`); it replaces `summary`.
    public let why: String?
    /// The day's summary, lines separated by `\n`; nil when `why` is shown.
    public let summary: String?
    /// For a search hit with matching photos: what to give the session so they come first.
    public let match: CullMatch?

    public var id: String { day.day }
}

/// A month in a year of the day list.
public struct CullMonth: Sendable, Hashable, Identifiable {
    /// `October`, or `Other folders` for undated days.
    public let name: String
    public let rows: [CullDayRow]
    /// `October · 5`.
    public let title: String
    public let id: String
}

/// A year in the day list: a header you can open, and its months.
public struct CullYear: Sendable, Hashable, Identifiable {
    /// The first four characters of the day id: `2026`.
    public let year: String
    /// `5 days · 1,234 frames · 2 done`.
    public let subtitle: String
    public let months: [CullMonth]

    public var id: String { year }
}

/// The days a search found, in the order the server ranked them.
public struct CullSearchResult: Sendable, Hashable {
    /// The trimmed query this answers.
    public let query: String
    /// `3 days · 12 photos, by words and captions.` or `No days match.`
    public let summary: String
    /// Notes to show under the summary, such as a failure or part of search being unavailable.
    public let notes: [String]
    public let rows: [CullDayRow]
}

/// State of the Cull tab's home, as `showDays`, `dayListHTML`, `daysByDate` and `runSearch` keep
/// it in `app.js`: the days grouped as In progress, On this day and by year and month, and a
/// search over them. The Place view and More like this are not here.
@MainActor
@Observable
public final class CullDaysModel {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// Days started but not finished, newest first.
    public private(set) var inProgress: [CullDayRow] = []
    /// Unculled days from this week in earlier years, at most four.
    public private(set) var onThisDay: [CullDayRow] = []
    /// The rest, by year and then month, in the order the server lists them.
    public private(set) var years: [CullYear] = []
    /// Years that are open. The newest starts open; keep it between launches if you like.
    public private(set) var openYears: Set<String>
    /// Why the last `refresh()` failed while an earlier result is still on screen; nil otherwise.
    public private(set) var refreshError: String?
    /// The search box. Setting it runs a search 280 ms after the last change.
    public var searchText: String {
        didSet { searchTextChanged() }
    }
    /// The last search that was answered. It can be of an older query: see `isSearching`.
    public var searchResult: CullSearchResult? { found.map(makeResult) }

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let sleep: CullSleep
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var hasOpenState: Bool
    @ObservationIgnored private var days: [Day] = []
    private var dayByID: [String: Day] = [:]
    private var found: (query: String, answer: DaySearchResult)?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchSeq = 0

    static let searchDelay: Duration = .milliseconds(280)

    /// `openYears` restores which years were open; nil opens the newest. `now` and `timeZone`
    /// decide what On this day and Resting mean; tests pin them.
    public init(
        client: CullingBayClient, openYears: Set<String>? = nil,
        now: @escaping () -> Date = { Date() }, timeZone: TimeZone = .current,
        sleep: @escaping CullSleep = CullClock.system
    ) {
        self.client = client
        self.now = now
        self.timeZone = timeZone
        self.sleep = sleep
        self.openYears = openYears ?? []
        self.hasOpenState = openYears != nil
        self.searchText = ""
    }

    // MARK: Loading

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

    public func isYearOpen(_ year: String) -> Bool { openYears.contains(year) }

    public func toggleYear(_ year: String) {
        if !openYears.insert(year).inserted { openYears.remove(year) }
        hasOpenState = true
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
            let message = GalleryMessages.failure(error, loading: "the days")
            if hasLoaded {
                refreshError = message
            } else {
                phase = .failed(message)
            }
        }
    }

    private func apply(_ list: [Day]) {
        days = list
        dayByID = Dictionary(list.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        inProgress = list.filter { $0.decided > 0 && !$0.finished }.map { row($0) }
        let rest = list.filter { !($0.decided > 0 && !$0.finished) }
        onThisDay = earlierYears().map { row($0) }
        years = group(rest)
        if !hasOpenState, let newest = years.first {
            openYears = [newest.year]
            hasOpenState = true
        }
        hasLoaded = true
        refreshError = nil
        phase = .loaded
    }

    // MARK: Grouping

    private func yearOf(_ day: Day) -> String { String(day.day.prefix(4)) }

    /// `daysByDate`: years in the order they first appear, each with its months likewise.
    private func group(_ list: [Day]) -> [CullYear] {
        var order: [String] = []
        for day in list {
            let year = yearOf(day)
            if !order.contains(year) { order.append(year) }
        }
        return order.map { year in
            let ofYear = list.filter { yearOf($0) == year }
            let frames = ofYear.reduce(0) { $0 + $1.frames }
            let done = ofYear.filter { $0.finished || lightroomCulled($0) }.count
            var subtitle = "\(ofYear.count) day" + (ofYear.count > 1 ? "s" : "")
                + " · \(CullFormat.grouped(frames)) frames"
            if done > 0 { subtitle += " · \(done) done" }
            var names: [String] = []
            for day in ofYear {
                let name = monthName(day)
                if !names.contains(name) { names.append(name) }
            }
            let months = names.map { name in
                let inMonth = ofYear.filter { monthName($0) == name }
                return CullMonth(
                    name: name, rows: inMonth.map { row($0) }, title: "\(name) · \(inMonth.count)",
                    id: year + "/" + name)
            }
            return CullYear(year: year, subtitle: subtitle, months: months)
        }
    }

    private func monthName(_ day: Day) -> String {
        guard let month = day.isoDate?.month else { return "Other folders" }
        return LibraryIndex.monthNames[month - 1]
    }

    /// `lrCulled`: every stack was already flagged or rated in Lightroom, and the phone has done nothing.
    private func lightroomCulled(_ day: Day) -> Bool {
        day.decided == 0 && !day.finished && day.stacks > 0 && day.lrDone >= day.stacks
    }

    /// `resting`: shot under 48 hours ago and not started.
    private func resting(_ day: Day) -> Bool {
        day.decided == 0 && !day.finished && day.lastTs != 0
            && now().timeIntervalSince1970 - day.lastTs < 48 * 3600
    }

    /// `onThisDay`: unculled days within three days of today's month and day in earlier years.
    private func earlierYears() -> [Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.dateComponents([.year, .month, .day], from: now())
        guard let thisYear = today.year, let month = today.month, let dayOfMonth = today.day else { return [] }
        let target = Self.ordinal(month: month, day: dayOfMonth)
        let found = days.filter { day in
            guard let parts = day.isoDate, let y = parts.year, let m = parts.month, let d = parts.day,
                  y < thisYear, day.decided == 0, !day.finished, !lightroomCulled(day)
            else { return false }
            let gap = abs(Self.ordinal(month: m, day: d) - target)
            return min(gap, 366 - gap) <= 3
        }
        return Array(found.prefix(4))
    }

    /// The day's place in a leap year (1...366).
    private static func ordinal(month: Int, day: Int) -> Int {
        let lengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return lengths.prefix(month - 1).reduce(0, +) + day
    }

    // MARK: Rows

    private func row(_ day: Day, hit: DayMatch? = nil, query: String = "") -> CullDayRow {
        let percent = day.frames > 0
            ? Int((Double(day.decided) / Double(day.frames) * 100).rounded()) : 0
        let tag: CullDayRow.Tag?
        if day.conflicts > 0 {
            tag = .init(text: "\(day.conflicts) conflict" + (day.conflicts > 1 ? "s" : ""), style: .warn)
        } else if day.landed > 0 {
            tag = .init(text: "Synced", style: .quiet)
        } else if let sentAt = day.sentAt, !sentAt.isEmpty {
            tag = .init(text: "Sent", style: .quiet)
        } else if day.finished {
            tag = .init(text: "Done", style: .quiet)
        } else if lightroomCulled(day) {
            tag = .init(text: "In Lightroom", style: .quiet)
        } else if day.decided > 0 {
            tag = .init(text: "\(percent)%", style: .normal)
        } else if resting(day) {
            tag = .init(text: "Resting", style: .quiet)
        } else {
            tag = nil
        }
        var meta = ["\(day.frames) frames", "\(day.stacks) stacks"]
        if day.lrDone > 0 && day.lrDone < day.stacks { meta.append("\(day.lrDone) done in Lightroom") }
        if day.date?.isEmpty ?? true { meta.append(day.day) }
        // A search hit shows its matching photos first, topped up from the day's own.
        var thumbs = day.thumbs
        if let hit, !hit.ids.isEmpty {
            thumbs = hit.ids + day.thumbs.filter { !hit.ids.contains($0) }
        }
        let why = hit.flatMap { $0.why.isEmpty ? nil : $0.why }
        let summary = why == nil ? day.summary.flatMap { $0.isEmpty ? nil : $0 } : nil
        let match = hit.flatMap { $0.matchIDs.isEmpty ? nil : CullMatch(ids: $0.matchIDs, label: "“\(query)”") }
        return CullDayRow(
            day: day, title: CullFormat.dayTitle(date: day.date, folder: day.folder),
            meta: meta.joined(separator: " · "), place: day.place.flatMap(Self.placeLine),
            thumbs: Array(thumbs.prefix(3)), tag: tag, percent: percent, showsBar: day.decided > 0,
            why: why, summary: summary, match: match)
    }

    /// `town` in app.js: the first two comma-separated parts, as stored.
    static func placeLine(_ place: String) -> String? {
        let parts = place.components(separatedBy: ", ").prefix(2).joined(separator: ", ")
        return parts.isEmpty ? nil : parts
    }

    // MARK: Search

    /// The box holds something: show the search result in place of the list.
    public var isShowingSearch: Bool { !trimmedQuery.isEmpty }

    /// The query is on its way, or the result on screen answers an older one.
    public var isSearching: Bool {
        !trimmedQuery.isEmpty && found?.query != trimmedQuery
    }

    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `runSearch`: ask 280 ms after the last keystroke; an answer to an older query is dropped.
    private func searchTextChanged() {
        searchTask?.cancel()
        searchTask = nil
        let query = trimmedQuery
        guard !query.isEmpty else { return }
        let sleep = self.sleep
        searchTask = Task {
            do { try await sleep(Self.searchDelay) } catch { return }
            guard !Task.isCancelled else { return }
            searchSeq += 1
            let mine = searchSeq
            let answer: DaySearchResult
            do {
                answer = try await client.daySearch(query)
            } catch {
                if error is CancellationError { return }
                answer = DaySearchResult(
                    days: [], photos: 0, signals: [],
                    notes: ["Search failed: " + CullFormat.errorText(error)])
            }
            guard mine == searchSeq, trimmedQuery == query else { return }
            found = (query, answer)
        }
    }

    private static let signalNames = [
        "words": "words", "captions": "captions", "pictures": "what’s in the pictures",
    ]

    /// `hitsHTML`: only days the list holds are shown.
    private func makeResult(_ found: (query: String, answer: DaySearchResult)) -> CullSearchResult {
        let hits = found.answer.days.filter { dayByID[$0.day] != nil }
        let signals = found.answer.signals.compactMap { Self.signalNames[$0] }
        var summary = "No days match."
        if !hits.isEmpty {
            summary = "\(hits.count) day" + (hits.count == 1 ? "" : "s")
            if found.answer.photos > 0 {
                summary += " · \(CullFormat.grouped(found.answer.photos)) photo"
                    + (found.answer.photos == 1 ? "" : "s")
            }
            if !signals.isEmpty { summary += ", by " + Self.andList(signals) }
            summary += "."
        }
        return CullSearchResult(
            query: found.query, summary: summary, notes: found.answer.notes,
            rows: hits.compactMap { hit in dayByID[hit.day].map { row($0, hit: hit, query: found.query) } })
    }

    private static func andList(_ items: [String]) -> String {
        items.count > 1 ? items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
            : items.first ?? ""
    }
}
