import Foundation

/// Where a stack stands: the model of `status` in `app.js`.
public struct StackStatus: Sendable, Hashable {
    /// The `v` of app.js, also the name of the stack's outline.
    public enum Verdict: String, Sendable, Hashable {
        case keep, hero, reject
    }

    public enum Source: Sendable, Hashable {
        /// Decided on the phone.
        case phone
        /// Flagged or rated by hand in Lightroom.
        case lightroom
    }

    /// Nil while the stack is open.
    public let verdict: Verdict?
    public let source: Source?
    /// For a stack kept in Lightroom: the frame that was picked, else the first rated one.
    public let frame: Frame?

    public var isDone: Bool { verdict != nil }

    static let open = StackStatus(verdict: nil, source: nil, frame: nil)
}

/// One frame's mark: the phone's decision, else your Lightroom flag or stars (`frameMark`).
public struct FrameMark: Sendable, Hashable {
    public let verdict: StackStatus.Verdict
    /// `Rejected`, `Hero`, `Kept`, `Rejected in Lightroom`, `Picked in Lightroom` or `Rated in Lightroom`.
    public let text: String
    public let stars: Int
}

/// What you set by hand in Lightroom (`lrMark`).
enum LightroomMark: Sendable, Hashable {
    case pick, reject, rated
}

/// The stacks of one day and the phone's decisions on their frames, with the rules that turn
/// them into what the cards say. Value type and pure: the model in `app.js` is `S.stacks` and
/// `S.dec` plus these functions.
struct CullBoard: Sendable {
    var stacks: [Stack] = []
    var decisions: [Int: Decision] = [:]
    /// The day's budget of stacks to keep; 0 when there is none.
    var budget = 0

    private var framesByID: [Int: Frame] = [:]

    init() {}

    init(stacks: [Stack], decisions: [Int: Decision], budget: Int) {
        self.stacks = stacks
        self.decisions = decisions
        self.budget = budget
        for stack in stacks {
            for frame in stack.frames { framesByID[frame.id] = frame }
        }
    }

    func frame(id: Int) -> Frame? { framesByID[id] }

    // MARK: Per frame and stack

    static func isPick(_ decision: Decision?) -> Bool { decision?.flag == .pick }

    func leadOf(_ stack: Stack) -> Frame {
        stack.frames.first { $0.id == stack.lead } ?? stack.frames[0]
    }

    /// The frame a card shows: the kept one, else the lead.
    func shown(_ stack: Stack) -> Frame {
        if stack.frames.count == 1 { return stack.frames[0] }
        return stack.frames.first { Self.isPick(decisions[$0.id]) } ?? leadOf(stack)
    }

    /// A flag you set in Lightroom by hand (reported back by the plug-in's catalog file). Flags
    /// the plug-in set from the phone come back as by `.phone` and are already in `decisions`.
    /// A reject flag rejects; a pick flag, or a star rating without a reject, means you have
    /// already been through the photo there.
    func lrMark(_ frame: Frame) -> LightroomMark? {
        guard let lr = frame.lr else { return nil }
        if lr.by == .you && lr.pick == -1 { return .reject }
        if lr.by == .you && lr.pick == 1 { return .pick }
        if lr.starsBy == .you && lr.rating > 0 { return .rated }
        return nil
    }

    func lrWord(_ frame: Frame) -> String? {
        switch lrMark(frame) {
        case .pick: "Picked in Lightroom"
        case .reject: "Rejected in Lightroom"
        case .rated: "★\(frame.lr?.rating ?? 0) in Lightroom"
        case nil: nil
        }
    }

    func lrShort(_ frame: Frame) -> String {
        switch lrMark(frame) {
        case .pick: "Picked in LR"
        case .reject: "Rejected in LR"
        case .rated: "★\(frame.lr?.rating ?? 0) in LR"
        case nil: "Kept as you set it"
        }
    }

    func status(_ stack: Stack) -> StackStatus {
        let ds = stack.frames.map { decisions[$0.id] }
        if ds.contains(where: Self.isPick) {
            let hero = ds.contains { Self.isPick($0) && $0?.stars == 5 }
            return StackStatus(verdict: hero ? .hero : .keep, source: .phone, frame: nil)
        }
        if ds.allSatisfy({ $0?.flag == .reject }) {
            return StackStatus(verdict: .reject, source: .phone, frame: nil)
        }
        let marks = stack.frames.map(lrMark)
        if marks.contains(.pick) || marks.contains(.rated) {
            let frame = stack.frames.first { lrMark($0) == .pick }
                ?? stack.frames.first { lrMark($0) == .rated }
            return StackStatus(verdict: .keep, source: .lightroom, frame: frame)
        }
        if marks.allSatisfy({ $0 == .reject }) {
            return StackStatus(verdict: .reject, source: .lightroom, frame: nil)
        }
        return .open
    }

    /// One frame's decision for the marks on a photo.
    func frameMark(_ frame: Frame) -> FrameMark? {
        let d = decisions[frame.id]
        let lrStars = frame.lr?.rating ?? 0
        if d?.flag == .reject { return FrameMark(verdict: .reject, text: "Rejected", stars: 0) }
        if let d, d.flag == .pick {
            let hero = d.stars == 5
            let stars = (d.stars ?? 0) > 0 ? d.stars ?? 0 : lrStars
            return FrameMark(verdict: hero ? .hero : .keep, text: hero ? "Hero" : "Kept", stars: stars)
        }
        switch lrMark(frame) {
        case .reject: return FrameMark(verdict: .reject, text: "Rejected in Lightroom", stars: 0)
        case .pick: return FrameMark(verdict: .keep, text: "Picked in Lightroom", stars: lrStars)
        case .rated: return FrameMark(verdict: .keep, text: "Rated in Lightroom", stars: lrStars)
        case nil: return nil
        }
    }

    /// The decision's flag for the strip under a burst card, `.clear` for none (`markOf`).
    func markOf(_ frame: Frame) -> CullFlag { decisions[frame.id]?.flag ?? .clear }

    // MARK: Whole day

    /// The first stack that is not done, looking from `from` and wrapping round; nil when all are.
    func firstOpen(from: Int = 0) -> Int? {
        let n = stacks.count
        for k in 0..<n {
            let i = (from + k) % n
            if !status(stacks[i]).isDone { return i }
        }
        return nil
    }

    var doneCount: Int { stacks.filter { status($0).isDone }.count }

    /// Stacks you had already flagged or rated in Lightroom.
    var lrDone: Int { stacks.filter { status($0).source == .lightroom }.count }

    /// Stacks kept, Lightroom's included (they count towards the budget).
    var keptCount: Int {
        stacks.filter { let st = status($0); return st.isDone && st.verdict != .reject }.count
    }

    // MARK: Lightroom clashes and the budget

    /// How many of these changes disagree with a flag you set in Lightroom (that flag will
    /// win). Only flags clash: Lightroom keeps a flag you set by hand.
    func lrClashes(_ changes: [CullChange]) -> Int {
        changes.filter { c in
            guard let frame = frame(id: c.id) else { return false }
            let mark = lrMark(frame)
            return (mark == .pick && c.flag != .clear && c.flag != .pick)
                || (mark == .reject && c.flag != .clear && c.flag != .reject)
        }.count
    }

    /// A reject lands on a photo you rated in Lightroom; the stars stay.
    func lrRatedRejects(_ changes: [CullChange]) -> Int {
        changes.filter { c in
            c.flag == .reject && frame(id: c.id).flatMap(lrMark) == .rated
        }.count
    }

    static func clashNote(_ clashes: Int, _ rated: Int) -> String {
        (clashes > 0
            ? " · Lightroom keeps your own flag on " + (clashes > 1 ? "\(clashes) of them" : "it") : "")
            + (rated > 0 ? " · " + (rated > 1 ? "\(rated) had" : "it had") + " your stars in Lightroom" : "")
    }

    /// `overNote`: how far over the budget the kept stacks are, as a tail for a toast.
    var overNote: String {
        let over = keptCount - budget
        return budget > 0 && over > 0 ? " · \(over) over this shoot’s \(budget)" : ""
    }

    // MARK: Status line

    /// What a decided stack shows when you come back to it (`stLine`).
    func statusLine(_ stack: Stack) -> CullStatusLine? {
        let st = status(stack)
        guard let verdict = st.verdict else { return nil }
        let n = stack.frames.count
        let f = shown(stack)
        var text: String
        var stars = 0
        if st.source == .lightroom {
            let mark = frameMark(st.frame ?? f) ?? FrameMark(verdict: .reject, text: "Rejected in Lightroom", stars: 0)
            text = verdict == .reject && n > 1 ? "Rejected in Lightroom · all \(n) frames" : mark.text
            stars = mark.stars
        } else if verdict == .reject {
            text = n > 1 ? "Rejected · all \(n) frames" : "Rejected"
        } else {
            let k = stack.frames.filter { Self.isPick(decisions[$0.id]) }.count
            if n == 1 {
                text = verdict == .hero ? "Hero" : "Kept"
            } else if k == n {
                text = "Kept all \(n)"
                    + (stack.kind == .bracket ? " · bracket" : stack.kind == .pano ? " · panorama" : "")
            } else if k > 1 {
                text = "Kept \(k) of \(n) · \(n - k) rejected"
            } else {
                text = "Kept \(CullFormat.stem(f.file)) · \(n - 1) other" + (n > 2 ? "s" : "") + " rejected"
            }
            stars = frameMark(f)?.stars ?? 0
        }
        if stack.frames.contains(where: { decisions[$0.id]?.state == .conflict }) {
            text += " · your Lightroom flag won"
        }
        return CullStatusLine(text: text, verdict: verdict, stars: stars)
    }
}

/// The line on a decided card's photo.
public struct CullStatusLine: Sendable, Hashable {
    public let text: String
    /// Colours the line: a reject is red, the rest green.
    public let verdict: StackStatus.Verdict
    /// Stars to show beside the text; 0 for none.
    public let stars: Int
}
