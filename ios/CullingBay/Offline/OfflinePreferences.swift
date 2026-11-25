import CullingBayCore
import Foundation

/// Settings for keeping days on the phone. The first three are plain `UserDefaults` keys, which
/// the Settings screen binds with `@AppStorage`, so they apply at once; the pins are a JSON
/// object of day id to `auto`, `always` or `never`.
enum OfflinePreferences {
    /// Whether to keep days on the phone. Off unless turned on in Settings.
    static let enabled = "offlineEnabled"
    /// How much to keep, in gigabytes.
    static let limitGB = "offlineLimitGB"
    /// Whether to keep the 1:1 crop at each frame's AF point.
    static let crops = "offlineCrops"
    /// Danny's choices for single days, as JSON: `{"2026/2026-10-01": "always"}`.
    static let pins = "offlinePins"

    static let defaultLimitGB = 2.0
    static let limitRange: ClosedRange<Double> = 0.5...10

    /// The settings as they stand, for code that does not sit in a view.
    typealias Values = OfflineSettings

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabled) }

    /// A key that was never set reads as its default, which `bool(forKey:)` cannot say for a
    /// default of true.
    static func current() -> Values {
        let defaults = UserDefaults.standard
        let limit = (defaults.object(forKey: limitGB) as? Double) ?? defaultLimitGB
        return Values(
            isEnabled: defaults.bool(forKey: enabled),
            limitGB: min(max(limit, limitRange.lowerBound), limitRange.upperBound),
            includeCrops: (defaults.object(forKey: crops) as? Bool) ?? true)
    }

    static func loadPins() -> [String: OfflinePin] {
        guard let data = UserDefaults.standard.data(forKey: pins),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return raw.compactMapValues { OfflinePin(rawValue: $0) }
    }

    /// `auto` is the absence of a pin, so it is not written.
    static func savePins(_ value: [String: OfflinePin]) {
        let raw = value.filter { $0.value != .auto }.mapValues(\.rawValue)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: pins)
    }
}

/// `OfflinePreferences` as the settings `OfflineSync` reads, each read going to `UserDefaults`.
struct UserDefaultsOfflineSettings: OfflineSettingsSource {
    var isEnabled: Bool { OfflinePreferences.isEnabled }
    func current() -> OfflineSettings { OfflinePreferences.current() }
    func loadPins() -> [String: OfflinePin] { OfflinePreferences.loadPins() }
    func savePins(_ pins: [String: OfflinePin]) { OfflinePreferences.savePins(pins) }
}
