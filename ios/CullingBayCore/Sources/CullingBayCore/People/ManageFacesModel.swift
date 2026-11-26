import Foundation
import Observation

/// The fix screen for one person: their faces, a page at a time (the server's own filings first,
/// the least sure first, then the ones Danny confirmed), with multi-select. What Danny can do to
/// the selected faces: "Not Alex", move them to someone else (or a new person), or say they are
/// not a face. One face can also be made the cover. A face disappears from the grid once it has
/// been dealt with.
@MainActor
@Observable
public final class ManageFacesModel {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The server's page size for this screen.
    public static let pageSize = 120

    /// The person, as the last answer left them; their name and counts change as faces go.
    public private(set) var person: Person
    public private(set) var phase: Phase = .idle
    public private(set) var faces: [PersonFace] = []
    /// Every face of theirs, loaded or not.
    public private(set) var total = 0
    public private(set) var isSelecting = false
    public private(set) var selected: Set<Int> = []
    public private(set) var isLoadingMore = false
    /// Why the last write or page failed; empty when it didn't.
    public private(set) var message = ""
    public private(set) var isWorking = false

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private var generation = 0

    public init(person: Person, client: CullingBayClient) {
        self.person = person
        self.client = client
    }

    // MARK: Reading

    /// More faces are on the server than are loaded.
    public var hasMore: Bool { faces.count < total }

    /// The selected faces in grid order.
    public var selectedFaces: [PersonFace] { faces.filter { selected.contains($0.id) } }

    /// Make cover is for one face at a time.
    public var canMakeCover: Bool { selected.count == 1 }

    /// `"Not Alex"`.
    public var notTitle: String { "Not \(person.name)" }

    // MARK: Loading

    /// Loads the first page again. The grid stays as it was while the page is on its way.
    public func load() async {
        generation += 1
        let mine = generation
        if faces.isEmpty { phase = .loading }
        do {
            let page = try await client.personFaces(person.id, offset: 0, limit: Self.pageSize)
            guard mine == generation else { return }
            faces = page.faces
            total = page.total
            selected.formIntersection(page.faces.map(\.id))
            message = ""
            phase = .loaded
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled {
                if faces.isEmpty { phase = .idle }
                return
            }
            let text = GalleryMessages.failure(error, loading: "their faces")
            if faces.isEmpty { phase = .failed(text) } else { message = text }
        }
    }

    /// Loads the next page, which starts after the faces the grid has. A face dealt with has left the
    /// server's list as well as the grid, so the two stay in step.
    public func loadMore() async {
        guard phase == .loaded, hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let mine = generation
        do {
            let page = try await client.personFaces(person.id, offset: faces.count, limit: Self.pageSize)
            guard mine == generation else { return }
            let known = Set(faces.map(\.id))
            faces += page.faces.filter { !known.contains($0.id) }
            total = page.total
        } catch {
            if !(error is CancellationError) { message = GalleryMessages.failure(error, loading: "more faces") }
        }
    }

    // MARK: Selecting

    public func beginSelection() { isSelecting = true }

    /// Selects or deselects a face. Does nothing unless the screen is selecting.
    public func toggleSelect(_ id: Int) {
        guard isSelecting else { return }
        if !selected.insert(id).inserted { selected.remove(id) }
    }

    /// Leaves selection mode and deselects everything.
    public func endSelection() {
        isSelecting = false
        selected = []
    }

    // MARK: Actions on the selected faces

    /// "Not Alex": these faces are not them, now and for any later suggestion.
    @discardableResult
    public func removeSelected() async -> Bool {
        let ids = selectedFaces.map(\.id)
        return await act(ids) { try await self.client.removeFaces(ids, from: self.person.id) }
    }

    /// Moves the selected faces to someone else.
    @discardableResult
    public func moveSelected(to other: Person) async -> Bool {
        let ids = selectedFaces.map(\.id)
        return await act(ids) {
            _ = try await self.client.moveFaces(ids, to: other.id)
            return await self.currentPerson()
        }
    }

    /// Moves the selected faces to a new person with this name. `.taken` carries the person who has
    /// the name, so the screen can offer to move them there instead.
    @discardableResult
    public func moveSelectedToNew(named text: String) async -> PersonWrite {
        guard let name = PeopleFormat.cleanName(text) else {
            message = PeopleMessages.nameLength
            return .failed
        }
        let ids = selectedFaces.map(\.id)
        var outcome = PersonWrite.failed
        await act(ids) {
            do {
                outcome = .saved(try await self.client.createPerson(name: name, faces: ids))
            } catch let taken as PersonNameTaken {
                outcome = .taken(taken.existing)
                return nil
            }
            return await self.currentPerson()
        }
        return outcome
    }

    /// Not a face, or a stranger: the selected faces are hidden everywhere.
    @discardableResult
    public func ignoreSelected() async -> Bool {
        let ids = selectedFaces.map(\.id)
        return await act(ids) {
            try await self.client.ignoreFaces(ids)
            return await self.currentPerson()
        }
    }

    /// Makes the one selected face their picture. The face stays in the grid.
    @discardableResult
    public func makeCover() async -> Bool {
        guard canMakeCover, let face = selectedFaces.first else { return false }
        return await makeCover(of: face.id)
    }

    /// Makes this face their picture (the long-press menu).
    @discardableResult
    public func makeCover(of face: Int) async -> Bool {
        guard !isWorking else { return false }
        message = ""
        isWorking = true
        defer { isWorking = false }
        do {
            person = try await client.setCover(person.id, face: face)
            return true
        } catch {
            if !(error is CancellationError) { message = PeopleMessages.failure(error) }
            return false
        }
    }

    // MARK: One write

    /// Runs a write on `ids`. A nil answer means the write did not happen and nothing changes. On
    /// success the faces leave the grid, the selection clears (selection mode stays) and the answer
    /// is the person's new state.
    @discardableResult
    private func act(_ ids: [Int], _ work: () async throws -> Person?) async -> Bool {
        guard !ids.isEmpty, !isWorking else { return false }
        message = ""
        isWorking = true
        defer { isWorking = false }
        do {
            guard let changed = try await work() else { return false }
            let gone = Set(ids)
            faces.removeAll { gone.contains($0.id) }
            total = max(0, total - ids.count)
            selected = []
            person = changed
            return true
        } catch {
            if !(error is CancellationError) { message = PeopleMessages.failure(error) }
            return false
        }
    }

    /// This person as the `people` list has them now, for a write whose answer is not about them.
    /// The write is done by then, so a list that can't be read leaves their counts as they were.
    private func currentPerson() async -> Person {
        let list = try? await client.people()
        return list?.people.first { $0.id == person.id } ?? person
    }
}
