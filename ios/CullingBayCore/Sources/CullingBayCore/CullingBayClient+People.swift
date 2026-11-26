import Foundation

/// A People write was refused with 409 because the name is already someone's. `existing` is that
/// person, so the screen can offer "Add to Alex?" or "Merge with Alex?" instead of an error.
public struct PersonNameTaken: Error, Equatable, Sendable {
    public let existing: Person
    /// The server's `error` text.
    public let message: String?

    public init(existing: Person, message: String? = nil) {
        self.existing = existing
        self.message = message
    }
}

/// The size of a face's picture: 160 px or 480 px square.
public enum FaceSize: String, Sendable, Hashable, CaseIterable {
    case small
    case large
}

/// The People routes. Reads go through the same ETag cache as the Gallery's. Writes never do:
/// what they change is read again, and the server's ETag moves with it.
extension CullingBayClient {
    // MARK: Reads

    /// The named people, the unnamed groups worth naming, and how many photos have been checked
    /// for faces.
    public func people() async throws -> PeopleList {
        let fetched: Fetched<PeopleList> = try await fetch(path: "/m/api/people")
        return fetched.value
    }

    /// One person's photos, newest first, with the Gallery's filters.
    public func personPhotos(_ id: Int, best: Bool = false, bursts: Bool = true) async throws -> PersonPhotos {
        let fetched: Fetched<PersonPhotos> = try await fetch(
            path: "/m/api/people/\(id)",
            query: [("best", URLBuilding.flag(best)), ("bursts", URLBuilding.flag(bursts))])
        return fetched.value
    }

    /// The photos of an unnamed group's unclaimed faces, newest first, with the Gallery's filters.
    public func groupPhotos(_ key: Int, best: Bool = false, bursts: Bool = true) async throws -> GroupPhotos {
        let fetched: Fetched<GroupPhotos> = try await fetch(
            path: "/m/api/people/group/\(key)",
            query: [("best", URLBuilding.flag(best)), ("bursts", URLBuilding.flag(bursts))])
        return fetched.value
    }

    /// One page of a person's faces for the fix screen. `limit` is 1 to 500; the server answers 400
    /// for anything else.
    public func personFaces(_ id: Int, offset: Int = 0, limit: Int = 100) async throws -> PersonFaces {
        let fetched: Fetched<PersonFaces> = try await fetch(
            path: "/m/api/people/\(id)/faces",
            query: [("offset", String(offset)), ("limit", String(limit))])
        return fetched.value
    }

    /// Up to 60 faces that may be this person, and the unnamed groups that may be them.
    public func suggestions(for id: Int) async throws -> PersonSuggestions {
        let fetched: Fetched<PersonSuggestions> = try await fetch(path: "/m/api/people/\(id)/suggestions")
        return fetched.value
    }

    /// The faces in one photo, left to right. A 404 (unknown photo) throws `.http`.
    public func photoFaces(_ photo: Int) async throws -> [PhotoFace] {
        let fetched: Fetched<PhotoFaces> = try await fetch(path: "/m/api/photo/\(photo)/faces")
        return fetched.value.faces
    }

    // MARK: Writes

    /// Names a group and/or some faces as a new person, each face a confirmed one. Throws
    /// `PersonNameTaken` when someone has the name already.
    public func createPerson(name: String, group: Int? = nil, faces: [Int]? = nil) async throws -> Person {
        try await writeJSON(
            method: "POST", path: "/m/api/people",
            body: CreatePersonBody(name: name, group: group, faces: faces), staling: .nothing)
    }

    /// Renames a person. Throws `PersonNameTaken` when someone else has the name.
    public func renamePerson(_ id: Int, to name: String) async throws -> Person {
        try await writeJSON(
            method: "POST", path: "/m/api/people/\(id)",
            body: UpdatePersonBody(name: name, cover: .unchanged), staling: .nothing)
    }

    /// Chooses the face for their picture; nil goes back to the best confirmed face. A face that
    /// is not theirs is a 400.
    public func setCover(_ id: Int, face: Int?) async throws -> Person {
        try await writeJSON(
            method: "POST", path: "/m/api/people/\(id)",
            body: UpdatePersonBody(name: nil, cover: face.map(UpdatePersonBody.Cover.face) ?? .best),
            staling: .nothing)
    }

    /// These faces (and the unclaimed faces of this group) are this person. A face already
    /// someone else's becomes theirs, and a "not this person" on it is taken back.
    public func addFaces(to id: Int, group: Int? = nil, faces: [Int]? = nil) async throws -> Person {
        try await writeJSON(
            method: "POST", path: "/m/api/people/\(id)/add",
            body: AddFacesBody(group: group, faces: faces), staling: .nothing)
    }

    /// Everything said about this person becomes `into`'s and this person is deleted. Answers with
    /// `into`'s person.
    public func mergePerson(_ id: Int, into: Int) async throws -> Person {
        try await writeJSON(
            method: "POST", path: "/m/api/people/\(id)/merge", body: MergeBody(into: into), staling: .nothing)
    }

    /// The answers to "Is this ...?": a yes is a confirmed face, a no is never suggested for them
    /// again. A face in both lists is a 400.
    public func reviewSuggestions(_ id: Int, yes: [Int], no: [Int]) async throws -> Person {
        try await writeJSON(
            method: "POST", path: "/m/api/people/\(id)/review",
            body: ReviewBody(yes: yes, no: no), staling: .nothing)
    }

    /// Deletes the person with what Danny said about them; their faces go back to their groups.
    public func deletePerson(_ id: Int) async throws {
        let _: PeopleAck = try await writeJSON(
            method: "POST", path: "/m/api/people/\(id)/delete", body: EmptyBody(), staling: .nothing)
    }

    /// These faces are not `person`: no longer theirs, and never suggested for them again.
    public func removeFaces(_ faces: [Int], from person: Int) async throws -> Person {
        try await writeJSON(
            method: "POST", path: "/m/api/faces",
            body: FacesBody(faces: faces, group: nil, action: "not", person: person), staling: .nothing)
    }

    /// An unnamed group's unclaimed faces are not `person`: the "No" to "Is this Alex?" on a group. The
    /// server remembers it, so the group's `maybe` is gone from the next read.
    public func removeGroup(_ key: Int, from person: Int) async throws -> Person {
        try await writeJSON(
            method: "POST", path: "/m/api/faces",
            body: FacesBody(faces: nil, group: key, action: "not", person: person), staling: .nothing)
    }

    /// These faces are `person`'s, whoever's they were.
    public func moveFaces(_ faces: [Int], to person: Int) async throws -> Person {
        try await writeJSON(
            method: "POST", path: "/m/api/faces",
            body: FacesBody(faces: faces, group: nil, action: "move", person: person), staling: .nothing)
    }

    /// Not a face, or a stranger: hidden everywhere.
    public func ignoreFaces(_ faces: [Int]) async throws {
        let _: PeopleAck = try await writeJSON(
            method: "POST", path: "/m/api/faces",
            body: FacesBody(faces: faces, group: nil, action: "ignore", person: nil), staling: .nothing)
    }

    /// Hides the group's unclaimed faces, like `ignoreFaces`.
    public func hideGroup(_ key: Int) async throws {
        let _: PeopleAck = try await writeJSON(
            method: "POST", path: "/m/api/people/group/\(key)/hide", body: EmptyBody(), staling: .nothing)
    }

    // MARK: URL builder

    /// A face's square picture, cut from the photo's 1616 px picture with the box enlarged by 30%.
    /// It is cacheable for a day like `imageURL`.
    public nonisolated func faceURL(id: Int, size: FaceSize = .small) -> URL {
        URLBuilding.url(base: baseURL, path: "/m/api/face/\(id)", query: [("s", size.rawValue)])
    }
}

// MARK: Bodies

/// The answer of a write that has nothing to give back: `{"ok": true}`.
private struct PeopleAck: Decodable, Sendable {
    let ok: Bool
}

private struct CreatePersonBody: Encodable, Sendable {
    let name: String
    let group: Int?
    let faces: [Int]?
}

private struct UpdatePersonBody: Encodable, Sendable {
    /// What to do with the cover. `best` sends `null`, which is not the same as leaving it out.
    enum Cover: Sendable {
        case unchanged
        case face(Int)
        case best
    }

    let name: String?
    let cover: Cover

    enum CodingKeys: String, CodingKey {
        case name, cover
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        switch cover {
        case .unchanged: break
        case .face(let id): try container.encode(id, forKey: .cover)
        case .best: try container.encodeNil(forKey: .cover)
        }
    }
}

private struct AddFacesBody: Encodable, Sendable {
    let group: Int?
    let faces: [Int]?
}

private struct MergeBody: Encodable, Sendable {
    let into: Int
}

private struct ReviewBody: Encodable, Sendable {
    let yes: [Int]
    let no: [Int]
}

private struct FacesBody: Encodable, Sendable {
    /// Either, or both: the faces named, and an unnamed group's unclaimed faces.
    let faces: [Int]?
    let group: Int?
    let action: String
    let person: Int?
}
