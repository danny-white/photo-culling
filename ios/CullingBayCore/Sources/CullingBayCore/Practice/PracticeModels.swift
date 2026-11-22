import Foundation

/// Where a challenge stands. A string the app does not know decodes as `.todo`, so one new
/// status on the server cannot make the whole list fail to load.
public enum PracticeStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case todo
    case downloaded
    case done
    case skipped

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = PracticeStatus(rawValue: text) ?? .todo
    }
}

/// How hard a challenge is. A string the app does not know decodes as `.medium`.
public enum PracticeLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case easy
    case medium
    case hard

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = PracticeLevel(rawValue: text) ?? .medium
    }

    /// `Easy`, `Medium`, `Hard`.
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// One editing challenge (`GET /m/api/practice`): a photo of Danny's, a tool limit and an aim,
/// and where he has got with it.
public struct PracticeChallenge: Codable, Sendable, Hashable, Identifiable {
    /// Stable key; the write route takes it.
    public let id: String
    public let title: String
    /// `phone` or `mac`.
    public let mode: String
    public let level: PracticeLevel
    /// Approximate time budget.
    public let minutes: Int
    /// The Lightroom tools the edit may use.
    public let tools: [String]
    /// The result to aim for.
    public let aim: String
    /// Why this photo suits it.
    public let why: String
    /// Editing suggestions; empty when the challenge has none.
    public let hints: [String]
    public let pickedBy: String
    /// `YYYY-MM-DD`.
    public let added: String
    public let photo: Photo
    public internal(set) var status: PracticeStatus
    /// Danny's note, up to 2000 characters.
    public internal(set) var note: String
    public internal(set) var updatedAt: String?
    /// When the RAW was first fetched; nil until it was.
    public internal(set) var downloadedAt: String?
    /// When it was marked done; nil unless `status` is `.done`.
    public internal(set) var doneAt: String?
    /// The full challenge needs Lightroom Classic (Calibration, Enhance), so it is done on the Mac.
    /// False when the server does not send it.
    public let needsDesktop: Bool
    /// Which tool needs the desktop, in a line; nil when none is given.
    public let desktopReason: String?
    /// The id of the Needs Desktop challenge this is the on-the-go version of. nil for any other,
    /// and for a companion whose parent is not in the answer, which then stands alone.
    public let companionOf: String?
    /// The ids of the challenges that are this one's on-the-go versions, in the file's order.
    /// Empty when the server does not send it.
    public let companions: [String]

    /// The RAW has been fetched at some point.
    public var wasDownloaded: Bool { !(downloadedAt ?? "").isEmpty }

    public init(
        id: String, title: String, mode: String = "phone", level: PracticeLevel = .medium,
        minutes: Int = 10, tools: [String] = [], aim: String = "", why: String = "",
        hints: [String] = [], pickedBy: String = "Claude", added: String = "", photo: Photo,
        status: PracticeStatus = .todo, note: String = "", updatedAt: String? = nil,
        downloadedAt: String? = nil, doneAt: String? = nil, needsDesktop: Bool = false,
        desktopReason: String? = nil, companionOf: String? = nil, companions: [String] = []
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.level = level
        self.minutes = minutes
        self.tools = tools
        self.aim = aim
        self.why = why
        self.hints = hints
        self.pickedBy = pickedBy
        self.added = added
        self.photo = photo
        self.status = status
        self.note = note
        self.updatedAt = updatedAt
        self.downloadedAt = downloadedAt
        self.doneAt = doneAt
        self.needsDesktop = needsDesktop
        self.desktopReason = desktopReason
        self.companionOf = companionOf
        self.companions = companions
    }

    enum CodingKeys: String, CodingKey {
        case id, title, mode, level, minutes, tools, aim, why, hints
        case pickedBy = "picked_by"
        case added, photo, status, note
        case updatedAt = "updated_at"
        case downloadedAt = "downloaded_at"
        case doneAt = "done_at"
        case needsDesktop = "needs_desktop"
        case desktopReason = "desktop_reason"
        case companionOf = "companion_of"
        case companions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        mode = try values.decode(String.self, forKey: .mode)
        level = try values.decode(PracticeLevel.self, forKey: .level)
        minutes = try values.decode(Int.self, forKey: .minutes)
        tools = try values.decode([String].self, forKey: .tools)
        aim = try values.decode(String.self, forKey: .aim)
        why = try values.decode(String.self, forKey: .why)
        hints = try values.decodeIfPresent([String].self, forKey: .hints) ?? []
        pickedBy = try values.decode(String.self, forKey: .pickedBy)
        added = try values.decode(String.self, forKey: .added)
        photo = try values.decode(Photo.self, forKey: .photo)
        status = try values.decode(PracticeStatus.self, forKey: .status)
        note = try values.decode(String.self, forKey: .note)
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
        downloadedAt = try values.decodeIfPresent(String.self, forKey: .downloadedAt)
        doneAt = try values.decodeIfPresent(String.self, forKey: .doneAt)
        needsDesktop = try values.decodeIfPresent(Bool.self, forKey: .needsDesktop) ?? false
        desktopReason = try values.decodeIfPresent(String.self, forKey: .desktopReason)
        companionOf = try values.decodeIfPresent(String.self, forKey: .companionOf)
        companions = try values.decodeIfPresent([String].self, forKey: .companions) ?? []
    }

    /// Takes the server's answer to a write.
    mutating func apply(_ state: PracticeState) {
        status = state.status
        note = state.note
        updatedAt = state.updatedAt
        downloadedAt = state.downloadedAt
        doneAt = state.doneAt
    }
}

/// Which section of the tab a group is listed in.
public enum PracticeSection: String, Sendable, Hashable, CaseIterable {
    case waiting, done, skipped
}

/// A challenge without `companion_of` and its on-the-go versions, in the file's order. They are the
/// same photo, so the tab lists them together; a challenge with no companion is a group of one.
public struct PracticeGroup: Sendable, Hashable, Identifiable {
    public let parent: PracticeChallenge
    public let companions: [PracticeChallenge]

    public var id: String { parent.id }

    /// The parent, then its companions.
    public var members: [PracticeChallenge] { [parent] + companions }

    /// How many challenges (rows) it shows.
    public var count: Int { 1 + companions.count }

    /// Waiting if any member is todo or downloaded, else Done if any is done, else Skipped. A pair
    /// stays together while one of them is still waiting.
    public var section: PracticeSection {
        let all = members
        if all.contains(where: { $0.status == .todo || $0.status == .downloaded }) { return .waiting }
        if all.contains(where: { $0.status == .done }) { return .done }
        return .skipped
    }

    public init(parent: PracticeChallenge, companions: [PracticeChallenge] = []) {
        self.parent = parent
        self.companions = companions
    }

    /// The groups of a list, in the order of their parents. A challenge is a companion when its
    /// `companionOf` names another challenge in the list that is not itself a companion; any other
    /// challenge, a companion whose parent is missing included, is a parent.
    public static func groups(of challenges: [PracticeChallenge]) -> [PracticeGroup] {
        let parents = Set(challenges.filter { $0.companionOf == nil }.map(\.id))
        func parentID(of challenge: PracticeChallenge) -> String? {
            challenge.companionOf.flatMap { parents.contains($0) ? $0 : nil }
        }
        var byParent: [String: [PracticeChallenge]] = [:]
        for challenge in challenges {
            if let parent = parentID(of: challenge) { byParent[parent, default: []].append(challenge) }
        }
        return challenges.compactMap { challenge in
            parentID(of: challenge) == nil
                ? PracticeGroup(parent: challenge, companions: byParent[challenge.id] ?? []) : nil
        }
    }
}

/// `GET /m/api/practice`. A file the server cannot read comes back as an empty list with
/// `error` and no `missing`.
public struct PracticeList: Codable, Sendable, Hashable {
    public let challenges: [PracticeChallenge]
    /// Challenges left out because their photo is no longer in the library.
    public let missing: Int?
    public let error: String?

    public init(challenges: [PracticeChallenge], missing: Int? = nil, error: String? = nil) {
        self.challenges = challenges
        self.missing = missing
        self.error = error
    }
}

/// The server's answer to `POST /m/api/practice/<id>`: the challenge's state after the write.
public struct PracticeState: Codable, Sendable, Hashable {
    public let ok: Bool
    public let id: String
    public let status: PracticeStatus
    public let note: String
    public let updatedAt: String?
    public let downloadedAt: String?
    public let doneAt: String?

    public init(
        ok: Bool = true, id: String, status: PracticeStatus, note: String = "",
        updatedAt: String? = nil, downloadedAt: String? = nil, doneAt: String? = nil
    ) {
        self.ok = ok
        self.id = id
        self.status = status
        self.note = note
        self.updatedAt = updatedAt
        self.downloadedAt = downloadedAt
        self.doneAt = doneAt
    }

    enum CodingKeys: String, CodingKey {
        case ok, id, status, note
        case updatedAt = "updated_at"
        case downloadedAt = "downloaded_at"
        case doneAt = "done_at"
    }
}
