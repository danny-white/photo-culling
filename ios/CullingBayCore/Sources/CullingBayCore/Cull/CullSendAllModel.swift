import Foundation
import Observation

/// The Cull tab's Send all: every day with decisions not yet sent to Lightroom, the finished
/// ones ticked, and one send for all the ticked days (`POST /m/api/send`). Like a day's own
/// Send, it waits for the taps still saving first, so each day goes whole.
@MainActor
@Observable
public final class CullSendAllModel {
    public struct Item: Sendable, Hashable, Identifiable {
        public let day: Day
        /// `Tue, 4 Aug 2026`.
        public let title: String
        /// `Victoria, British Columbia`; nil without one.
        public let place: String?
        public let unsent: Int

        public var id: String { day.day }
        /// `46 decisions`.
        public var countText: String { "\(unsent) decision" + (unsent == 1 ? "" : "s") }
    }

    /// Finished in the cull, so ticked to start with. Newest first.
    public let finished: [Item]
    /// Still being culled: listed so they can be sent too, but not ticked.
    public let unfinished: [Item]
    public private(set) var selected: Set<String>
    public private(set) var isSending = false
    /// What happened, or why not.
    public private(set) var message = ""
    /// The send went through, so the sheet can close.
    public private(set) var didSend = false

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let queue: CullWriteQueue

    public init(days: [Day], client: CullingBayClient, queue: CullWriteQueue) {
        let items = days.compactMap { day -> Item? in
            let n = Self.unsent(day)
            guard n > 0 else { return nil }
            return Item(
                day: day, title: CullFormat.dayTitle(date: day.date, folder: day.folder),
                place: day.place.flatMap(CullDaysModel.placeLine), unsent: n)
        }
        finished = items.filter(\.day.finished)
        unfinished = items.filter { !$0.day.finished }
        selected = Set(finished.map(\.id))
        self.client = client
        self.queue = queue
    }

    /// Decisions a day has not sent yet. An older server without `unsent` gives decided minus
    /// sent, which misses decisions to send again after a sync could not find them.
    public static func unsent(_ day: Day) -> Int { day.unsent ?? max(0, day.decided - day.sent) }

    public var isEmpty: Bool { finished.isEmpty && unfinished.isEmpty }
    public var all: [Item] { finished + unfinished }
    public func isSelected(_ id: String) -> Bool { selected.contains(id) }

    public func toggle(_ id: String) {
        guard !isSending else { return }
        if selected.contains(id) { selected.remove(id) } else if all.contains(where: { $0.id == id }) { selected.insert(id) }
    }

    public func selectAll() { if !isSending { selected = Set(all.map(\.id)) } }
    public func selectNone() { if !isSending { selected = [] } }

    public var selectedDecisions: Int { all.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.unsent } }

    /// `Send 3 days to Lightroom`, or `Pick the days to send`.
    public var sendLabel: String {
        let n = selected.count
        return n == 0 ? "Pick the days to send" : "Send \(n) day" + (n == 1 ? "" : "s") + " to Lightroom"
    }

    /// `128 decisions from 3 days`.
    public var selectionText: String {
        let n = selected.count, d = selectedDecisions
        return "\(d) decision" + (d == 1 ? "" : "s") + " from \(n) day" + (n == 1 ? "" : "s")
    }

    /// Sends the ticked days, in the list's order. Returns whether they went.
    @discardableResult
    public func send() async -> Bool {
        let days = all.map(\.id).filter { selected.contains($0) }
        guard !days.isEmpty, !isSending else { return false }
        isSending = true
        defer { isSending = false }
        guard await queue.drain(timeout: CullSessionModel.drainTimeout) else {
            message = "Still offline: \(queue.pending) taps waiting to save. Send once they are in."
            return false
        }
        do {
            let result = try await client.sendDays(days)
            message = result.queued > 0
                ? "Queued \(result.queued) decisions from \(days.count) day" + (days.count == 1 ? "" : "s")
                    + " for Lightroom. On the Mac: Sync AI Cull Data."
                : "Nothing new to send."
            didSend = true
            return true
        } catch {
            message = "Not sent: " + CullFormat.errorText(error)
            return false
        }
    }
}
