import Foundation
import Observation

/// State of one results screen (a search, a "like", or one day), as `route()` and `renderGrid`
/// in `gallery.js` keep it. Make a new model per screen.
@MainActor
@Observable
public final class FeedModel {
    /// What the screen shows.
    public enum Source: Sendable, Hashable {
        case search(String)
        /// Photos like photo `id`. `file` is that photo's file name, when known.
        case like(Int, file: String?)
        /// A day id such as `2026/2026-10-01`.
        case day(String)
        /// The photos a named person is in. `name` is for the title.
        case person(Int, name: String)
        /// The photos of an unnamed group's faces, by the group's key.
        case group(Int)

        /// The route name `gallery.js` reports with `results_ready`: `q`, `like` or `day`; the People
        /// screens are `person` and `group`.
        public var screen: String {
            switch self {
            case .search: "q"
            case .like: "like"
            case .day: "day"
            case .person: "person"
            case .group: "group"
            }
        }
    }

    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public let source: Source
    /// The Best filter. Change it with `setBest(_:)`.
    public private(set) var best: Bool
    /// The "1 per burst" filter. Change it with `setBursts(_:)`.
    public private(set) var bursts: Bool
    public private(set) var phase: Phase = .idle
    /// The photos in display order. The previous result stays here while a reload is in flight.
    public private(set) var photos: [Photo] = []
    /// Matches before the Best and bursts filters (the photo count for a day).
    public private(set) var total = 0
    public private(set) var notes: [String] = []
    /// What matched: `words`, `captions`, `pictures`, `dates`.
    public private(set) var signals: [String] = []

    public private(set) var isSelecting = false
    public private(set) var selected: Set<Int> = []
    /// How many times tiles were taken out of the grid or put back by `remove` and `restore`. A view
    /// animates on this, so a tile sliding out is animated and a load replacing the photos is not.
    public private(set) var edits = 0

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let settings: any GallerySettings
    @ObservationIgnored private var generation = 0
    /// What a day load said about the day; nil until one has.
    private var loadedDay: GalleryDay?
    private var hasResult = false

    public init(source: Source, client: CullingBayClient, settings: any GallerySettings) {
        self.source = source
        self.client = client
        self.settings = settings
        self.best = settings.best
        self.bursts = settings.bursts
    }

    // MARK: Loading

    /// Loads the photos for the current filters. If another load starts before this one
    /// finishes, this one's answer is dropped, whichever finishes first.
    public func load() async {
        generation += 1
        let mine = generation
        phase = .loading
        do {
            let loaded = try await fetch()
            guard mine == generation else { return }
            apply(loaded)
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled {
                phase = hasResult ? .loaded : .idle
            } else {
                phase = .failed(GalleryMessages.failure(error, loading: "that"))
            }
        }
    }

    /// Sets the Best filter, saves it, and reloads.
    public func setBest(_ on: Bool) async {
        best = on
        settings.best = on
        await load()
    }

    /// Sets the "1 per burst" filter, saves it, and reloads.
    public func setBursts(_ on: Bool) async {
        bursts = on
        settings.bursts = on
        await load()
    }

    private struct Loaded: Sendable {
        var photos: [Photo]
        var total: Int
        var notes: [String]
        var signals: [String]
        var day: GalleryDay?
    }

    private func fetch() async throws -> Loaded {
        switch source {
        case .search(let query):
            let list = try await client.search(query, best: best, bursts: bursts)
            return Loaded(photos: list.photos, total: list.total, notes: list.notes, signals: list.signals)
        case .like(let id, _):
            let list = try await client.like(id, best: best, bursts: bursts)
            return Loaded(photos: list.photos, total: list.total, notes: list.notes, signals: list.signals)
        case .day(let day):
            let body = try await client.galleryDay(day, best: best, bursts: bursts)
            return Loaded(
                photos: body.photos, total: body.photos.count, notes: [], signals: [], day: body)
        case .person(let id, _):
            let body = try await client.personPhotos(id, best: best, bursts: bursts)
            return Loaded(photos: body.photos, total: body.total, notes: [], signals: [])
        case .group(let key):
            let body = try await client.groupPhotos(key, best: best, bursts: bursts)
            return Loaded(photos: body.photos, total: body.total, notes: [], signals: [])
        }
    }

    private func apply(_ result: Loaded) {
        photos = result.photos
        total = result.total
        notes = result.notes
        signals = result.signals
        loadedDay = result.day
        selected.formIntersection(result.photos.map(\.id))
        hasResult = true
        phase = .loaded
    }

    // MARK: What the screen says

    /// The notes joined into one paragraph.
    public var note: String { notes.joined(separator: " ") }

    public var title: String {
        switch source {
        case .search(let query):
            return "“\(query)”"
        case .like:
            return "Similar photos"
        case .day(let day):
            if let loadedDay { return GalleryFormat.longDate(loadedDay.date) }
            return GalleryFormat.longDate(day.split(separator: "/").last.map(String.init))
        case .person(_, let name):
            return name
        case .group:
            return "Not named yet"
        }
    }

    /// `"Loading…"`, then for a day `"Seattle · 16 photos · Dune walk"` and otherwise
    /// `"120 photos · best only (top 120 of 340)"`. Empty after a first load fails.
    public var subtitle: String {
        guard hasResult else {
            if case .failed = phase { return "" }
            return "Loading…"
        }
        let count = GalleryFormat.photoCount(photos.count) + (best ? " · best only" : "")
        if case .day = source {
            let first = photos.first { $0.place != nil }
            return [first.flatMap { town($0.place) }, count, loadedDay?.summary]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let more = total > photos.count && !best && !bursts ? " (top \(photos.count) of \(total))" : ""
        return count + more
    }

    /// What to show in place of an empty grid.
    public var emptyMessage: String {
        if best { return "Nothing you picked or rated 3★ or more. Turn off ★ Best to see everything." }
        if case .group = source { return "Nothing is left in this group. Its faces have been named or hidden." }
        return "No photos found."
    }

    /// Whether tiles carry their date: results from many days do; a single day does not.
    public var showsDates: Bool {
        if case .day = source { false } else { true }
    }

    // MARK: Taking tiles out and putting them back

    /// Tiles `remove(_:lowersTotalBy:)` took out of the grid, and where each was, so `restore(_:)` can
    /// put them back. It remembers which load the grid was from: after another load the old places
    /// mean nothing.
    public struct RemovedTiles: Sendable, Hashable {
        public struct Tile: Sendable, Hashable {
            public let index: Int
            public let photo: Photo
        }

        /// In grid order.
        public let tiles: [Tile]
        let total: Int
        let generation: Int

        public var isEmpty: Bool { tiles.isEmpty }
    }

    /// Takes these photos out of the grid at once, without asking the server again, and lowers `total`
    /// by `dropped` (the photos of the person the screen is about that went, which a tile standing for a
    /// burst counts more than once). The person's screen uses it after "Not Alex" has been saved.
    @discardableResult
    public func remove(_ ids: Set<Int>, lowersTotalBy dropped: Int = 0) -> RemovedTiles {
        let tiles = photos.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { RemovedTiles.Tile(index: $0.offset, photo: $0.element) }
        photos.removeAll { ids.contains($0.id) }
        selected.subtract(ids)
        total = max(0, total - dropped)
        if !tiles.isEmpty { edits += 1 }
        return RemovedTiles(tiles: tiles, total: dropped, generation: generation)
    }

    /// Puts tiles back where `remove` found them. Answers false, and puts nothing back, when the grid
    /// has been loaded again since (its places are not these any more): the caller loads it instead.
    @discardableResult
    public func restore(_ removed: RemovedTiles) -> Bool {
        guard removed.generation == generation else { return false }
        let present = Set(photos.map(\.id))
        for tile in removed.tiles where !present.contains(tile.photo.id) {
            photos.insert(tile.photo, at: min(tile.index, photos.count))
        }
        total += removed.total
        if photos.count > present.count { edits += 1 }
        return true
    }

    // MARK: Selection

    public func beginSelection() { isSelecting = true }

    /// Selects or deselects a photo. Does nothing unless the screen is selecting.
    public func toggleSelect(_ id: Int) {
        guard isSelecting else { return }
        if !selected.insert(id).inserted { selected.remove(id) }
    }

    /// The selected photos in display order.
    public var selectedPhotos: [Photo] { photos.filter { selected.contains($0.id) } }

    /// Deselects everything and stays in selection mode.
    public func clearSelection() { selected = [] }

    /// Leaves selection mode and deselects everything.
    public func endSelection() {
        isSelecting = false
        selected = []
    }
}
