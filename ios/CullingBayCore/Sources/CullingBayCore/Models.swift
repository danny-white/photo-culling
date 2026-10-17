import Foundation

/// One day folder in the library (`GET /m/api/days`).
public struct Day: Codable, Sendable, Hashable, Identifiable {
    /// Library-relative folder, e.g. `2026/2026-10-01`. The id used in other routes.
    public let day: String
    /// Last path part, e.g. `2026-10-01`.
    public let folder: String
    /// ISO date `YYYY-MM-DD`; nil for an undated folder.
    public let date: String?
    public let frames: Int
    public let stacks: Int
    /// Up to 3 photo ids for the day's row.
    public let thumbs: [Int]
    /// Latest capture time, epoch seconds (a float on the wire).
    public let lastTs: Double
    /// The town most photos were near, lower case, `town, region, country`.
    public let place: String?
    public let places: [String]
    public let gpsFrames: Int
    public let summary: String?
    public let decided: Int
    public let sent: Int
    public let landed: Int
    public let conflicts: Int
    public let lrDone: Int
    public let finished: Bool
    public let sentAt: String?

    public var id: String { day }

    /// `date` parsed into year, month and day; nil when absent or malformed.
    public var isoDate: DateComponents? { parseISODate(date) }

    public init(
        day: String, folder: String, date: String? = nil, frames: Int, stacks: Int,
        thumbs: [Int], lastTs: Double, place: String? = nil, places: [String],
        gpsFrames: Int, summary: String? = nil, decided: Int, sent: Int, landed: Int,
        conflicts: Int, lrDone: Int, finished: Bool, sentAt: String? = nil
    ) {
        self.day = day
        self.folder = folder
        self.date = date
        self.frames = frames
        self.stacks = stacks
        self.thumbs = thumbs
        self.lastTs = lastTs
        self.place = place
        self.places = places
        self.gpsFrames = gpsFrames
        self.summary = summary
        self.decided = decided
        self.sent = sent
        self.landed = landed
        self.conflicts = conflicts
        self.lrDone = lrDone
        self.finished = finished
        self.sentAt = sentAt
    }

    enum CodingKeys: String, CodingKey {
        case day, folder, date, frames, stacks, thumbs
        case lastTs = "last_ts"
        case place, places
        case gpsFrames = "gps_frames"
        case summary, decided, sent, landed, conflicts
        case lrDone = "lr_done"
        case finished
        case sentAt = "sent_at"
    }
}

/// One photo as the gallery routes return it.
public struct Photo: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// Its day id, e.g. `2026/2026-10-01`.
    public let day: String
    /// ISO date `YYYY-MM-DD`.
    public let date: String?
    /// Capture time in epoch seconds. The server read the camera's clock as local time on the PC
    /// (Pacific), so formatting `captureDate` in the phone's own time zone shows the time the
    /// camera displayed. Formatting it in UTC would be off by 7 or 8 hours.
    public let ts: Double?
    /// File name, e.g. `DSC05040.ARW`. Not unique: camera numbers wrap.
    public let file: String
    /// Size of the original file.
    public let bytes: Int?
    public let camera: String?
    public let lens: String?
    /// Machine caption; not always right.
    public let caption: String?
    /// Nearest town, as in `Day.place`.
    public let place: String?
    /// 0 to 5, the higher of Lightroom and phone.
    public let stars: Int
    public let picked: Bool
    public let rejected: Bool
    /// The original is a RAW (ARW, NEF, CR2, CR3, DNG, ...).
    public let raw: Bool

    /// `ts` as a `Date` (see `ts` for what the instant means).
    public var captureDate: Date? { ts.map { Date(timeIntervalSince1970: $0) } }

    /// `date` parsed into year, month and day; nil when absent or malformed.
    public var isoDate: DateComponents? { parseISODate(date) }

    public init(
        id: Int, day: String, date: String? = nil, ts: Double? = nil, file: String,
        bytes: Int? = nil, camera: String? = nil, lens: String? = nil, caption: String? = nil,
        place: String? = nil, stars: Int, picked: Bool, rejected: Bool, raw: Bool
    ) {
        self.id = id
        self.day = day
        self.date = date
        self.ts = ts
        self.file = file
        self.bytes = bytes
        self.camera = camera
        self.lens = lens
        self.caption = caption
        self.place = place
        self.stars = stars
        self.picked = picked
        self.rejected = rejected
        self.raw = raw
    }
}

/// Result of `gallery/search` and `gallery/like`. `query` is only present for a search.
public struct PhotoList: Codable, Sendable, Hashable {
    public let query: String?
    /// Matches before the Best and bursts filters.
    public let total: Int
    /// What matched: `words`, `captions`, `pictures`, `dates`.
    public let signals: [String]
    /// Sentences to show when part of search is unavailable.
    public let notes: [String]
    public let photos: [Photo]

    public init(query: String? = nil, total: Int, signals: [String], notes: [String], photos: [Photo]) {
        self.query = query
        self.total = total
        self.signals = signals
        self.notes = notes
        self.photos = photos
    }
}

/// Result of `gallery/day/<day>`.
public struct GalleryDay: Codable, Sendable, Hashable {
    public let day: String
    public let date: String?
    public let summary: String?
    public let photos: [Photo]

    public init(day: String, date: String? = nil, summary: String? = nil, photos: [Photo]) {
        self.day = day
        self.date = date
        self.summary = summary
        self.photos = photos
    }
}

/// Parses `YYYY-MM-DD` into date components, or nil if it is not a real calendar date.
func parseISODate(_ string: String?) -> DateComponents? {
    guard let string else { return nil }
    let parts = string.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
          (1...12).contains(month)
    else { return nil }
    let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    let daysInMonth = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    guard (1...daysInMonth).contains(day) else { return nil }
    return DateComponents(year: year, month: month, day: day)
}
