import Foundation

/// The Cull tab's routes. Reads go through the same ETag cache as the Gallery's. Writes never
/// do; a successful one drops the cached `GET /m/api/day/<day>` it made stale.
extension CullingBayClient {
    // MARK: Reads

    /// `day` is the day id such as `2026/2026-10-01`; the slash stays a path separator.
    public func cullDay(_ day: String) async throws -> CullDay {
        let fetched: Fetched<CullDay> = try await fetch(path: "/m/api/day/\(day)")
        return fetched.value
    }

    /// Days to review for a query, each with its matching photo ids.
    public func daySearch(_ q: String) async throws -> DaySearchResult {
        let fetched: Fetched<DaySearchResult> = try await fetch(
            path: "/m/api/search", query: [("q", q)])
        return fetched.value
    }

    /// Other days with photos like this one.
    public func dayLike(_ id: Int) async throws -> DaySearchResult {
        let fetched: Fetched<DaySearchResult> = try await fetch(path: "/m/api/like/\(id)")
        return fetched.value
    }

    // MARK: Writes

    /// A fresh action id for `decide`: a UUID string.
    public nonisolated static func newActionID() -> String { UUID().uuidString }

    /// One tap: the changes made together, saved as one action that `undo(actionID:)` takes back.
    ///
    /// `actionID` makes a retry safe. Keep it, and resend the same call with the same id after a
    /// dropped response: a repeated id answers `replay` and changes nothing, even if the changes
    /// differ. Don't reuse an id after an undo, or the new decision is ignored.
    /// `label` is free text kept with the action; the server never reads it back.
    @discardableResult
    public func decide(
        actionID: String, day: String, label: String = "", changes: [CullChange]
    ) async throws -> CullAck {
        try await writeJSON(
            method: "POST", path: "/m/api/decide",
            body: DecideBody(actionID: actionID, day: day, label: label, changes: changes),
            staling: .day(day))
    }

    /// `decide` with a freshly generated action id, which it returns so the tap can be undone.
    public func decide(
        day: String, label: String = "", changes: [CullChange]
    ) async throws -> (actionID: String, ack: CullAck) {
        let actionID = Self.newActionID()
        let ack = try await decide(actionID: actionID, day: day, label: label, changes: changes)
        return (actionID, ack)
    }

    /// Puts the rows back as they were before that action. The id doesn't say which day it was
    /// for, so every cached cull day is dropped.
    @discardableResult
    public func undo(actionID: String) async throws -> CullAck {
        try await writeJSON(
            method: "POST", path: "/m/api/undo", body: UndoBody(actionID: actionID), staling: .allDays)
    }

    /// Saves where the session stopped. `pass` is 1 or 2 and `cursor` a `Stack.id`. `finished`
    /// marks the day finished; it can't be turned off again except by `reset`.
    @discardableResult
    public func saveProgress(
        day: String, pass: Int, cursor: Int, finished: Bool = false
    ) async throws -> CullAck {
        try await writeJSON(
            method: "PUT", path: "/m/api/day/\(day)/progress",
            body: ProgressBody(pass: pass, cursor: cursor, finished: finished), staling: .day(day))
    }

    /// Queues the day's unsent decisions for the next Lightroom sync. Throws `.unavailable` when
    /// the inbox share isn't mounted on the PC.
    public func send(day: String) async throws -> SendResult {
        try await writeJSON(
            method: "POST", path: "/m/api/day/\(day)/send", body: EmptyBody(), staling: .day(day))
    }

    /// Starts the day over on the phone. Throws `.conflict` (with `applied`) once any of its
    /// decisions has reached Lightroom, and `.unavailable` when queued rows can't be withdrawn.
    public func reset(day: String) async throws -> ResetResult {
        try await writeJSON(
            method: "POST", path: "/m/api/day/\(day)/reset", body: EmptyBody(), staling: .day(day))
    }
}

private struct DecideBody: Encodable, Sendable {
    let actionID: String
    let day: String
    let label: String
    let changes: [CullChange]

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case day, label, changes
    }
}

private struct UndoBody: Encodable, Sendable {
    let actionID: String

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
    }
}

private struct ProgressBody: Encodable, Sendable {
    let pass: Int
    let cursor: Int
    let finished: Bool
}

private struct EmptyBody: Encodable, Sendable {}
