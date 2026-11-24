import Foundation

/// What Danny says about one day: leave it to the app, always keep it, or never.
public enum OfflinePin: String, Codable, Sendable, Hashable, CaseIterable {
    case auto
    case always
    case never
}

/// The days to keep on the phone, in the order they were chosen.
public struct OfflinePlan: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        /// Pinned `always`.
        case always
        /// Started but not finished.
        case inProgress
        /// Not touched yet, and among the newest.
        case newest
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public let day: Day
        public let reason: Reason
        /// What the day takes: its saved size if it is saved, else the estimate.
        public let estimatedBytes: Int
        /// The day is within the limit. A day that is not stays out of the plan's total, and a
        /// smaller one after it may still fit.
        public let fits: Bool

        public var id: String { day.day }
    }

    /// Every candidate in the order it was considered: pinned, then in progress, then newest.
    public let entries: [Entry]
    /// The limit the plan was made for, in bytes.
    public let limitBytes: Int

    public static let empty = OfflinePlan(entries: [], limitBytes: 0)

    /// The days to keep: the entries that fit.
    public var kept: [Entry] { entries.filter(\.fits) }
    /// What the days to keep add up to.
    public var plannedBytes: Int { kept.reduce(0) { $0 + $1.estimatedBytes } }

    public func entry(for day: String) -> Entry? { entries.first { $0.day.day == day } }
}

/// Chooses which days to keep on the phone: pure, so it is tested on its own.
public enum OfflinePlanner {
    /// What a frame is expected to take, in bytes: its thumbnail, its 1616 px picture, and its
    /// 1:1 crop when crops are kept.
    public static let thumbBytes = 20_000
    public static let viewBytes = 330_000
    public static let cropBytes = 220_000

    public static func bytesPerFrame(includeCrops: Bool) -> Int {
        thumbBytes + viewBytes + (includeCrops ? cropBytes : 0)
    }

    /// Bytes in a limit given in gigabytes (decimal, as the phone's storage screen counts).
    public static func bytes(gigabytes: Double) -> Int {
        Int((gigabytes * 1_000_000_000).rounded())
    }

    /// `days` is newest first, as the server sends it. `pins` is by day id (a day without one is
    /// `auto`); `savedBytes` is what each saved day takes, by day id (a day without an entry is
    /// not saved).
    ///
    /// Days are considered in this order, each group newest first:
    /// 1. pinned `always`, even if finished;
    /// 2. partly culled (`decided > 0 && !finished`);
    /// 3. not culled at all (`decided == 0` and Lightroom has not done every stack).
    ///
    /// `never` days are left out, and so is a finished day with nothing unsent, unless pinned
    /// `always`. A day goes in if the running total stays within the limit.
    public static func plan(
        days: [Day], pins: [String: OfflinePin] = [:], savedBytes: [String: Int] = [:],
        limitBytes: Int, includeCrops: Bool
    ) -> OfflinePlan {
        func pin(_ day: Day) -> OfflinePin { pins[day.day] ?? .auto }
        func isPicked(_ day: Day) -> Bool { !(day.finished && CullSendAllModel.unsent(day) == 0) }

        var candidates: [(day: Day, reason: OfflinePlan.Reason)] = []
        candidates += days.filter { pin($0) == .always }.map { ($0, .always) }
        candidates += days.filter {
            pin($0) == .auto && isPicked($0) && $0.decided > 0 && !$0.finished
        }.map { ($0, .inProgress) }
        candidates += days.filter {
            pin($0) == .auto && isPicked($0) && $0.decided == 0 && $0.lrDone < $0.stacks
        }.map { ($0, .newest) }

        let perFrame = bytesPerFrame(includeCrops: includeCrops)
        var total = 0
        var entries: [OfflinePlan.Entry] = []
        for (day, reason) in candidates {
            let size = savedBytes[day.day] ?? day.frames * perFrame
            let fits = total + size <= limitBytes
            if fits { total += size }
            entries.append(OfflinePlan.Entry(day: day, reason: reason, estimatedBytes: size, fits: fits))
        }
        return OfflinePlan(entries: entries, limitBytes: limitBytes)
    }
}

/// The words the Offline settings show. Deterministic and English, like `CullFormat`.
public enum OfflineFormat {
    /// `320 MB`, `1.4 GB`: decimal units, a decimal only for gigabytes.
    public static func size(_ bytes: Int) -> String {
        if bytes >= 1_000_000_000 {
            let tenths = (Double(bytes) / 100_000_000).rounded() / 10
            return CullFormat.number(tenths) + " GB"
        }
        if bytes >= 1_000_000 { return "\(Int((Double(bytes) / 1_000_000).rounded())) MB" }
        if bytes > 0 { return "\(max(1, Int((Double(bytes) / 1_000).rounded()))) KB" }
        return "0 MB"
    }

    /// `2 GB`, `2.5 GB`: the limit as the slider says it.
    public static func limit(gigabytes: Double) -> String {
        CullFormat.number(gigabytes) + " GB"
    }

    /// `6 days · 1.4 GB saved`, or `No days saved yet`.
    public static func saved(days: Int, bytes: Int) -> String {
        guard days > 0 else { return "No days saved yet" }
        return "\(days) day" + (days == 1 ? "" : "s") + " · \(size(bytes)) saved"
    }

    /// `Saving Tue, 29 Sep 2026 · 120 of 480`; `Saving Tue, 29 Sep 2026…` before the day's files
    /// are counted.
    public static func saving(title: String, done: Int, total: Int) -> String {
        total > 0 ? "Saving \(title) · \(done) of \(total)" : "Saving \(title)…"
    }
}
