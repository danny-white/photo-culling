import Foundation

/// Defaults for `GallerySettings`.
public enum GalleryDefaults {
    public static let best = false
    public static let bursts = true
    /// The PC on the tailnet.
    public static let serverURL = URL(string: "http://100.82.57.4:8000")!
}

/// What the gallery remembers between launches. The models read and write it on the main actor,
/// so a conforming type needs no locking. Setting `openYears` or `openMonths` also makes
/// `hasOpenState` true.
@MainActor
public protocol GallerySettings: AnyObject {
    /// The Best filter ("★ Best").
    var best: Bool { get set }
    /// The "1 per burst" filter.
    var bursts: Bool { get set }
    /// Years open on the home page.
    var openYears: Set<String> { get set }
    /// Months open on the home page, as `LibraryIndex.Month.key`.
    var openMonths: Set<String> { get set }
    /// Whether open years and months were ever saved. False on the first visit, when the home
    /// page opens the newest year and month.
    var hasOpenState: Bool { get }
    var serverURL: URL { get set }
}

/// Settings kept in memory, for tests and previews.
@MainActor
public final class InMemoryGallerySettings: GallerySettings {
    public var best: Bool
    public var bursts: Bool
    public var openYears: Set<String> {
        didSet { hasOpenState = true }
    }
    public var openMonths: Set<String> {
        didSet { hasOpenState = true }
    }
    public private(set) var hasOpenState: Bool
    public var serverURL: URL

    public init(
        best: Bool = GalleryDefaults.best, bursts: Bool = GalleryDefaults.bursts,
        openYears: Set<String>? = nil, openMonths: Set<String>? = nil,
        serverURL: URL = GalleryDefaults.serverURL
    ) {
        self.best = best
        self.bursts = bursts
        self.openYears = openYears ?? []
        self.openMonths = openMonths ?? []
        self.hasOpenState = openYears != nil || openMonths != nil
        self.serverURL = serverURL
    }
}

/// Settings in `UserDefaults`, under the keys `gallery.best`, `gallery.bursts`, `gallery.open`
/// (JSON `{"years": [...], "months": [...]}`, as the web gallery stores it) and `server.url`.
@MainActor
public final class UserDefaultsGallerySettings: GallerySettings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var best: Bool {
        get { defaults.object(forKey: "gallery.best") as? Bool ?? GalleryDefaults.best }
        set { defaults.set(newValue, forKey: "gallery.best") }
    }

    public var bursts: Bool {
        get { defaults.object(forKey: "gallery.bursts") as? Bool ?? GalleryDefaults.bursts }
        set { defaults.set(newValue, forKey: "gallery.bursts") }
    }

    public var openYears: Set<String> {
        get { openState?.years ?? [] }
        set { openState = OpenState(years: newValue, months: openMonths) }
    }

    public var openMonths: Set<String> {
        get { openState?.months ?? [] }
        set { openState = OpenState(years: openYears, months: newValue) }
    }

    public var hasOpenState: Bool { openState != nil }

    public var serverURL: URL {
        get {
            defaults.string(forKey: "server.url").flatMap { URL(string: $0) }
                ?? GalleryDefaults.serverURL
        }
        set { defaults.set(newValue.absoluteString, forKey: "server.url") }
    }

    private struct OpenState: Codable {
        var years: Set<String>
        var months: Set<String>
    }

    /// Nil when nothing was saved or the saved text cannot be read.
    private var openState: OpenState? {
        get {
            defaults.data(forKey: "gallery.open")
                .flatMap { try? JSONDecoder().decode(OpenState.self, from: $0) }
        }
        set {
            guard let newValue else { return defaults.removeObject(forKey: "gallery.open") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            defaults.set(try? encoder.encode(newValue), forKey: "gallery.open")
        }
    }
}
