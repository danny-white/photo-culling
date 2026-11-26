import Foundation

/// One line of the (i) sheet: a label and what the file says.
public struct PhotoInfoRow: Sendable, Hashable, Identifiable {
    public let label: String
    public let value: String

    public var id: String { label }

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A titled group of rows in the (i) sheet.
public struct PhotoInfoSection: Sendable, Hashable, Identifiable {
    public let title: String
    public let rows: [PhotoInfoRow]

    public var id: String { title }

    public init(_ title: String, _ rows: [PhotoInfoRow]) {
        self.title = title
        self.rows = rows
    }
}

/// The wording of the (i) sheet: a photo's camera details as short text. Pure, so a test can pin
/// it. A value the file lacks (or that makes no sense, such as an ISO of 0) comes back nil, and
/// the sheet leaves that row out. The locale is a parameter where it matters.
public enum PhotoInfoFormat {
    private static let minus = "\u{2212}"

    // MARK: One value at a time

    /// `1/2500 s`, `0.3 s`, `2.5 s`, `30 s`. Under a second it is a fraction when 1/s is within 5%
    /// of a whole number (so 0.0588 is `1/17 s`) and a decimal otherwise (`0.3 s`). A time that
    /// would read `1/1 s` is written as a decimal too.
    public static func shutter(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 1 {
            let n = 1 / seconds
            let whole = n.rounded()
            if whole >= 2, abs(n - whole) <= 0.05 * whole { return "1/\(Int(whole)) s" }
        }
        return "\(oneDecimal(seconds)) s"
    }

    /// `f/4`, `f/2.8`, `f/1.8`.
    public static func aperture(_ fNumber: Double?) -> String? {
        guard let fNumber, fNumber.isFinite, fNumber > 0 else { return nil }
        return "f/\(oneDecimal(fNumber))"
    }

    /// `ISO 100`, `ISO 12,800`: grouped from 10,000 up.
    public static func iso(_ iso: Int?, locale: Locale = .current) -> String? {
        isoNumber(iso, locale: locale).map { "ISO \($0)" }
    }

    /// The number alone, for the row labelled ISO: `100`, `12,800`.
    public static func isoNumber(_ iso: Int?, locale: Locale = .current) -> String? {
        guard let iso, iso > 0 else { return nil }
        guard iso >= 10_000 else { return String(iso) }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: iso)) ?? String(iso)
    }

    /// `40 mm`, or `6.8 mm (24 mm full-frame)` when the full-frame equivalent is 1 mm or more from
    /// the focal length shown. Whole millimetres from 10 mm up, one decimal below.
    public static func focalLength(_ mm: Double?, equivalent: Double? = nil) -> String? {
        guard let mm, mm.isFinite, mm > 0 else { return nil }
        let shown = mm >= 10 ? mm.rounded() : (mm * 10).rounded() / 10
        let text = "\(mm >= 10 ? String(Int(shown)) : oneDecimal(shown)) mm"
        guard let equivalent, equivalent.isFinite, equivalent > 0, abs(equivalent - shown) >= 1 else {
            return text
        }
        return "\(text) (\(Int(equivalent.rounded())) mm full-frame)"
    }

    /// `−0.7 EV`, `+0.3 EV`, `0 EV`, with a real minus sign.
    public static func exposureComp(_ ev: Double?) -> String? {
        guard let ev, ev.isFinite else { return nil }
        let size = oneDecimal(abs(ev))
        guard size != "0" else { return "0 EV" }
        return "\(ev < 0 ? minus : "+")\(size) EV"
    }

    /// `43.2 MB`: decimal units, as the Files app shows them (`512 bytes`, `4.1 KB`, `1.2 GB`).
    public static func size(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        guard bytes >= 1000 else { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1000
        var step = 0
        // 999.96 KB reads as 1000.0 KB once rounded, so it moves up a unit instead.
        while step < units.count - 1, (value * 10).rounded() >= 10_000 {
            value /= 1000
            step += 1
        }
        return "\(oneDecimal(value)) \(units[step])"
    }

    /// `8000 × 5320 · 42.6 MP`. The megapixels are the server's, else worked out from the size.
    /// Whichever part is not known is left out.
    public static func resolution(width: Int?, height: Int?, megapixels: Double?) -> String? {
        var parts: [String] = []
        let hasSize = (width ?? 0) > 0 && (height ?? 0) > 0
        if let width, let height, hasSize { parts.append("\(width) × \(height)") }
        var mp = megapixels.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if mp == nil, let width, let height, hasSize { mp = Double(width) * Double(height) / 1e6 }
        if let mp { parts.append("\(oneDecimal(mp)) MP") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `Tue, Sep 29 2026 · 3:35:35 PM UTC−7`. `taken` is the camera's clock as `YYYY:MM:DD
    /// HH:MM:SS`, with an optional `.fraction` that is ignored, and it is shown as it reads, with no
    /// shift to another zone. `offset` (`-07:00`) only adds the zone. Nil when `taken` cannot be read.
    public static func taken(_ taken: String?, offset: String? = nil, locale: Locale = .current) -> String? {
        guard let taken, let when = parseTaken(taken) else { return nil }
        let date = GalleryFormat.longDate(when.date)
        let time = clock(when.seconds, locale: locale)
        let zone = offset.flatMap(zoneName)
        return "\(date) · \(time)" + (zone.map { " \($0)" } ?? "")
    }

    /// `19.42863, −99.16605`: five decimals, with a real minus sign.
    public static func coordinates(_ gps: PhotoInfo.Coordinates?) -> String? {
        guard let gps, gps.latitude.isFinite, gps.longitude.isFinite else { return nil }
        return "\(degrees(gps.latitude)), \(degrees(gps.longitude))"
    }

    // MARK: The sheet

    /// The line at the top of the sheet: `1/2500 s · f/4 · ISO 100 · 40 mm`, leaving out what is
    /// missing. The focal length is the plain one, without the full-frame note (the rows have it).
    /// Nil when nothing is known.
    public static func summary(_ info: PhotoInfo, locale: Locale = .current) -> String? {
        let parts = [
            shutter(info.shutterSeconds), aperture(info.aperture), iso(info.iso, locale: locale),
            focalLength(info.focalMM),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The sheet's rows in sections, in order: Exposure, Camera, File, Taken, Place. A row with no
    /// value is left out, and so is a section with no rows.
    public static func sections(_ info: PhotoInfo, locale: Locale = .current) -> [PhotoInfoSection] {
        let all: [(String, [(String, String?)])] = [
            ("Exposure", [
                ("Shutter", shutter(info.shutterSeconds)),
                ("Aperture", aperture(info.aperture)),
                ("ISO", isoNumber(info.iso, locale: locale)),
                ("Exposure comp.", exposureComp(info.ev)),
                ("Focal length", focalLength(info.focalMM, equivalent: info.focal35MM)),
                ("Mode", info.program),
                ("Metering", info.metering),
                ("Flash", info.flash),
                ("White balance", info.whiteBalance),
                ("Focus", info.focusMode),
            ]),
            ("Camera", [("Camera", info.camera), ("Lens", info.lens)]),
            ("File", [
                ("Name", info.file),
                ("Format", info.format),
                ("Size", size(info.bytes)),
                ("Resolution", resolution(width: info.width, height: info.height, megapixels: info.megapixels)),
            ]),
            ("Taken", [("Date", taken(info.taken, offset: info.offset, locale: locale))]),
            ("Place", [("Place", info.place), ("Coordinates", coordinates(info.gps))]),
        ]
        return all.compactMap { title, rows in
            let present = rows.compactMap { label, value -> PhotoInfoRow? in
                guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { return nil }
                return PhotoInfoRow(label, text)
            }
            return present.isEmpty ? nil : PhotoInfoSection(title, present)
        }
    }

    // MARK: When the details cannot be had

    /// What the sheet says when the request failed. Nothing is said about the cause beyond what
    /// Danny can act on: the PC is out of reach, the photo is gone, or the file cannot be read.
    public static func failure(_ error: any Error) -> String {
        switch error as? CullingBayError {
        case .transport(ServerLink.forcedMessage):
            return "Camera details come from the PC. Turn off Work offline to see them."
        case .transport, .unavailable:
            return "Camera details come from the PC, and it can’t be reached right now. Try again when it’s back."
        case .http(404, _):
            return "This photo isn’t in the library index any more."
        case .http(415, _):
            return "This file’s details can’t be read."
        case .http(let status, let message):
            return "Couldn’t load the camera details: \(message ?? "HTTP \(status)")"
        case .conflict(let message, _):
            return "Couldn’t load the camera details: \(message ?? "the server refused")"
        case .decoding(let message):
            return "Couldn’t load the camera details: \(message)"
        case nil:
            return "Couldn’t load the camera details: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    /// One decimal, without a trailing `.0`: `4`, `2.8`, `1.8`.
    private static func oneDecimal(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// `99.16605` with its sign: a real minus, and none for a position that rounds to zero.
    private static func degrees(_ value: Double) -> String {
        let text = String(format: "%.5f", abs(value))
        let isZero = text.allSatisfy { $0 == "0" || $0 == "." }
        return (value < 0 && !isZero ? minus : "") + text
    }

    /// The date (`2026-09-29`) and the seconds into that day of a `YYYY:MM:DD HH:MM:SS[.fraction]`
    /// time; nil if it is not one, or not a real date and time.
    private static func parseTaken(_ text: String) -> (date: String, seconds: Int)? {
        let halves = text.split(separator: " ", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let day = halves[0].split(separator: ":", omittingEmptySubsequences: false)
        let whole = halves[1].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let hms = whole[0].split(separator: ":", omittingEmptySubsequences: false)
        guard day.count == 3, hms.count == 3 else { return nil }
        if whole.count == 2, whole[1].isEmpty || !whole[1].allSatisfy({ ("0"..."9").contains($0) }) { return nil }
        let date = day.joined(separator: "-")
        guard parseISODate(date) != nil,
              hms.allSatisfy({ $0.count == 2 && $0.allSatisfy { ("0"..."9").contains($0) } }),
              let hour = Int(hms[0]), let minute = Int(hms[1]), let second = Int(hms[2]),
              hour < 24, minute < 60, second < 60
        else { return nil }
        return (date, hour * 3600 + minute * 60 + second)
    }

    /// `3:35:35 PM` (or `15:35:35`, as the phone's locale writes it) for a time of day. The time
    /// has no zone of its own, so it is built in UTC and read back in UTC.
    private static func clock(_ seconds: Int, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// `UTC−7`, `UTC+5:30`, `UTC` for `-07:00`, `+05:30`, `+00:00` or `Z`; nil for anything else.
    private static func zoneName(_ offset: String) -> String? {
        let text = offset.trimmingCharacters(in: .whitespaces)
        if text == "Z" { return "UTC" }
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let parts = text.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { ("0"..."9").contains($0) } }),
              let hours = Int(parts[0]), let minutes = Int(parts[1]), hours <= 23, minutes < 60
        else { return nil }
        if hours == 0 && minutes == 0 { return "UTC" }
        return "UTC\(sign == "-" ? minus : "+")\(hours)" + (minutes == 0 ? "" : ":" + String(format: "%02d", minutes))
    }
}
