import Foundation

/// One write to the server, in a form that can be sent again exactly: a `decide` keeps its
/// `action_id`, so a resend after a dropped answer changes nothing.
public enum CullWrite: Codable, Sendable, Hashable {
    case decide(actionID: String, day: String, label: String, changes: [CullChange])
    case undo(actionID: String)
    /// `lead` is the `Stack.lead` of the cursor's stack, so the server can keep the cursor on the
    /// same stack after photos are added.
    case progress(day: String, pass: Int, cursor: Int, finished: Bool, lead: Int?)
}

/// Where `CullWriteQueue` keeps its items, so taps survive the app being closed. It runs on the
/// main actor, as the queue does; a conforming type needs no locking.
@MainActor
public protocol CullWriteStore: AnyObject {
    /// What was saved; empty when nothing was or it cannot be read.
    func load() -> [CullWrite]
    func save(_ writes: [CullWrite])
}

/// A store in memory, for tests and previews. Sharing one between two queues stands in for a
/// relaunch.
@MainActor
public final class InMemoryCullWriteStore: CullWriteStore {
    public private(set) var writes: [CullWrite]

    public init(writes: [CullWrite] = []) {
        self.writes = writes
    }

    public func load() -> [CullWrite] { writes }
    public func save(_ writes: [CullWrite]) { self.writes = writes }
}

/// A store in one JSON file inside `directory` (the app passes its Application Support or
/// Caches folder), written atomically so a crash mid-save leaves the old file.
@MainActor
public final class FileCullWriteStore: CullWriteStore {
    public let fileURL: URL

    public init(directory: URL, fileName: String = "cull-write-queue.json") {
        fileURL = directory.appendingPathComponent(fileName)
    }

    public func load() -> [CullWrite] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CullWrite].self, from: data)) ?? []
    }

    /// Best effort, like the web app's `localStorage`: a failed save leaves the queue in memory.
    public func save(_ writes: [CullWrite]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(writes) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
