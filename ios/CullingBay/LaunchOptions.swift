import Foundation

/// Launch arguments for looking at a screen in the simulator, where nothing can tap:
/// `-CBStartTab cull` starts on the Cull tab, and `-CBOpenDay 2026/2026-10-01` also opens that
/// day. They only choose what to show. Opening a day reads it and sends nothing.
enum LaunchOptions {
    static var startsOnCull: Bool {
        UserDefaults.standard.string(forKey: "CBStartTab") == "cull"
    }

    /// A day id such as `2026/2026-10-01`.
    static var openDay: String? {
        UserDefaults.standard.string(forKey: "CBOpenDay").flatMap { $0.isEmpty ? nil : $0 }
    }
}
