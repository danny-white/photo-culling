import Foundation

/// The gallery's display strings, ported from `gallery.js`. Pure and deterministic: the zone and
/// locale are parameters, so a test can pin them.
public enum GalleryFormat {
    static let monthAbbreviations = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    static let weekdayAbbreviations = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// `"Sat, Oct 17 2026"`. `"Undated"` for nil; a string that is not a real `YYYY-MM-DD` date
    /// comes back unchanged (a folder named `unsorted` stays readable).
    public static func longDate(_ iso: String?) -> String {
        guard let iso else { return "Undated" }
        guard let parts = parseISODate(iso), let year = parts.year, let month = parts.month,
              let day = parts.day
        else { return iso }
        return "\(weekdayAbbreviations[weekday(year: year, month: month, day: day)]), "
            + "\(monthAbbreviations[month - 1]) \(day) \(year)"
    }

    /// `"Oct 17 ’26"`. Empty for nil or a malformed date.
    public static func shortDate(_ iso: String?) -> String {
        guard let parts = parseISODate(iso), let year = parts.year, let month = parts.month,
              let day = parts.day
        else { return "" }
        return "\(monthAbbreviations[month - 1]) \(day) ’" + String(format: "%02d", year % 100)
    }

    /// The capture time of day, such as `"3:41 PM"` in en_US. `ts` is `Photo.ts`: format it in
    /// the phone's own zone (the default) to show the time the camera displayed. Empty for nil
    /// or 0. Recent ICU versions put a narrow no-break space before `PM`.
    public static func time(
        _ ts: Double?, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        guard let ts, ts != 0 else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }

    /// A file size: `"12 MB"` from 10 MB up, `"3.4 MB"` below. Empty for nil or 0.
    public static func megabytes(_ bytes: Int?) -> String {
        guard let bytes, bytes != 0 else { return "" }
        let mb = Double(bytes) / 1e6
        return (mb >= 10 ? String(Int(mb.rounded())) : String(format: "%.1f", mb)) + " MB"
    }

    /// `"1 photo"`, `"1,234 photos"`.
    public static func photoCount(_ n: Int, locale: Locale = .current) -> String {
        "\(grouped(n, locale: locale)) photo" + (n == 1 ? "" : "s")
    }

    /// `"1 day"`, `"12 days"`.
    public static func dayCount(_ n: Int) -> String {
        "\(n) day" + (n == 1 ? "" : "s")
    }

    /// `"★★★"`, capped at five. Empty for 0 or less.
    public static func stars(_ n: Int) -> String {
        String(repeating: "★", count: min(max(n, 0), 5))
    }

    private static func grouped(_ n: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// 0 = Sunday, for a Gregorian date (Sakamoto's method, so no calendar or zone is involved).
    private static func weekday(year: Int, month: Int, day: Int) -> Int {
        let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let y = month < 3 ? year - 1 : year
        return (y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + day) % 7
    }
}
