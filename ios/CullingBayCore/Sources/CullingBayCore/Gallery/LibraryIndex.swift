import Foundation

/// The home page's view of `GET /m/api/days`: days grouped into years and months, newest first
/// in the order the list comes, as `groupDays` does in `gallery.js`. Undated days form the year
/// and the month `"Undated"` (shown as "Other folders").
public struct LibraryIndex: Sendable, Hashable {
    /// The year (and month key) of a day without a date.
    public static let undated = "Undated"

    public struct Year: Sendable, Hashable, Identifiable {
        /// `"2026"`, or `"Undated"`.
        public let year: String
        public let days: [Day]
        public let months: [Month]

        public var id: String { year }
        public var photoCount: Int { days.reduce(0) { $0 + $1.frames } }
        /// The town most of the year's photos were near.
        public var topTown: String? { LibraryIndex.topTown(of: days) }
        /// `"12 days · 3,400 photos · Seattle"`.
        public var subtitle: String { LibraryIndex.subtitle(days: days) }
    }

    public struct Month: Sendable, Hashable, Identifiable {
        /// `"2026-10"`, or `"Undated"`. Used as the id of the open state.
        public let key: String
        public let days: [Day]

        public var id: String { key }
        /// `"October"`, or `"Other folders"` for the undated group.
        public var name: String {
            guard key != LibraryIndex.undated, let month = Int(key.suffix(2)), (1...12).contains(month)
            else { return "Other folders" }
            return LibraryIndex.monthNames[month - 1]
        }
        public var photoCount: Int { days.reduce(0) { $0 + $1.frames } }
        public var topTown: String? { LibraryIndex.topTown(of: days) }
        public var subtitle: String { LibraryIndex.subtitle(days: days) }
        /// Thumbnail ids for the closed month's strip: the first of each day (all three of a
        /// one- or two-day month), at most six.
        public var strip: [Int] {
            Array(days.flatMap { $0.thumbs.prefix(days.count > 2 ? 1 : 3) }.prefix(6))
        }
    }

    /// A day in an earlier year near today's month and day.
    public struct OnThisDay: Sendable, Hashable, Identifiable {
        public let day: Day
        public let year: Int
        /// The photo for the tile.
        public let thumb: Int

        public var id: String { day.day }
        /// `"2025 · Seattle"`, or `"2025"` without a place.
        public var label: String {
            [String(year), town(day.place)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    public let years: [Year]
    public let dayCount: Int

    public init(days: [Day]) {
        var years: [Year] = []
        var current: (year: String, days: [Day], months: [Month])?
        var month: (key: String, days: [Day])?

        func closeMonth() {
            guard let finished = month else { return }
            current?.months.append(Month(key: finished.key, days: finished.days))
            month = nil
        }
        func closeYear() {
            closeMonth()
            if let finished = current {
                years.append(Year(year: finished.year, days: finished.days, months: finished.months))
            }
            current = nil
        }

        for day in days {
            let yearName = Self.year(of: day)
            if current?.year != yearName {
                closeYear()
                current = (yearName, [], [])
            }
            current?.days.append(day)
            let key = Self.monthKey(of: day)
            if month?.key != key {
                closeMonth()
                month = (key, [])
            }
            month?.days.append(day)
        }
        closeYear()
        self.years = years
        self.dayCount = days.count
    }

    public static let empty = LibraryIndex(days: [])

    /// Days in an earlier year within two days of `today`'s month and day, in list order. The
    /// distance wraps the new year, so on 1 January the 31st of December counts. `gallery.js`
    /// does not wrap; this deliberately does.
    public func onThisDay(today: Date, timeZone: TimeZone = .current) -> [OnThisDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        guard let thisYear = now.year, let month = now.month, let day = now.day else { return [] }
        let target = Self.ordinal(month: month, day: day)
        var found: [OnThisDay] = []
        for year in years {
            for entry in year.days {
                guard let thumb = entry.thumbs.first, let parts = entry.isoDate,
                      let y = parts.year, let m = parts.month, let d = parts.day, y < thisYear
                else { continue }
                let gap = abs(Self.ordinal(month: m, day: d) - target)
                if min(gap, 366 - gap) <= 2 {
                    found.append(OnThisDay(day: entry, year: y, thumb: thumb))
                }
            }
        }
        return found
    }

    // MARK: Helpers

    static let monthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September",
        "October", "November", "December",
    ]

    static func year(of day: Day) -> String {
        day.date.map { String($0.prefix(4)) } ?? undated
    }

    static func monthKey(of day: Day) -> String {
        day.date.map { String($0.prefix(7)) } ?? undated
    }

    /// The day's place in a leap year (1...366), so 29 February has a slot.
    private static func ordinal(month: Int, day: Int) -> Int {
        let lengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return lengths.prefix(month - 1).reduce(0, +) + day
    }

    /// The town most photos were near: places are counted by frames, and the first seen wins a tie.
    static func topTown(of days: [Day]) -> String? {
        var frames: [String: Int] = [:]
        var order: [String] = []
        for day in days {
            guard let place = day.place, !place.isEmpty else { continue }
            if frames[place] == nil { order.append(place) }
            frames[place, default: 0] += day.frames
        }
        var best: String?
        for place in order where best == nil || frames[place]! > frames[best!]! { best = place }
        return town(best)
    }

    static func subtitle(days: [Day]) -> String {
        [
            GalleryFormat.dayCount(days.count),
            GalleryFormat.photoCount(days.reduce(0) { $0 + $1.frames }),
            topTown(of: days),
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

extension Day {
    /// A day row's second line: `"Seattle · 120 photos · Dune walk"`.
    public var rowSubtitle: String {
        [town(place), GalleryFormat.photoCount(frames), summary]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
