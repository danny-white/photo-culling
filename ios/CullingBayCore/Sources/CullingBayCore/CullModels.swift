import Foundation

/// A string-valued enum whose values are closed on today's server but may grow. Each has an
/// `.other(String)` case, so a value added later decodes (and encodes back unchanged) instead
/// of failing the whole day. Build one from a raw string with `init(rawValue:)`: a known string
/// always gives the named case, never `.other`.
public protocol OpenStringEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    init(rawValue: String)
}

extension OpenStringEnum {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How a stack was formed (`Stack.kind`).
public enum StackKind: OpenStringEnum {
    case single
    case burst
    /// An exposure bracket; suggests Keep all.
    case bracket
    /// A panorama sweep, confirmed from pixels; suggests Keep all.
    case pano
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "single": self = .single
        case "burst": self = .burst
        case "bracket": self = .bracket
        case "pano": self = .pano
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .single: "single"
        case .burst: "burst"
        case .bracket: "bracket"
        case .pano: "pano"
        case .other(let value): value
        }
    }
}

/// A decision's flag (`Decision.flag`, and `CullChange.flag` when deciding).
public enum CullFlag: OpenStringEnum {
    case pick
    case reject
    /// Takes a flag back off. On the wire it is `"none"`; it is not named `.none` so it can't be
    /// mistaken for an absent `CullFlag?`.
    case clear
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pick": self = .pick
        case "reject": self = .reject
        case "none": self = .clear
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pick: "pick"
        case .reject: "reject"
        case .clear: "none"
        case .other(let value): value
        }
    }
}

/// Where a decision was made (`CullChange.via`). The server accepts only these four.
public enum CullVia: OpenStringEnum {
    /// The web app no longer sends it.
    case sweep
    /// A decision on the card.
    case card
    /// From the burst picker.
    case burst
    /// A photo pulled back from the reject pile.
    case rescue
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "sweep": self = .sweep
        case "card": self = .card
        case "burst": self = .burst
        case "rescue": self = .rescue
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .sweep: "sweep"
        case .card: "card"
        case .burst: "burst"
        case .rescue: "rescue"
        case .other(let value): value
        }
    }
}

/// Where a decision has got to on its way to Lightroom (`Decision.state`).
public enum DecisionState: OpenStringEnum {
    /// Saved on the phone only. Every decide sets it back to this.
    case draft
    /// Sent: waiting for the Mac's next Lightroom sync.
    case queued
    /// The plug-in applied it.
    case landed
    /// Your own flag in Lightroom was kept instead.
    case conflict
    /// The photo was not in the Lightroom selection; the next send includes it again.
    case missing
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "draft": self = .draft
        case "queued": self = .queued
        case "landed": self = .landed
        case "conflict": self = .conflict
        case "missing": self = .missing
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .draft: "draft"
        case .queued: "queued"
        case .landed: "landed"
        case .conflict: "conflict"
        case .missing: "missing"
        case .other(let value): value
        }
    }
}

/// Who set a flag or a star rating in Lightroom (`LightroomState.by`, `.starsBy`).
public enum LightroomSource: OpenStringEnum {
    /// By hand in Lightroom. Only this counts as "already culled in Lightroom".
    case you
    /// The plug-in, applying a Send.
    case phone
    /// Nobody (`""` on the wire).
    case unset
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "you": self = .you
        case "phone": self = .phone
        case "": self = .unset
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .you: "you"
        case .phone: "phone"
        case .unset: ""
        case .other(let value): value
        }
    }
}

/// One day for culling (`GET /m/api/day/<day>`).
public struct CullDay: Codable, Sendable, Hashable, Identifiable {
    /// Library-relative folder, e.g. `2026/2026-10-01`.
    public let day: String
    public let folder: String
    /// ISO date `YYYY-MM-DD`; nil for an undated folder.
    public let date: String?
    public let summary: String?
    public let budget: Budget
    /// In shot order.
    public let stacks: [Stack]
    /// Where the last session stopped; nil until the first progress save.
    public let progress: Progress?

    public var id: String { day }

    /// `date` parsed into year, month and day; nil when absent or malformed.
    public var isoDate: DateComponents? { parseISODate(date) }

    public init(
        day: String, folder: String, date: String? = nil, summary: String? = nil,
        budget: Budget, stacks: [Stack], progress: Progress? = nil
    ) {
        self.day = day
        self.folder = folder
        self.date = date
        self.summary = summary
        self.budget = budget
        self.stacks = stacks
        self.progress = progress
    }
}

/// The soft limit of stacks to keep in a day.
public struct Budget: Codable, Sendable, Hashable {
    /// Stacks to keep: `perHour` per hour of shooting, at least 5.
    public let stacks: Int
    public let perHour: Int
    /// Shooting time in hours (pauses over 10 minutes count as 10), 2 decimals.
    public let hours: Double

    public init(stacks: Int, perHour: Int, hours: Double) {
        self.stacks = stacks
        self.perHour = perHour
        self.hours = hours
    }

    enum CodingKeys: String, CodingKey {
        case stacks
        case perHour = "per_hour"
        case hours
    }
}

/// Where the last culling session stopped. Both are nil after a Send that came before any
/// progress save.
public struct Progress: Codable, Sendable, Hashable {
    /// 1 or 2.
    public let pass: Int?
    /// A `Stack.id`.
    public let cursor: Int?

    public init(pass: Int? = nil, cursor: Int? = nil) {
        self.pass = pass
        self.cursor = cursor
    }
}

/// Frames taken together: one shutter press, or a single shot.
public struct Stack: Codable, Sendable, Hashable, Identifiable {
    /// Position in this response (0, 1, 2, ...). What `Progress.cursor` refers to. It isn't
    /// stable if photos are added to the day.
    public let id: Int
    public let kind: StackKind
    /// The `Frame.id` to show first: the sharpest frame, or a bracket's base exposure.
    public let lead: Int
    /// In shot order.
    public let frames: [Frame]

    public init(id: Int, kind: StackKind, lead: Int, frames: [Frame]) {
        self.id = id
        self.kind = kind
        self.lead = lead
        self.frames = frames
    }
}

/// One frame of a stack. A RAW with a same-name JPEG is one frame (the RAW).
public struct Frame: Codable, Sendable, Hashable, Identifiable {
    /// Photo id for every picture route and for deciding.
    public let id: Int
    /// File name, e.g. `DSC05040.ARW`.
    public let file: String
    /// File names that ride along (the JPEG of a RAW+JPEG pair).
    public let partners: [String]
    /// Their photo ids, same order.
    public let partnerIDs: [Int]
    /// Higher is sharper; only comparable inside one burst.
    public let sharpness: Double?
    /// `[u, v]`: the autofocus point as fractions of the upright frame; nil if not recorded.
    public let af: [Double]?
    /// Measured hints, at most one: `Blown`, `Dark` or `Softer`. Always empty inside a bracket.
    public let badges: [String]
    /// What Lightroom held at the last sync that covered the photo.
    public let lr: LightroomState?
    /// The phone's decision.
    public let decision: Decision?
    public let lens: String?
    /// Machine caption; not always right.
    public let caption: String?
    /// Share of pure-white pixels, 0 to 100.
    public let blownPct: Double?
    /// Mean brightness, 0 to 255.
    public let meanLum: Double?
    /// Nearest town, as in `Day.place`.
    public let place: String?

    public init(
        id: Int, file: String, partners: [String] = [], partnerIDs: [Int] = [],
        sharpness: Double? = nil, af: [Double]? = nil, badges: [String] = [],
        lr: LightroomState? = nil, decision: Decision? = nil, lens: String? = nil,
        caption: String? = nil, blownPct: Double? = nil, meanLum: Double? = nil,
        place: String? = nil
    ) {
        self.id = id
        self.file = file
        self.partners = partners
        self.partnerIDs = partnerIDs
        self.sharpness = sharpness
        self.af = af
        self.badges = badges
        self.lr = lr
        self.decision = decision
        self.lens = lens
        self.caption = caption
        self.blownPct = blownPct
        self.meanLum = meanLum
        self.place = place
    }

    enum CodingKeys: String, CodingKey {
        case id, file, partners
        case partnerIDs = "partner_ids"
        case sharpness, af, badges, lr, decision, lens, caption
        case blownPct = "blown_pct"
        case meanLum = "mean_lum"
        case place
    }
}

/// What Lightroom held for a photo at the last sync that covered it.
public struct LightroomState: Codable, Sendable, Hashable {
    /// 1 picked, 0 unflagged, -1 rejected.
    public let pick: Int
    /// 0 to 5.
    public let rating: Int
    /// Who set the flag.
    public let by: LightroomSource
    /// Who set the stars.
    public let starsBy: LightroomSource

    public var isPicked: Bool { pick == 1 }
    public var isRejected: Bool { pick == -1 }

    public init(pick: Int, rating: Int, by: LightroomSource, starsBy: LightroomSource) {
        self.pick = pick
        self.rating = rating
        self.by = by
        self.starsBy = starsBy
    }

    enum CodingKeys: String, CodingKey {
        case pick, rating, by
        case starsBy = "stars_by"
    }
}

/// The phone's decision about a frame.
public struct Decision: Codable, Sendable, Hashable {
    public let flag: CullFlag
    /// 1 to 5 or nil; only a pick has any.
    public let stars: Int?
    /// `""` when empty.
    public let note: String
    public let state: DecisionState
    /// What the Lightroom sync reported: for `.landed` nil or `your N kept`, for `.missing`
    /// `not in the Lightroom selection`, for `.conflict` the plug-in's text for what it kept.
    public let outcome: String?

    public init(flag: CullFlag, stars: Int? = nil, note: String = "", state: DecisionState, outcome: String? = nil) {
        self.flag = flag
        self.stars = stars
        self.note = note
        self.state = state
        self.outcome = outcome
    }
}

/// One day of a day search (`GET /m/api/search`, `GET /m/api/like/<id>`).
public struct DayMatch: Codable, Sendable, Hashable, Identifiable {
    /// Day id, e.g. `2026/2026-10-01`.
    public let day: String
    /// Matching photos in the day; 0 when it matched by its summary, a town or a date only.
    public let n: Int
    /// Up to 4 matching photo ids, best first, for thumbnails.
    public let ids: [Int]
    /// Up to 400 matching photo ids: the stacks that contain one come first when the day opens.
    public let matchIDs: [Int]
    /// One line to show, e.g. `3 photos · “a chick in a burrow”`; `""` for a date-only match.
    public let why: String

    public var id: String { day }

    public init(day: String, n: Int, ids: [Int], matchIDs: [Int], why: String) {
        self.day = day
        self.n = n
        self.ids = ids
        self.matchIDs = matchIDs
        self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case day, n, ids
        case matchIDs = "match_ids"
        case why
    }
}

/// Result of `GET /m/api/search` and `GET /m/api/like/<id>`: days to open, best first.
/// `query` is only present for a search.
public struct DaySearchResult: Codable, Sendable, Hashable {
    public let query: String?
    public let days: [DayMatch]
    /// Matching photos.
    public let photos: Int
    /// What matched: `words`, `captions`, `pictures`, `dates`.
    public let signals: [String]
    /// Sentences to show when part of search is unavailable.
    public let notes: [String]

    public init(query: String? = nil, days: [DayMatch], photos: Int, signals: [String], notes: [String]) {
        self.query = query
        self.days = days
        self.photos = photos
        self.signals = signals
        self.notes = notes
    }
}

/// One frame's new decision, as `decide` sends it.
public struct CullChange: Codable, Sendable, Hashable {
    /// A `Frame.id` (or a `partnerIDs` entry) of the day being decided.
    public let id: Int
    public let flag: CullFlag
    /// 1 to 5. The server keeps it only for a pick.
    public let stars: Int?
    public let note: String?
    public let via: CullVia

    public init(id: Int, flag: CullFlag, stars: Int? = nil, note: String? = nil, via: CullVia) {
        self.id = id
        self.flag = flag
        self.stars = stars
        self.note = note
        self.via = via
    }
}

/// The answer to `decide`, `undo` and `saveProgress`.
public struct CullAck: Codable, Sendable, Hashable {
    public let ok: Bool
    /// The server had already seen this action id and did nothing.
    public let replay: Bool

    public init(ok: Bool = true, replay: Bool = false) {
        self.ok = ok
        self.replay = replay
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        replay = try container.decodeIfPresent(Bool.self, forKey: .replay) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case ok, replay
    }
}

/// The answer to `send`.
public struct SendResult: Codable, Sendable, Hashable {
    public let ok: Bool
    /// Decisions queued for the next Lightroom sync; 0 when nothing was new.
    public let queued: Int
    /// Rows written to the inbox file, counting pair partners.
    public let fileRows: Int

    public init(ok: Bool = true, queued: Int, fileRows: Int) {
        self.ok = ok
        self.queued = queued
        self.fileRows = fileRows
    }

    enum CodingKeys: String, CodingKey {
        case ok, queued
        case fileRows = "file_rows"
    }
}

/// The answer to `reset`.
public struct ResetResult: Codable, Sendable, Hashable {
    public let ok: Bool
    /// Decisions removed.
    public let cleared: Int
    /// Rows taken back out of the inbox file.
    public let withdrawn: Int

    public init(ok: Bool = true, cleared: Int, withdrawn: Int) {
        self.ok = ok
        self.cleared = cleared
        self.withdrawn = withdrawn
    }
}
