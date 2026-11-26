import Foundation
import Observation

/// Choosing a person: the named people, filtered as Danny types, and a "New person" row for what
/// he typed when no one has that name. Used to name a group, to move faces to someone, to merge
/// one person into another, and to say who a face in a photo is.
@MainActor
@Observable
public final class PersonPickerModel {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public enum Choice: Sendable, Hashable {
        case person(Person)
        /// A new person; the name is already cleaned.
        case new(name: String)
    }

    public private(set) var phase: Phase = .idle
    /// Everyone named, most photos first, except the people left out.
    public private(set) var everyone: [Person] = []
    /// What Danny has typed.
    public var text = ""

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let excluded: Set<Int>
    @ObservationIgnored private var named: [Person] = []

    /// `excluding` are people who are not a choice, such as the person the faces are moving away
    /// from. They still count as having their name.
    public init(client: CullingBayClient, excluding: Set<Int> = []) {
        self.client = client
        self.excluded = excluding
    }

    public func load() async {
        phase = .loading
        do {
            let list = try await client.people()
            named = list.people
            everyone = list.people.filter { !excluded.contains($0.id) }
            phase = .loaded
        } catch {
            if error is CancellationError || Task.isCancelled {
                phase = .idle
            } else {
                phase = .failed(GalleryMessages.failure(error, loading: "the people"))
            }
        }
    }

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The people whose names hold what was typed, case aside, those that start with it first. All
    /// of them while nothing is typed.
    public var matches: [Person] {
        let query = query
        guard !query.isEmpty else { return everyone }
        let found = everyone.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let starts = found.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
        return starts + found.filter { person in !starts.contains { $0.id == person.id } }
    }

    /// Someone who has exactly what was typed as their name, case aside, even a person left out.
    public var sameName: Person? {
        let query = query.lowercased()
        return query.isEmpty ? nil : named.first { $0.name.lowercased() == query }
    }

    /// The name for a "New person" row: what was typed, when it is a good name and no one has it.
    public var newName: String? {
        guard sameName == nil else { return nil }
        return PeopleFormat.cleanName(text)
    }
}
