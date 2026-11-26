import Foundation
import Observation

/// State of the People tab's first screen: the named people, the unnamed groups worth naming, how
/// far the face search has got, and the name filter. It reads `GET /m/api/people` and keeps
/// nothing on the phone: People needs the PC.
@MainActor
@Observable
public final class PeopleHomeModel {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// Most photos first.
    public private(set) var people: [Person] = []
    /// The unnamed groups worth naming, the likeliest friends and family first.
    public private(set) var groups: [FaceGroup] = []
    /// Photos checked for faces, and photos in the library.
    public private(set) var facesChecked = 0
    public private(set) var photosOK = 0
    /// Why the last `refresh()` failed while an earlier result is still on screen; nil otherwise.
    public private(set) var refreshError: String?
    /// The name filter. Empty shows everyone.
    public var filter = ""

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasLoaded = false

    public init(client: CullingBayClient) {
        self.client = client
    }

    // MARK: Loading

    /// Loads the list. Shows `.loading` unless a result is already on screen.
    public func load() async {
        if !hasLoaded { phase = .loading }
        await fetch()
    }

    /// Fetches again (a 304 makes it cheap). The current result stays on screen meanwhile and, if
    /// the fetch fails, afterwards; `refreshError` says why.
    public func refresh() async {
        await fetch()
    }

    private func fetch() async {
        generation += 1
        let mine = generation
        do {
            let list = try await client.people()
            guard mine == generation else { return }
            apply(list)
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled {
                if !hasLoaded { phase = .idle }
                return
            }
            let message = GalleryMessages.failure(error, loading: "the people")
            if hasLoaded {
                refreshError = message
            } else {
                phase = .failed(message)
            }
        }
    }

    private func apply(_ list: PeopleList) {
        people = list.people
        groups = list.groups
        facesChecked = list.facesChecked
        photosOK = list.photosOK
        hasLoaded = true
        refreshError = nil
        phase = .loaded
    }

    // MARK: What the screen shows

    public var isFiltering: Bool { !query.isEmpty }

    private var query: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The people whose names hold the filter, case aside.
    public var visiblePeople: [Person] {
        guard isFiltering else { return people }
        return people.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// With no filter, every group; with one, the groups that look like a person whose name holds it.
    public var visibleGroups: [FaceGroup] {
        guard isFiltering else { return groups }
        return groups.filter { $0.maybe?.name.localizedCaseInsensitiveContains(query) == true }
    }

    /// `"Finding faces… 8,609 of 43,195 photos"` while the backfill or an import is running.
    public var progress: String? {
        PeopleFormat.progress(checked: facesChecked, of: photosOK)
    }

    /// Said under People while nobody is named but there are groups to name.
    public var noPeopleHint: String? {
        guard phase == .loaded, people.isEmpty, !isFiltering, !groups.isEmpty else { return nil }
        return "Nobody is named yet. Open a group below and give it a name."
    }

    /// What to say in place of the grids when there is nothing to show; nil while there is.
    public var emptyMessage: String? {
        guard phase == .loaded, visiblePeople.isEmpty, visibleGroups.isEmpty else { return nil }
        if isFiltering { return "No one matches “\(query)”." }
        return facesChecked == 0
            ? "No faces yet. They appear here once the PC has looked through the photos."
            : "No faces to name right now."
    }

    /// A person as the last load had them, for a screen that opens before its own load answers.
    public func person(id: Int) -> Person? { people.first { $0.id == id } }

    /// A group as the last load had it, for a screen that opens before its own load answers.
    public func group(key: Int) -> FaceGroup? { groups.first { $0.key == key } }
}
