import Foundation

/// Strings and small helpers the Cull tab shares, ported from `app.js`. Pure and deterministic,
/// with no locale: the web app's text is English (British spelling) whatever the phone is set to.
public enum CullFormat {
    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    /// `en-GB` short months, with `Sept` as current ICU prints it.
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"]

    /// `stem` in app.js: a file name without its last extension, `DSC05040.ARW` to `DSC05040`.
    public static func stem(_ file: String) -> String {
        guard let dot = file.lastIndex(of: "."), file.index(after: dot) != file.endIndex else { return file }
        return String(file[..<dot])
    }

    /// `starText`: `"★★★"`, empty for 0.
    public static func starText(_ n: Int) -> String {
        n > 0 ? String(repeating: "★", count: n) : ""
    }

    /// `dayTitle`: `"Sat, 17 Oct 2026"` for a dated day, else the folder name.
    public static func dayTitle(date: String?, folder: String) -> String {
        guard let date, let parts = parseISODate(date), let year = parts.year, let month = parts.month,
              let day = parts.day
        else { return folder }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        else { return folder }
        return "\(weekdays[calendar.component(.weekday, from: noon) - 1]), \(day) \(months[month - 1]) \(year)"
    }

    /// `n.toLocaleString()` as en-US prints it: `1,234`.
    static func grouped(_ n: Int) -> String {
        var out = ""
        for (index, digit) in String(abs(n)).reversed().enumerated() {
            if index > 0, index % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    /// A number the way JavaScript prints it: `2`, not `2.0`.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// `e.message` in app.js: the server's `error` text, else `HTTP <status>`.
    static func errorText(_ error: any Error) -> String {
        guard let error = error as? CullingBayError else { return error.localizedDescription }
        switch error {
        case .http(let status, let message): return message ?? "HTTP \(status)"
        case .conflict(let message, _): return message ?? "HTTP 409"
        case .unavailable(let message): return message ?? "HTTP 503"
        case .decoding(let message), .transport(let message): return message
        }
    }
}
