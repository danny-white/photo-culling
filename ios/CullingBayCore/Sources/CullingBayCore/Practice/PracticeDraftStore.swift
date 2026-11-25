import Foundation

/// Where `PracticeModel` keeps the notes that are typed and not saved to the server, so a note
/// written while the PC could not be reached is still there after the app is closed. It runs on
/// the main actor, as the model does; a conforming type needs no locking.
@MainActor
public protocol PracticeDraftStore: AnyObject {
    /// The notes by challenge id; empty when none were saved or the file cannot be read.
    func load() -> [String: String]
    func save(_ drafts: [String: String])
}

/// A store in memory, for tests and previews. Sharing one between two models stands in for a relaunch.
@MainActor
public final class InMemoryPracticeDraftStore: PracticeDraftStore {
    public private(set) var drafts: [String: String]

    public init(drafts: [String: String] = [:]) {
        self.drafts = drafts
    }

    public func load() -> [String: String] { drafts }
    public func save(_ drafts: [String: String]) { self.drafts = drafts }
}

/// A store in one JSON file inside `directory` (the app passes a folder in Application Support),
/// written atomically so a crash mid-save leaves the old file. A missing or garbled file is no notes.
@MainActor
public final class FilePracticeDraftStore: PracticeDraftStore {
    public let fileURL: URL

    public init(directory: URL, fileName: String = "practice-notes.json") {
        fileURL = directory.appendingPathComponent(fileName)
    }

    public func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Best effort: a failed save leaves the notes in memory. No notes removes the file.
    public func save(_ drafts: [String: String]) {
        if drafts.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(drafts) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
