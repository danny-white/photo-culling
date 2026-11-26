import Foundation

// The People routes' shapes, as `review/API.md` lists them under People. The server rebuilds who
// is in which photo from Danny's answers, so none of this is saved on the phone.

/// Whose a face is (`PhotoFace.how`, `PersonFace.how`). `unnamed` is `"none"` on the wire: nobody's
/// yet, a member of an unnamed group or a suggestion. It is not named `.none` so it can't be
/// mistaken for an absent `FaceHow?`.
public enum FaceHow: OpenStringEnum {
    /// Danny said so: named it, added it, answered yes, or moved it there.
    case confirmed
    /// The server filed it under that person.
    case auto
    case unnamed
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "confirmed": self = .confirmed
        case "auto": self = .auto
        case "none": self = .unnamed
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .confirmed: "confirmed"
        case .auto: "auto"
        case .unnamed: "none"
        case .other(let value): value
        }
    }
}

/// A named person (`GET /m/api/people` and every People write that changes one).
public struct Person: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// As given, trimmed; 1 to 80 characters. No two people share a name, case aside.
    public let name: String
    /// Photos with at least one face of theirs (confirmed or filed by the server).
    public let photos: Int
    /// Their faces, confirmed and filed.
    public let faces: Int
    /// A face id for their picture: the one Danny chose, else the best confirmed face. Nil only
    /// when they have no faces left.
    public let cover: Int?
    /// Faces that may be them, for "Review N suggestions".
    public let suggestions: Int
    /// Faces the server filed as them on a weak match (under 0.55), for "Check N faces". A server
    /// that doesn't send it, which is an older one, counts as 0.
    public let doubts: Int

    public init(
        id: Int, name: String, photos: Int, faces: Int, cover: Int? = nil, suggestions: Int = 0, doubts: Int = 0
    ) {
        self.id = id
        self.name = name
        self.photos = photos
        self.faces = faces
        self.cover = cover
        self.suggestions = suggestions
        self.doubts = doubts
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, photos, faces, cover, suggestions, doubts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        photos = try container.decode(Int.self, forKey: .photos)
        faces = try container.decode(Int.self, forKey: .faces)
        cover = try container.decodeIfPresent(Int.self, forKey: .cover)
        suggestions = try container.decode(Int.self, forKey: .suggestions)
        doubts = try container.decodeIfPresent(Int.self, forKey: .doubts) ?? 0
    }
}

/// A person named in a face's answer: `GroupMaybe`, `PhotoFace.person` and `PhotoFace.suggestion`.
public struct PersonRef: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// Faces that look alike, which nobody has named. Its `key` is its smallest face id.
public struct FaceGroup: Codable, Sendable, Hashable, Identifiable {
    /// The group id, in the writes' `group` and in `people/group/<key>`.
    public let key: Int
    /// Faces in the group nobody has claimed, and the photos they are in.
    public let faces: Int
    public let photos: Int
    /// How many different shoot folders they are from.
    public let days: Int
    /// A face id for its picture: its best face.
    public let cover: Int
    /// Only when the group looks 0.40 or more like a named person, for "Is this Alex?".
    public let maybe: PersonRef?

    public var id: Int { key }

    public init(key: Int, faces: Int, photos: Int, days: Int, cover: Int, maybe: PersonRef? = nil) {
        self.key = key
        self.faces = faces
        self.photos = photos
        self.days = days
        self.cover = cover
        self.maybe = maybe
    }

    /// The same group with no "Is this ...?" question, for one Danny has answered no to.
    public func withoutMaybe() -> FaceGroup {
        FaceGroup(key: key, faces: faces, photos: photos, days: days, cover: cover)
    }
}

/// `GET /m/api/people`: the named people, the unnamed groups worth naming, and how far the face
/// search has got.
public struct PeopleList: Codable, Sendable, Hashable {
    /// Most photos first.
    public let people: [Person]
    public let groups: [FaceGroup]
    /// Photos checked for faces, and photos in the library, for "faces found in N of M photos".
    public let facesChecked: Int
    public let photosOK: Int

    public init(people: [Person], groups: [FaceGroup], facesChecked: Int, photosOK: Int) {
        self.people = people
        self.groups = groups
        self.facesChecked = facesChecked
        self.photosOK = photosOK
    }

    enum CodingKeys: String, CodingKey {
        case people, groups
        case facesChecked = "faces_checked"
        case photosOK = "photos_ok"
    }
}

/// `GET /m/api/people/<id>`: one person's photos, newest first.
public struct PersonPhotos: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
    /// Their photos before the Best and bursts filters.
    public let total: Int
    public let photos: [Photo]

    public init(id: Int, name: String, total: Int, photos: [Photo]) {
        self.id = id
        self.name = name
        self.total = total
        self.photos = photos
    }
}

/// `GET /m/api/people/group/<key>`: the photos of a group's unclaimed faces, newest first. `total`
/// is 0 for a group with nothing left.
public struct GroupPhotos: Codable, Sendable, Hashable {
    public let key: Int
    public let total: Int
    public let photos: [Photo]

    public init(key: Int, total: Int, photos: [Photo]) {
        self.key = key
        self.total = total
        self.photos = photos
    }
}

/// A face on a person's fix screen (`GET /m/api/people/<id>/faces`).
public struct PersonFace: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// The photo it is in.
    public let photo: Int
    /// `auto` (the server filed it) or `confirmed`.
    public let how: FaceHow

    public init(id: Int, photo: Int, how: FaceHow) {
        self.id = id
        self.photo = photo
        self.how = how
    }
}

/// `GET /m/api/people/<id>/faces`. The server's own filings come first, the least sure first,
/// then the confirmed ones, newest photo first.
public struct PersonFaces: Codable, Sendable, Hashable {
    /// Every face of theirs, not only this page.
    public let total: Int
    public let faces: [PersonFace]

    public init(total: Int, faces: [PersonFace]) {
        self.total = total
        self.faces = faces
    }
}

/// A face that may be a person: "Is this Alex?" (`GET /m/api/people/<id>/suggestions`).
public struct FaceSuggestion: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let photo: Int
    /// How alike, 0.40 to 0.55.
    public let sim: Double

    public init(id: Int, photo: Int, sim: Double) {
        self.id = id
        self.photo = photo
        self.sim = sim
    }
}

/// Up to 60 faces that may be this person, most alike first, and the unnamed groups whose
/// `maybe` is them. `GET /people/<id>/doubts` answers in the same shape: up to 60 faces filed as them
/// on a weak match, least sure first, and no groups.
public struct PersonSuggestions: Codable, Sendable, Hashable {
    public let faces: [FaceSuggestion]
    public let groups: [FaceGroup]

    public init(faces: [FaceSuggestion], groups: [FaceGroup]) {
        self.faces = faces
        self.groups = groups
    }
}

/// One face in one photo (`GET /m/api/photo/<id>/faces`).
public struct PhotoFace: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// `[x0, y0, x1, y1]` as fractions (0 to 1) of the upright photo.
    public let box: [Double]
    public let how: FaceHow
    /// Only when `how` is `confirmed` or `auto`.
    public let person: PersonRef?
    /// Only for an unnamed face that may be that person.
    public let suggestion: PersonRef?

    public init(id: Int, box: [Double], how: FaceHow, person: PersonRef? = nil, suggestion: PersonRef? = nil) {
        self.id = id
        self.box = box
        self.how = how
        self.person = person
        self.suggestion = suggestion
    }
}

/// `GET /m/api/photo/<id>/faces`, left to right.
struct PhotoFaces: Decodable, Sendable {
    let faces: [PhotoFace]
}
