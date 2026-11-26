import Foundation
import Observation

/// State of one unnamed group's screen: its header (picture, photo and day counts), the question
/// "Is this Alex?" when it looks like a named person, and what Danny does with it: give it a name
/// (new, or an existing person's), say yes or no to the question, or hide it. The group's photos
/// are a `FeedModel` over `.group`; this is the rest.
///
/// The header is read from the `people` list. A group that is not listed (one the server left out as
/// probably not a person) still opens, with the picture of its key face and no counts.
@MainActor
@Observable
public final class GroupModel {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// How the screen came to an end. The view closes (to the person, for `.named`).
    public enum Ending: Sendable, Hashable {
        case named(Person)
        case hidden
    }

    public let key: Int
    public private(set) var phase: Phase
    public private(set) var group: FaceGroup?
    /// Why the last write failed; empty when it didn't.
    public private(set) var message = ""
    public private(set) var ending: Ending?
    /// A write is in flight, so the buttons should wait.
    public private(set) var isWorking = false
    /// Danny said no to "Is this ...?" for this group.
    public private(set) var maybeDeclined: Bool

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let onDecline: (@MainActor (Int) -> Void)?
    @ObservationIgnored private var generation = 0

    /// `group` is what the list already knows, so the header shows at once. `maybeDeclined` is
    /// whether the question was answered no earlier in this run; `onDecline` tells whoever keeps
    /// that (the People tab's list) when it is answered now.
    public init(
        key: Int, group: FaceGroup? = nil, maybeDeclined: Bool = false, client: CullingBayClient,
        onDecline: (@MainActor (Int) -> Void)? = nil
    ) {
        self.key = key
        self.group = group
        self.phase = group == nil ? .idle : .loaded
        self.maybeDeclined = maybeDeclined
        self.client = client
        self.onDecline = onDecline
    }

    // MARK: Reading

    /// A face id for the big circle: the group's best face, else its key face.
    public var cover: Int { group?.cover ?? key }

    /// `"37 photos · 5 days"`; empty when the list does not have the group.
    public var caption: String { group.map { PeopleFormat.groupCaption($0) } ?? "" }

    /// The person the group looks like, until Danny says it isn't.
    public var maybe: PersonRef? { maybeDeclined ? nil : group?.maybe }

    /// `"Is this Alex?"`
    public var question: String? { maybe.map { "Is this \($0.name)?" } }

    // MARK: Loading

    /// Reads the group again from the `people` list (a 304 makes it cheap). A group the list does
    /// not have keeps what the screen had.
    public func load() async {
        generation += 1
        let mine = generation
        if group == nil { phase = .loading }
        do {
            let list = try await client.people()
            guard mine == generation else { return }
            if let found = list.groups.first(where: { $0.key == key }) { group = found }
            message = ""
            phase = .loaded
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled {
                if group == nil { phase = .idle }
                return
            }
            let text = GalleryMessages.failure(error, loading: "the group")
            if group == nil {
                phase = .failed(text)
            } else {
                message = text
            }
        }
    }

    // MARK: Writing

    /// Names the group's unclaimed faces as a new person. `.taken` carries the person who has that
    /// name, so the screen can offer "Add to Alex?". A name that is not 1 to 80 characters is
    /// `.failed` without asking the server. On success `ending` is `.named`.
    @discardableResult
    public func name(_ text: String) async -> PersonWrite {
        guard let name = PeopleFormat.cleanName(text) else {
            message = PeopleMessages.nameLength
            return .failed
        }
        let result: PersonWrite? = await write {
            do {
                let created = try await self.client.createPerson(name: name, group: self.key)
                self.ending = .named(created)
                return .saved(created)
            } catch let taken as PersonNameTaken {
                return .taken(taken.existing)
            }
        }
        return result ?? .failed
    }

    /// The group's unclaimed faces are this existing person's. On success `ending` is `.named`.
    @discardableResult
    public func add(to person: PersonRef) async -> Bool {
        guard let changed = await write({ try await self.client.addFaces(to: person.id, group: self.key) })
        else { return false }
        ending = .named(changed)
        return true
    }

    /// Yes to "Is this Alex?": the group is Alex's.
    @discardableResult
    public func confirmMaybe() async -> Bool {
        guard let maybe else { return false }
        return await add(to: maybe)
    }

    /// No to "Is this Alex?". The server can only be told about faces it names, and the app is
    /// told one of this group's (its cover), so that face is marked not Alex and the question goes
    /// from this run's screens (`maybeDeclined`, and `onDecline` for the list).
    public func declineMaybe() async {
        guard let maybe else { return }
        guard await write({ try await self.client.removeFaces([self.cover], from: maybe.id) }) != nil else { return }
        maybeDeclined = true
        onDecline?(key)
    }

    /// "Not someone I know": hides the group's unclaimed faces everywhere. On success `ending` is `.hidden`.
    @discardableResult
    public func hide() async -> Bool {
        guard await write({ try await self.client.hideGroup(self.key) }) != nil else { return false }
        ending = .hidden
        return true
    }

    /// Runs one write: clears the old message, holds the buttons, and turns a failure into `message`
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
