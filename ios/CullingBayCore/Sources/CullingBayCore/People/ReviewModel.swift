import Foundation
import Observation

/// "Is this Alex?": the faces that may be one person, a batch of up to 60 at a time. Every face
/// starts as yes and a tap turns it into no; Confirm sends the batch (yes becomes a confirmed
/// face, no means never suggest it for them again) and loads the next, until none are left.
/// Unnamed groups that look like them come first, each with its own Yes and No, which send at once.
@MainActor
@Observable
public final class ReviewModel {
    public enum Phase: Sendable, Hashable {
        case loading
        case reviewing
        /// Nothing is left to review.
        case done
        case failed(String)
    }

    public let personID: Int
    /// The person as the server last said, so the title and the count to go are current.
    public private(set) var person: Person
    public private(set) var phase: Phase = .loading
    /// This batch, most alike first.
    public private(set) var faces: [FaceSuggestion] = []
    /// Unnamed groups that may be them, still unanswered.
    public private(set) var groups: [FaceGroup] = []
    /// Faces of this batch turned into no.
    public private(set) var noes: Set<Int> = []
    /// Faces confirmed and faces turned down, over every batch of this review.
    public private(set) var confirmedTotal = 0
    public private(set) var removedTotal = 0
    /// Why the last write failed; empty when it didn't.
    public private(set) var message = ""
    public private(set) var isWorking = false

    @ObservationIgnored private let client: CullingBayClient

    public init(person: Person, client: CullingBayClient) {
        self.personID = person.id
        self.person = person
        self.client = client
    }

    // MARK: Reading

    /// `"Is this Alex?"`
    public var title: String { "Is this \(person.name)?" }

    /// Faces of this batch that stay yes, and those turned into no.
    public var yesCount: Int { faces.count - noes.count }
    public var noCount: Int { noes.count }

    /// Suggestions the server still has after this batch; 0 when it is the last.
    public var moreAfterThis: Int { max(0, person.suggestions - faces.count) }

    public func isNo(_ face: Int) -> Bool { noes.contains(face) }

    /// Every face of this batch is no: the batch has faces and none is left as yes.
    public var allNo: Bool { !faces.isEmpty && noes.count == faces.count }

    // MARK: Loading

    /// Loads the next batch. Nothing in it (no faces and no groups) is `.done`.
    public func load() async {
        phase = .loading
        do {
            let batch = try await client.suggestions(for: personID)
            faces = batch.faces
            groups = batch.groups
            noes = []
            phase = batch.faces.isEmpty && batch.groups.isEmpty ? .done : .reviewing
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            phase = .failed(GalleryMessages.failure(error, loading: "the suggestions"))
        }
    }

    // MARK: Answering

    /// Turns a face into no, or back into yes.
    public func toggle(_ face: Int) {
        guard faces.contains(where: { $0.id == face }) else { return }
        if !noes.insert(face).inserted { noes.remove(face) }
    }

    /// Turns every face of this batch into no (`true`), or every one back into yes (`false`), for when none
    /// of them, or all of them, are the person. Sends nothing: Confirm does.
    public func markAll(no: Bool) {
        noes = no ? Set(faces.map(\.id)) : []
    }

    /// Sends this batch as one review, then loads the next. A failure keeps the batch, with every
    /// tap, so Confirm can be pressed again.
    public func confirm() async {
        guard phase == .reviewing, !faces.isEmpty, !isWorking else { return }
        let no = faces.map(\.id).filter(noes.contains)
        let yes = faces.map(\.id).filter { !noes.contains($0) }
        message = ""
        isWorking = true
        do {
            person = try await client.reviewSuggestions(personID, yes: yes, no: no)
        } catch {
            isWorking = false
            if !(error is CancellationError) { message = PeopleMessages.failure(error) }
            return
        }
        isWorking = false
        confirmedTotal += yes.count
        removedTotal += no.count
        await load()
    }

    /// Answers "Might be Alex" for a group. Yes adds its faces to them; no says they are not them, and
    /// the server remembers. Either way the group leaves the list, and the groups are read again
    /// (the faces, and the taps on them, stay as they are).
    public func answer(group: FaceGroup, yes: Bool) async {
        guard !isWorking else { return }
        message = ""
        isWorking = true
        defer { isWorking = false }
        do {
            if yes {
                person = try await client.addFaces(to: personID, group: group.key)
            } else {
                person = try await client.removeGroup(group.key, from: personID)
            }
            groups.removeAll { $0.key == group.key }
            if let batch = try? await client.suggestions(for: personID) { groups = batch.groups }
            if faces.isEmpty && groups.isEmpty { phase = .done }
        } catch {
            if !(error is CancellationError) { message = PeopleMessages.failure(error) }
        }
    }
}
