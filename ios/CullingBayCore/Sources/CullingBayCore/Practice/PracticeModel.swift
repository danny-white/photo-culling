import Foundation
import Observation

/// State of the Practice tab, as `practice.js` keeps it: the challenges, which are waiting, done
/// or skipped, the notes Danny has typed, and the writes that mark one downloaded, done or
/// skipped. The server's answer to a write decides what a challenge then shows.
@MainActor
@Observable
public final class PracticeModel {
    /// In the file's order.
    public private(set) var challenges: [PracticeChallenge] = []
    /// Challenges left out because their photo is no longer in the library.
    public private(set) var missing = 0
    /// A load is running. The list stays on screen meanwhile.
    public private(set) var isLoading = false
    /// The server has answered at least once, so an empty list means there are none.
    public private(set) var hasLoaded = false
    /// What to say above the list or the detail: the server's `error`, a failed load, or a failed
    /// write. Empty when there is nothing to say.
    public private(set) var message = ""
    /// Notes typed and not yet saved, by challenge id. A failed save leaves its note here.
    public private(set) var drafts: [String: String] = [:]
    private var saving: [String: Int] = [:]

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generation = 0

    /// `now` stamps the download mark a challenge shows before the server answers; tests pin it.
    public init(client: CullingBayClient, now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    // MARK: Reading

    /// Todo and downloaded, in the file's order.
    public var waiting: [PracticeChallenge] {
        challenges.filter { $0.status == .todo || $0.status == .downloaded }
    }
    public var done: [PracticeChallenge] { challenges.filter { $0.status == .done } }
    public var skipped: [PracticeChallenge] { challenges.filter { $0.status == .skipped } }

    public func challenge(id: String) -> PracticeChallenge? {
        challenges.first { $0.id == id }
    }

    /// A write for this challenge is running, so its buttons should wait.
    public func isSaving(_ id: String) -> Bool { (saving[id] ?? 0) > 0 }

    // MARK: Loading

    /// Fetches the list (a 304 makes it cheap). A failed fetch keeps the list that is on screen
    /// and says why in `message`; a newer fetch makes an older answer unwelcome.
    public func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        do {
            let list = try await client.practice()
            guard mine == generation else { return }
            challenges = list.challenges
            missing = list.missing ?? 0
            message = list.error ?? ""
            hasLoaded = true
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled { return }
            message = GalleryMessages.failure(error, loading: "the challenges")
        }
    }

    // MARK: Notes

    /// What the note box shows: what was typed, else what the server has.
    public func draft(for id: String) -> String {
        drafts[id] ?? challenge(id: id)?.note ?? ""
    }

    /// Keeps what was typed. Text that is the saved note again is no draft.
    public func setDraft(_ text: String, for id: String) {
        drafts[id] = text == challenge(id: id)?.note ? nil : text
    }

    // MARK: Writing

    /// The RAW was fetched. The challenge shows it at once (downloaded, unless it is done) and
    /// the server is told in the background; if that fails the mark stays, quietly. The task is
    /// for tests to wait on.
    @discardableResult
    public func markDownloaded(_ id: String) -> Task<Void, Never> {
        guard let index = challenges.firstIndex(where: { $0.id == id }) else { return Task {} }
        if !challenges[index].wasDownloaded { challenges[index].downloadedAt = localStamp() }
        if challenges[index].status != .done { challenges[index].status = .downloaded }
        return Task { _ = await write(id, status: .downloaded, note: nil, quiet: true) }
    }

    /// Mark done (with the note), Skip, and the other moves. Returns whether the server took it;
    /// if not, the challenge is as it was and `message` says so.
    @discardableResult
    public func setStatus(_ status: PracticeStatus, for id: String, note: String? = nil) async -> Bool {
        await write(id, status: status, note: note, quiet: false)
    }

    /// Undo and Move to waiting: back to downloaded if the RAW was ever fetched, else to todo.
    @discardableResult
    public func moveToWaiting(_ id: String) async -> Bool {
        guard let challenge = challenge(id: id) else { return false }
        return await setStatus(challenge.wasDownloaded ? .downloaded : .todo, for: id)
    }

    /// Saves the note and leaves the status alone.
    @discardableResult
    public func saveNote(_ note: String, for id: String) async -> Bool {
        await write(id, status: nil, note: note, quiet: false)
    }

    private func write(_ id: String, status: PracticeStatus?, note: String?, quiet: Bool) async -> Bool {
        guard challenge(id: id) != nil else { return false }
        saving[id, default: 0] += 1
        defer {
            let left = (saving[id] ?? 1) - 1
            saving[id] = left > 0 ? left : nil
        }
        do {
            let state = try await client.updatePractice(id: id, status: status, note: note)
            // The list may have been loaded again while this ran, so look the challenge up now.
            if let index = challenges.firstIndex(where: { $0.id == id }) {
                challenges[index].apply(state)
            }
            if let note, drafts[id] == note { drafts[id] = nil }
            if !quiet { message = "" }
            return true
        } catch {
            if !quiet { message = "Not saved: \(Self.reason(error)). Your note is still here." }
            return false
        }
    }

    /// The error's text without a final full stop, since the sentence it ends has one.
    private static func reason(_ error: any Error) -> String {
        var text = CullFormat.errorText(error)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// `2026-11-21T10:15:00` in the phone's zone, the shape the server stamps.
    private func localStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: now())
    }
}
