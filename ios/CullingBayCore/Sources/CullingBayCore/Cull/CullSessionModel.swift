import Foundation
import Observation

/// State of one opened day in the Cull tab: the port of `S` and the functions around it in
/// `app.js` (`openDay`, `decide`, `keepFrames`, `act`, `undo`, `advance`, `go`, `saveProgress`,
/// `sendDay`, `vCull`, `vSummary`). The SwiftUI views only bind to it and call its methods.
///
/// Every tap updates the local decisions at once and is sent through the `CullWriteQueue`. Make
/// a new model per opened day, and call `load()`.
///
/// Phase 2 only: the burst picker and knock-out, the grid, 1:1 and focus views, rescue and drop
/// from the review, and Start over are not here.
@MainActor
@Observable
public final class CullSessionModel {
    /// `NOTE_PREFIX`: the note on the frames a burst keep rejects, followed by the kept file stems.
    public static let notePrefix = "Burst reject · kept "
    /// How long Send waits for the queue before it gives up.
    public static let drainTimeout: Duration = .seconds(10)
    /// The wait before a position is saved, so a run of moves is one save.
    public static let progressDelay: Duration = .milliseconds(600)

    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// What the day shows: the cards, or the end-of-day review.
    public enum Screen: Sendable, Hashable {
        case cards
        case summary
    }

    /// A message for the toast, shown for about 2.8 s. It carries an Undo button when
    /// `offersUndo` is set; the button calls `undo()`.
    public struct Toast: Sendable, Hashable, Identifiable {
        /// 1, 2, ...: tells one toast from the next, even with the same text.
        public let id: Int
        public let text: String
        public let offersUndo: Bool
    }

    /// The last thing the user did, for a haptic: watch `id` and play one per change.
    public struct Feedback: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            case kept, hero, rejected, undone
        }

        public let id: Int
        public let kind: Kind
    }

    /// Stacks that matched a search, which were moved to the front.
    public struct Matches: Sendable, Hashable {
        public let count: Int
        public let label: String
    }

    public let dayID: String
    public let queue: CullWriteQueue

    public private(set) var phase: Phase = .idle
    /// Why the last `refresh()` failed while the day is on screen; nil otherwise.
    public private(set) var refreshError: String?
    public private(set) var day: CullDay?
    public private(set) var screen: Screen = .cards
    /// The stack on the card, an index into `stacks`.
    public private(set) var cursor = 0
    /// The pass the server records; always 2.
    public private(set) var pass = 2
    public private(set) var matches: Matches?
    public private(set) var toast: Toast?
    public private(set) var feedback: Feedback?
    public private(set) var isSending = false

    private var board = CullBoard()
    private var history: [HistoryEntry] = []

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let match: CullMatch?
    @ObservationIgnored private let sleep: CullSleep
    @ObservationIgnored private let newActionID: @Sendable () -> String
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var edits = 0
    @ObservationIgnored private var toastCount = 0
    @ObservationIgnored private var feedbackCount = 0
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var undone: [String: HistoryEntry] = [:]

    /// One tap, kept for Undo: the decisions as they were, and where the cursor was.
    private struct HistoryEntry {
        let actionID: String
        let label: String
        let before: [(id: Int, decision: Decision?)]
        let changes: [CullChange]
        let cursor: Int
        let pass: Int
    }

    /// `match` is the search hit the day was opened from: its stacks go first. `newActionID`
    /// makes the ids of `decide`; tests pin it.
    public init(
        day: String, client: CullingBayClient, queue: CullWriteQueue, match: CullMatch? = nil,
        sleep: @escaping CullSleep = CullClock.system,
        newActionID: @escaping @Sendable () -> String = { CullingBayClient.newActionID() }
    ) {
        self.dayID = day
        self.client = client
        self.queue = queue
        self.match = match
        self.sleep = sleep
        self.newActionID = newActionID
        queue.observeDrops(self) { [weak self] drop in self?.queueDropped(drop) }
    }

    /// Call when the day's screen goes away. A position save still waiting goes out anyway.
    public func close() {
        queue.stopObservingDrops(self)
    }

    // MARK: Opening

    /// `openDay`: loads the day, fills the decisions from it, puts the search matches first and
    /// starts on the saved stack, or the first open one after it, or on the review.
    public func load() async {
        generation += 1
        let mine = generation
        phase = .loading
        do {
            let body = try await client.cullDay(dayID)
            guard mine == generation else { return }
            open(body)
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled {
                phase = day == nil ? .idle : .loaded
            } else {
                phase = .failed(GalleryMessages.failure(error, loading: "this day"))
            }
        }
    }

    /// Loads the day again for the receipts (`landed`, `conflict`, ...) and keeps the cursor on
    /// the same stack. First waits up to `waiting` for the queue to empty, so no tap is lost, and
    /// drops the answer if you decide something while it is on its way.
    public func refresh(waiting: Duration = .seconds(3)) async {
        guard day != nil else { return await load() }
        generation += 1
        let mine = generation
        let seen = edits
        guard await queue.drain(timeout: waiting) else {
            refreshError = "Still offline: \(queue.pending) taps waiting to save. Refresh once they are in."
            return
        }
        do {
            let body = try await client.cullDay(dayID)
            guard mine == generation, seen == edits else { return }
            reload(body)
            refreshError = nil
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled { return }
            refreshError = GalleryMessages.failure(error, loading: "this day")
        }
    }

    private struct Arranged {
        var stacks: [Stack]
        var decisions: [Int: Decision]
        var matches: Matches?
    }

    /// The day's stacks with the search matches first, and its decisions.
    private func arrange(_ body: CullDay) -> Arranged {
        var stacks = body.stacks.filter { !$0.frames.isEmpty }
        var decisions: [Int: Decision] = [:]
        for stack in stacks {
            for frame in stack.frames {
                if let decision = frame.decision { decisions[frame.id] = decision }
            }
        }
        var matches: Matches?
        if let match {
            let ids = Set(match.ids)
            let first = stacks.filter { $0.frames.contains { ids.contains($0.id) } }
            if !first.isEmpty && first.count < stacks.count {
                let inFirst = Set(first.map(\.id))
                stacks = first + stacks.filter { !inFirst.contains($0.id) }
                matches = Matches(count: first.count, label: match.label)
            }
        }
        return Arranged(stacks: stacks, decisions: decisions, matches: matches)
    }

    private func open(_ body: CullDay) {
        let arranged = arrange(body)
        day = body
        board = CullBoard(stacks: arranged.stacks, decisions: arranged.decisions, budget: body.budget.stacks)
        matches = arranged.matches
        history = []
        undone = [:]
        pass = 2        // one pass now; the server still records pass and position
        var start = 0
        if matches == nil, let saved = body.progress?.cursor {
            start = max(0, board.stacks.firstIndex { $0.id == saved } ?? 0)
        }
        cursor = start
        if board.stacks.isEmpty {
            screen = .summary
        } else if let i = board.status(board.stacks[start]).isDone ? board.firstOpen(from: start) : start {
            cursor = i
            screen = .cards
        } else {
            screen = .summary
        }
        refreshError = nil
        phase = .loaded
    }

    private func reload(_ body: CullDay) {
        let lead = currentStack?.lead
        let arranged = arrange(body)
        day = body
        board = CullBoard(stacks: arranged.stacks, decisions: arranged.decisions, budget: body.budget.stacks)
        matches = arranged.matches
        if let lead, let i = board.stacks.firstIndex(where: { $0.lead == lead }) {
            cursor = i
        } else {
            cursor = max(0, min(cursor, board.stacks.count - 1))
        }
        if board.stacks.isEmpty { screen = .summary }
    }

    // MARK: Reading

    public var stacks: [Stack] { board.stacks }
    /// The phone's decision on each frame, by `Frame.id`.
    public var decisions: [Int: Decision] { board.decisions }
    /// The stack the cursor is on.
    public var currentStack: Stack? {
        board.stacks.indices.contains(cursor) ? board.stacks[cursor] : nil
    }
    public var canUndo: Bool { !history.isEmpty }

    /// `dayTitle`: `Sat, 17 Oct 2026`.
    public var title: String {
        day.map { CullFormat.dayTitle(date: $0.date, folder: $0.folder) }
            ?? String(dayID.split(separator: "/").last ?? "")
    }

    /// Stacks not yet decided.
    public var stacksLeft: Int { board.stacks.count - board.doneCount }

    /// `3 stacks to go`.
    public var toGoText: String { "\(stacksLeft) stack" + (stacksLeft == 1 ? "" : "s") + " to go" }

    /// `2 matches first`, the chip in the top bar for a day opened from a search; nil otherwise.
    /// Tapping it calls `explainMatches()`.
    public var matchesChip: String? {
        matches.map { "\($0.count) match" + ($0.count == 1 ? "" : "es") + " first" }
    }

    /// The share of stacks decided, 0 to 1.
    public var progressFraction: Double {
        board.stacks.isEmpty ? 0 : Double(board.doneCount) / Double(board.stacks.count)
    }

    /// The budget bar; nil when the day has no budget.
    public var budgetBar: CullBudgetBar? {
        guard let budget = day?.budget, budget.stacks > 0 else { return nil }
        let kept = board.keptCount
        let over = kept - budget.stacks
        return CullBudgetBar(
            kept: kept, limit: budget.stacks,
            text: over > 0 ? "Kept \(kept) · \(over) over \(budget.stacks)" : "Kept \(kept) of \(budget.stacks)",
            fraction: min(1, Double(kept) / Double(budget.stacks)),
            detail: "\(budget.perHour) stacks an hour of shooting (\(CullFormat.number(budget.hours)) h)")
    }

    /// `vCull`: the card for the stack under the cursor; nil when there is none.
    public var card: CullCard? {
        guard let stack = currentStack else { return nil }
        let frame = board.shown(stack)
        let st = board.status(stack)
        let isBurst = stack.frames.count > 1

        var badges: [CullBadge] = []
        switch stack.kind {
        case .pano: badges.append(CullBadge(text: "Looks like a panorama", style: .hint))
        case .bracket: badges.append(CullBadge(text: "Looks like a bracket", style: .hint))
        default:
            if isBurst && frame.id == stack.lead { badges.append(CullBadge(text: "Sharpest", style: .hint)) }
        }
        badges += frame.badges.map { CullBadge(text: $0, style: .measured) }
        if st.source != .lightroom, let word = board.lrWord(frame) {
            badges.append(CullBadge(text: word, style: .lightroom))
        }

        let chip: CullChip? = isBurst
            ? .burst(count: stack.frames.count)
            : frame.partners.isEmpty ? nil
            : .partners("RAW + " + frame.partners.map {
                ($0.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? $0)
                    .uppercased()
            }.joined(separator: " + "))

        // The button that made the decision shows pressed when you come back to the stack.
        let kept = stack.frames.filter { CullBoard.isPick(board.decisions[$0.id]) }.count
        func pressed(_ button: PressedButton) -> Bool {
            guard let verdict = st.verdict else { return false }
            if button == .reject { return verdict == .reject }
            if verdict == .reject { return false }
            switch button {
            case .hero: return verdict == .hero
            case .keepAll: return st.source != .lightroom && kept == stack.frames.count
            default: return verdict != .hero && (st.source == .lightroom || !isBurst || kept < stack.frames.count)
            }
        }
        let keepPressed = isBurst ? pressed(.keep) : pressed(.keep) || pressed(.hero)

        let n = board.stacks.count
        return CullCard(
            stack: stack, frame: frame, status: st, isBurst: isBurst,
            suggestsKeepAll: (stack.kind == .pano || stack.kind == .bracket) && !st.isDone,
            badges: badges, chip: chip, statusLine: board.statusLine(stack),
            strip: isBurst ? stack.frames.prefix(6).map { CullStripItem(frame: $0, mark: board.markOf($0)) } : [],
            stripMore: max(0, stack.frames.count - 6),
            pressed: CullPressed(reject: pressed(.reject), keepAll: isBurst && pressed(.keepAll), keep: keepPressed),
            stars: !isBurst && st.isDone && st.verdict != .reject ? board.frameMark(frame)?.stars ?? 0 : 0,
            keepAllLabel: "Keep all \(stack.frames.count)",
            fileLine: ([frame.file] + frame.partners).joined(separator: " + ") + " · \(cursor + 1)/\(n)")
    }

    private enum PressedButton { case reject, keepAll, hero, keep }

    /// `vSummary`: the end-of-day review.
    public var summary: CullSummary {
        let all = board.stacks.flatMap(\.frames)
        let inLightroom = Set(
            board.stacks.filter { board.status($0).source == .lightroom }.flatMap { $0.frames.map(\.id) })
        var kept = 0, hero = 0, rejected = 0, none = 0
        for frame in all {
            let d = board.decisions[frame.id]
            if d == nil || d?.flag == .clear {
                if !inLightroom.contains(frame.id) { none += 1 }
            } else if d?.flag == .reject {
                rejected += 1
            } else if d?.stars == 5 {
                hero += 1
            } else {
                kept += 1
            }
        }
        let rejects = all.filter {
            let d = board.decisions[$0.id]
            return d?.flag == .reject && d?.state != .conflict
        }
        let won = all.filter { board.decisions[$0.id]?.state == .conflict }
        let skipped = board.lrDone
        let decided = all.compactMap { board.decisions[$0.id] }
        func by(_ state: DecisionState) -> Int { decided.filter { $0.state == state }.count }
        let missing = by(.missing)
        let unsent = by(.draft) + missing
        let queued = by(.queued), landed = by(.landed), conflicts = by(.conflict)

        var lines: [String] = []
        if landed > 0 { lines.append("\(landed) in Lightroom") }
        if queued > 0 { lines.append("\(queued) waiting for the next Sync AI Cull Data") }
        if missing > 0 { lines.append("\(missing) not found in the last sync, will go again") }
        if skipped > 0 {
            lines.append(
                "\(skipped) stack" + (skipped > 1 ? "s were" : " was")
                    + " already flagged or rated in Lightroom and skipped")
        }

        let limit = board.budget
        let keptStacks = board.keptCount
        let over = limit > 0 ? keptStacks - limit : 0
        var heading: String?
        var note: String?
        var dropHint: String?
        if over > 0, let budget = day?.budget {
            heading = "Kept · \(keptStacks) of \(limit)"
            note = "\(over) over this shoot’s budget of \(limit) (\(budget.perHour) stacks an hour of shooting)."
            dropHint = "Tap a stack to drop it."
        } else if limit > 0 {
            note = "Kept \(keptStacks) of this shoot’s budget of \(limit)."
        }

        let burstNote: (Frame) -> Bool = { !(self.board.decisions[$0.id]?.note ?? "").isEmpty }
        return CullSummary(
            kept: kept, hero: hero, rejected: rejected, unflagged: none,
            subtitle: board.firstOpen() == nil ? "Day finished" : "Rejects so far",
            daySummary: day?.summary.flatMap { $0.isEmpty ? nil : $0 },
            unsent: unsent, missing: missing, queued: queued, landed: landed, conflicts: conflicts,
            lightroomLines: lines,
            won: won.map { CullSummary.Won(frame: $0, label: board.lrShort($0)) },
            wonNote: won.isEmpty ? nil
                : "The phone said otherwise, but you had flagged " + (won.count > 1 ? "these" : "this")
                + " in Lightroom yourself, so Lightroom kept your flag. Change it there if the phone was right.",
            rejectsFromBursts: rejects.filter(burstNote),
            rejectsOutright: rejects.filter { !burstNote($0) },
            overBudget: max(0, over), budgetHeading: heading, budgetNote: note, budgetDropHint: dropHint,
            sendLabel: unsent > 0 ? "Send \(unsent) to Lightroom" : queued > 0 ? "Waiting for Lightroom"
                : landed > 0 ? "In Lightroom" : "Send to Lightroom",
            canSend: unsent > 0)
    }

    // MARK: Moving

    /// `go`: browse to the next (`1`) or previous (`-1`) stack and save the position. Going on
    /// from the last stack opens the review.
    public func go(_ delta: Int) {
        guard screen == .cards, !board.stacks.isEmpty else { return }
        let n = board.stacks.count
        if delta > 0 && cursor == n - 1 {
            screen = .summary
            return
        }
        cursor = max(0, min(n - 1, cursor + delta))
        saveProgress()
    }

    /// `back-cull`: from the review back to the cards, on the first stack still open.
    public func backToCards() {
        if let i = board.firstOpen(from: cursor) { cursor = i }
        screen = .cards
    }

    /// The toast for the "N matches first" chip.
    public func explainMatches() {
        guard let matches else { return }
        showToast(
            "\(matches.count) stack" + (matches.count == 1 ? "" : "s") + " matched \(matches.label), "
                + "so they come first. The rest of the day follows.")
    }

    public func dismissToast() { toast = nil }

    // MARK: Deciding

    /// Rejects every frame of the stack and moves on.
    public func reject() {
        guard screen == .cards, let stack = currentStack else { return }
        commit(
            stack.frames.count > 1
                ? "Rejected all \(stack.frames.count)" : "Rejected " + CullFormat.stem(stack.frames[0].file),
            stack.frames.map { CullChange(id: $0.id, flag: .reject, note: "", via: .card) })
    }

    /// Keeps every frame of the stack and moves on.
    public func keepAll() {
        guard screen == .cards, let stack = currentStack else { return }
        commit(
            "Kept all \(stack.frames.count)"
                + (stack.kind == .pano ? " · panorama" : stack.kind == .bracket ? " · bracket" : ""),
            stack.frames.map { CullChange(id: $0.id, flag: .pick, note: "", via: .card) })
    }

    /// Keeps the frame on the card, with `stars` (1 to 5) if given, and moves on. On a burst
    /// the other frames are rejected with a note naming the kept one.
    public func keep(stars: Int? = nil) {
        guard screen == .cards, let stack = currentStack else { return }
        let frame = board.shown(stack)
        keepFrames(of: stack, [frame], rates: stars.flatMap { (1...5).contains($0) ? [frame.id: $0] : nil }, via: .card)
    }

    /// `keepFrames`: keeps `keeps` and rejects the rest of the stack with the burst note.
    /// `rates` has the stars for a kept frame.
    private func keepFrames(of stack: Stack, _ keeps: [Frame], rates: [Int: Int]?, via: CullVia) {
        let rates = rates ?? [:]
        var changes = keeps.map {
            CullChange(id: $0.id, flag: .pick, stars: rates[$0.id], note: "", via: via)
        }
        let keepIDs = Set(keeps.map(\.id))
        let others = stack.frames.filter { !keepIDs.contains($0.id) }
        let note = Self.notePrefix + keeps.map { CullFormat.stem($0.file) }.joined(separator: ", ")
        changes += others.map { CullChange(id: $0.id, flag: .reject, note: note, via: via) }
        let head = "Kept " + (keeps.count > 1
            ? "\(keeps.count) frames"
            : CullFormat.stem(keeps[0].file) + (rates[keeps[0].id].map { " " + CullFormat.starText($0) } ?? ""))
        commit(others.isEmpty ? head : head + " · \(others.count) rejected with a note", changes)
    }

    /// `commit`: saves the tap, says what happened (with the Lightroom and budget notes), moves on.
    private func commit(_ label: String, _ changes: [CullChange]) {
        act(label, changes)
        showToast(
            label + CullBoard.clashNote(board.lrClashes(changes), board.lrRatedRejects(changes))
                + (changes.contains { $0.flag == .pick } ? board.overNote : ""),
            offersUndo: true)
        let hero = changes.contains { $0.flag == .pick && $0.stars == 5 }
        signal(changes.contains { $0.flag == .pick } ? (hero ? .hero : .kept) : .rejected)
        advance()
    }

    /// `act`: one tap. The decisions change at once; the write goes to the queue.
    private func act(_ label: String, _ changes: [CullChange]) {
        history.append(HistoryEntry(
            actionID: newActionID(), label: label,
            before: changes.map { ($0.id, board.decisions[$0.id]) }, changes: changes,
            cursor: cursor, pass: pass))
        apply(changes)
        queue.enqueue(.decide(
            actionID: history[history.count - 1].actionID, day: day?.day ?? dayID, label: label,
            changes: changes))
    }

    private func apply(_ changes: [CullChange]) {
        edits += 1
        for c in changes {
            let stars = c.flag == .pick ? c.stars.flatMap { $0 > 0 ? $0 : nil } : nil
            board.decisions[c.id] = Decision(
                flag: c.flag, stars: stars, note: c.note ?? "", state: .draft, outcome: nil)
        }
    }

    /// `advance`: on to the first open stack after this one, or to the review, saving the
    /// position (and the day as finished when none is left).
    private func advance() {
        if let i = board.firstOpen(from: cursor + 1) {
            cursor = i
            screen = .cards
            saveProgress()
        } else {
            screen = .summary
            saveProgress(finished: true)
        }
    }

    /// Takes back the last tap. The decisions return at once; if the server refuses (the tap
    /// already reached Lightroom) they are put back and a toast says so.
    public func undo() {
        guard let entry = history.popLast() else {
            showToast("Nothing to undo")
            return
        }
        edits += 1
        for (id, decision) in entry.before { board.decisions[id] = decision }
        undone[entry.actionID] = entry
        queue.enqueue(.undo(actionID: entry.actionID))
        pass = entry.pass
        showToast("Undone: " + entry.label)
        signal(.undone)
        cursor = max(0, min(entry.cursor, board.stacks.count - 1))
        screen = .cards
        saveProgress()
    }

    /// A write the server refused. A refused undo means the tap is still in force, so its
    /// decisions go back (except on a frame decided again since); anything else is reported as
    /// the web app does.
    private func queueDropped(_ drop: CullWriteQueue.Drop) {
        if case .undo(let actionID) = drop.write, case .conflict(let message, _) = drop.error,
           let entry = undone.removeValue(forKey: actionID) {
            let restored = Dictionary(entry.before.map { ($0.id, $0.decision) }, uniquingKeysWith: { first, _ in first })
            apply(entry.changes.filter { board.decisions[$0.id] == restored[$0.id] ?? nil })
            showToast("Not undone: " + (message ?? "HTTP 409"))
        } else {
            showToast(drop.message)
        }
    }

    // MARK: Progress

    /// `saveProgress`: the position is saved 600 ms after the last move, or at once for the move
    /// that finishes the day. The save goes to the queue with the stack's `lead`.
    private func saveProgress(finished: Bool = false) {
        guard day != nil else { return }
        progressTask?.cancel()
        progressTask = nil
        let stack = currentStack
        let write = CullWrite.progress(
            day: day?.day ?? dayID, pass: pass, cursor: stack?.id ?? 0, finished: finished,
            lead: stack?.lead)
        if finished {
            queue.enqueue(write)
            return
        }
        let queue = self.queue, sleep = self.sleep
        progressTask = Task {
            do { try await sleep(Self.progressDelay) } catch { return }
            guard !Task.isCancelled else { return }
            queue.enqueue(write)
        }
    }

    // MARK: Send

    /// `sendDay`: waits up to 10 s for every tap to reach the server, then sends the day to
    /// Lightroom. Unsent decisions become `queued` here; `refresh()` brings the real receipts.
    public func send() async {
        guard let day, !isSending else { return }
        isSending = true
        defer { isSending = false }
        guard await queue.drain(timeout: Self.drainTimeout) else {
            showToast("Still offline: \(queue.pending) taps waiting to save. Send once they are in.")
            return
        }
        do {
            let result = try await client.send(day: day.day)
            for (id, d) in board.decisions where d.state == .draft || d.state == .missing {
                board.decisions[id] = Decision(
                    flag: d.flag, stars: d.stars, note: d.note, state: .queued, outcome: d.outcome)
            }
            showToast(
                result.queued > 0
                    ? "Queued \(result.queued) for Lightroom. On the Mac: Sync AI Cull Data."
                    : "Nothing new to send.")
        } catch {
            showToast("Not sent: " + CullFormat.errorText(error))
        }
    }

    // MARK: Toast and feedback

    private func showToast(_ text: String, offersUndo: Bool = false) {
        toastCount += 1
        toast = Toast(id: toastCount, text: text, offersUndo: offersUndo)
    }

    private func signal(_ kind: Feedback.Kind) {
        feedbackCount += 1
        feedback = Feedback(id: feedbackCount, kind: kind)
    }
}
