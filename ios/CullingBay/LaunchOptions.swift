import CullingBayCore
import Foundation

/// Launch arguments for looking at a screen in the simulator, where nothing can tap:
/// `-CBStartTab cull` starts on the Cull tab, and `-CBOpenDay 2026/2026-10-01` also opens that
/// day. They only choose what to show. Opening a day reads it and sends nothing.
///
/// Further into a day, all of them looking and none of them acting:
/// - `-CBOpenStack 3` puts the card on the fourth stack (without saving the position);
/// - `-CBOpenPicker 1` opens the burst picker on the card's burst, and `-CBPickerFrame 2` shows
///   its third frame;
/// - `-CBOpenFocus 1` opens the 1:1 focus check on the card (or on the picker's frame, with
///   `-CBOpenPicker`), `-CBLinked 1` turns linked zoom on, and `-CBFocusStep 1` steps on to the
///   next frame once the first page is in place, to show the same spot on it;
/// - `-CBReadOnly 1` refuses every request that is not a GET, so nothing can reach the server
///   (a decision, an undo, a saved position, a Send, or a timing report).
enum LaunchOptions {
    static var startsOnCull: Bool {
        UserDefaults.standard.string(forKey: "CBStartTab") == "cull"
    }

    /// A day id such as `2026/2026-10-01`.
    static var openDay: String? {
        UserDefaults.standard.string(forKey: "CBOpenDay").flatMap { $0.isEmpty ? nil : $0 }
    }

    static var openStack: Int? { integer("CBOpenStack") }
    static var openPicker: Bool { UserDefaults.standard.bool(forKey: "CBOpenPicker") }
    static var pickerFrame: Int? { integer("CBPickerFrame") }
    static var openFocus: Bool { UserDefaults.standard.bool(forKey: "CBOpenFocus") }
    static var linked: Bool { UserDefaults.standard.bool(forKey: "CBLinked") }
    static var focusSteps: Int { integer("CBFocusStep") ?? 0 }
    static var readOnly: Bool { UserDefaults.standard.bool(forKey: "CBReadOnly") }

    private static func integer(_ key: String) -> Int? {
        UserDefaults.standard.string(forKey: key).flatMap { Int($0) }
    }

    /// Puts an opened day on the screen the arguments ask for. Nothing is decided or saved.
    @MainActor
    static func apply(to session: CullSessionModel) {
        if let stack = openStack { session.look(at: stack) }
        if openPicker {
            session.openPicker()
            if let frame = pickerFrame { session.picker?.show(frame) }
        }
        if openFocus {
            session.openFocus()
            session.focus?.setLinked(linked)
        }
    }
}
