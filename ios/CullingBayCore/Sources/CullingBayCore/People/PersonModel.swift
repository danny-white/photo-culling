import Foundation
import Observation

/// State of one person's screen: the header (name, photo count, picture, how many faces to
/// review) and what Danny does to the person: rename, merge into someone else, remove the name,
/// choose the cover. The person's photos are a `FeedModel` over `.person`; this is the rest.
///
/// `GET /m/api/people/<id>` carries only the name and the photos, so the header is read from the
/// `people` list, and each write's answer (the changed Person) replaces it.
@MainActor
@Observable
public final class PersonModel {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        /// There is no person to show: the load failed, or they are gone.
        case failed(String)
    }

    /// How the screen came to an end: the person is someone else's now, or deleted. The view closes.
    public enum Ending: Sendable, Hashable {
        case merged(into: Person)
        case deleted
    }

    public let id: Int
    public private(set) var phase: Phase
    public private(set) var person: Person?
    /// Why the last write (or a reload with someone on screen) failed; empty when it didn't.
    public private(set) var message = ""
    public private(set) var ending: Ending?
    /// A write is in flight, so the menu should wait.
    public private(set) var isWorking = false

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private var generation = 0

    /// `person` is what the list already knows, so the header shows at once.
    public init(id: Int, person: Person? = nil, client: CullingBayClient) {
        self.id = id
        self.person = person
        self.phase = person == nil ? .idle : .loaded
        self.client = client
    }

    // MARK: Reading

    public var name: String { person?.name ?? "" }
    public var photoCaption: String { person.map { PeopleFormat.personCaption($0) } ?? "" }
    /// A face id for the big circle; nil when they have no faces left.
    public var cover: Int? { person?.cover }

    /// `"Review 12 suggestions"`, nil when there are none.
    public var reviewBanner: String? {
        guard let person, person.suggestions > 0 else { return nil }
        return PeopleFormat.reviewTitle(person.suggestions)
    }

    // MARK: Loading

    /// Reads the person again from the `people` list (a 304 makes it cheap). If someone is already
    /// on screen a failure keeps them and says why in `message`.
    public func load() async {
        generation += 1
        let mine = generation
        if person == nil { phase = .loading }
        do {
            let list = try await client.people()
            guard mine == generation else { return }
            if let found = list.people.first(where: { $0.id == id }) {
                person = found
                message = ""
                phase = .loaded
            } else {
                person = nil
                phase = .failed("That person isn’t in the library any more.")
            }
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled {
                if person == nil { phase = .idle }
                return
            }
            let text = GalleryMessages.failure(error, loading: "the person")
            if person == nil {
                phase = .failed(text)
            } else {
                message = text
            }
        }
    }

    /// A screen that changed this person (the review, the fix screen) hands back their new state.
    public func update(_ changed: Person) {
        guard changed.id == id else { return }
        person = changed
        phase = .loaded
    }

    // MARK: Writing

    /// Renames them. `.taken` carries the person who has that name, so the screen can offer to merge
    /// with them. A name that is not 1 to 80 characters is `.failed` without asking the server.
    @discardableResult
    public func rename(to text: String) async -> PersonWrite {
        guard let name = PeopleFormat.cleanName(text) else {
            message = PeopleMessages.nameLength
            return .failed
        }
        if let person, person.name == name { return .saved(person) }
        let result: PersonWrite? = await write {
            do {
                let changed = try await self.client.renamePerson(self.id, to: name)
                self.update(changed)
                return .saved(changed)
            } catch let taken as PersonNameTaken {
                return .taken(taken.existing)
            }
        }
        return result ?? .failed
    }

    /// Everything said about this person becomes `other`'s, and this person goes. On success
    /// `ending` is `.merged`.
    @discardableResult
    public func merge(into other: Person) async -> Bool {
        guard let into = await write({ try await self.client.mergePerson(self.id, into: other.id) })
        else { return false }
        ending = .merged(into: into)
        return true
    }

    /// Takes the name off: their faces go back to their groups. On success `ending` is `.deleted`.
    @discardableResult
    public func delete() async -> Bool {
        guard await write({ try await self.client.deletePerson(self.id) }) != nil else { return false }
        ending = .deleted
        return true
    }

    /// Chooses the face for their picture; nil goes back to the best confirmed face.
    @discardableResult
    public func setCover(face: Int?) async -> Bool {
        guard let changed = await write({ try await self.client.setCover(self.id, face: face) })
        else { return false }
        update(changed)
        return true
    }

    /// Runs one write: clears the old message, holds the menu, and turns a failure into `message`
    /// and a nil.
    private func write<T: Sendable>(_ work: () async throws -> T) async -> T? {
        message = ""
        isWorking = true
        defer { isWorking = false }
        do {
            return try await work()
        } catch {
            if !(error is CancellationError) { message = PeopleMessages.failure(error) }
            return nil
        }
    }
}
