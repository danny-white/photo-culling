import Foundation
import Observation

/// The faces in one photo, for the People section of the (i) sheet, and what Danny can do about each:
/// "Not Alex" on a named face, "This is…" on any, "Yes, it's Alex" on one the server only suspects,
/// and "Not a face". The list is read again after every change, so the sheet shows what the server
/// now says.
@MainActor
@Observable
public final class PhotoFacesModel {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public let photoID: Int
    public private(set) var phase: Phase = .idle
    /// Left to right.
    public private(set) var faces: [PhotoFace] = []
    /// Why the last write failed; empty when it didn't.
    public private(set) var message = ""
    /// A write is in flight, so the menus should wait.
    public private(set) var isWorking = false

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private var generation = 0

    public init(photoID: Int, client: CullingBayClient) {
        self.photoID = photoID
        self.client = client
    }

    // MARK: Reading

    /// What the sheet calls a face: its person's name, `Alex?` for a face that may be them, or `Unnamed`.
    public static func label(for face: PhotoFace) -> String {
        if let person = face.person { return person.name }
        if let suggestion = face.suggestion { return "\(suggestion.name)?" }
        return "Unnamed"
    }

    // MARK: Loading

    /// Reads the photo's faces. A failure with faces on screen keeps them and says why in `message`.
    public func load() async {
        generation += 1
        let mine = generation
        if faces.isEmpty { phase = .loading }
        do {
            let found = try await client.photoFaces(photoID)
            guard mine == generation else { return }
            faces = found
            phase = .loaded
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled {
                if faces.isEmpty { phase = .idle }
                return
            }
            let text = GalleryMessages.failure(error, loading: "the faces")
            if faces.isEmpty { phase = .failed(text) } else { message = text }
        }
    }

    // MARK: Fixing a face

    /// "Not Alex": this face is not the person it is filed under. Does nothing for an unnamed face.
    @discardableResult
    public func notThem(_ face: PhotoFace) async -> Bool {
        guard let person = face.person else { return false }
        return await change { _ = try await self.client.removeFaces([face.id], from: person.id) }
    }

    /// "This is…": this face is someone's, whoever's it was.
    @discardableResult
    public func isThis(_ face: PhotoFace, person: Person) async -> Bool {
        await change { _ = try await self.client.moveFaces([face.id], to: person.id) }
    }

    /// "This is…" a new person. `.taken` carries the person who has the name, so the sheet can offer
    /// to use them.
    @discardableResult
    public func isThisNew(_ face: PhotoFace, named text: String) async -> PersonWrite {
        guard let name = PeopleFormat.cleanName(text) else {
            message = PeopleMessages.nameLength
            return .failed
        }
        var outcome = PersonWrite.failed
        await change {
            do {
                outcome = .saved(try await self.client.createPerson(name: name, faces: [face.id]))
            } catch let taken as PersonNameTaken {
                outcome = .taken(taken.existing)
                return false
            }
            return true
        }
        return outcome
    }

    /// "Yes, it's Alex", for a face the server only suspects.
    @discardableResult
    public func confirmSuggestion(_ face: PhotoFace) async -> Bool {
        guard let suggestion = face.suggestion else { return false }
        return await change {
            _ = try await self.client.reviewSuggestions(suggestion.id, yes: [face.id], no: [])
        }
    }

    /// Not a face, or a stranger: hidden everywhere.
    @discardableResult
    public func notAFace(_ face: PhotoFace) async -> Bool {
        await change { try await self.client.ignoreFaces([face.id]) }
    }

    /// Runs a write and, if it happened, reads the faces again.
    @discardableResult
    private func change(_ work: () async throws -> Void) async -> Bool {
        await change { try await work(); return true }
    }

    /// `work` answers whether it wrote anything; false changes nothing and says nothing.
    @discardableResult
    private func change(_ work: () async throws -> Bool) async -> Bool {
        guard !isWorking else { return false }
        message = ""
        isWorking = true
        do {
            guard try await work() else {
                isWorking = false
                return false
            }
        } catch {
            isWorking = false
            if !(error is CancellationError) { message = PeopleMessages.failure(error) }
            return false
        }
        isWorking = false
        await load()
        return true
    }
}
