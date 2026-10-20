import Foundation

/// A badge on the card's photo.
public struct CullBadge: Sendable, Hashable {
    public enum Style: Sendable, Hashable {
        /// With a dot: `Looks like a panorama`, `Looks like a bracket`, `Sharpest`.
        case hint
        /// A measured hint from the server: `Blown`, `Dark`, `Softer`.
        case measured
        /// What you set in Lightroom: `Picked in Lightroom`, `★3 in Lightroom`.
        case lightroom
    }

    public let text: String
    public let style: Style
}

/// The chip on the card's photo.
public enum CullChip: Sendable, Hashable {
    /// A burst; opens the picker.
    case burst(count: Int)
    /// A RAW with its partners: `RAW + JPG`. Not a button.
    case partners(String)

    public var text: String {
        switch self {
        case .burst(let count): String(count)
        case .partners(let text): text
        }
    }
}

/// Which buttons show pressed on a decided card.
public struct CullPressed: Sendable, Hashable {
    public let reject: Bool
    public let keepAll: Bool
    /// Keep on a single card, which also shows pressed for a hero; Choose on a burst card.
    public let keep: Bool
}

/// One thumbnail of the strip under a burst card.
public struct CullStripItem: Sendable, Hashable, Identifiable {
    public let frame: Frame
    /// `.pick`, `.reject`, or `.clear` for no decision (the outline).
    public let mark: CullFlag

    public var id: Int { frame.id }
}

/// The soft limit of stacks to keep, as the bar on the card shows it (`budgetBar`).
public struct CullBudgetBar: Sendable, Hashable {
    public let kept: Int
    public let limit: Int
    /// `Kept 4 of 5`, or `Kept 7 · 2 over 5`.
    public let text: String
    /// Going over shows in amber.
    public var isOver: Bool { kept > limit }
    /// How full the bar is, 0 to 1.
    public let fraction: Double
    /// `10 stacks an hour of shooting (0.19 h)`.
    public let detail: String
}

/// Everything the Cull card shows for the stack the cursor is on, ported from `vCull`. The photo
/// itself is `frame`: load `CullingBayClient.imageURL(id:size:)` for it. Make a new one with
/// `CullSessionModel.card` whenever the model changes.
public struct CullCard: Sendable, Hashable {
    public let stack: Stack
    /// The frame the card shows: the kept one, else the lead.
    public let frame: Frame
    public let status: StackStatus
    /// A stack of more than one frame.
    public let isBurst: Bool
    /// A bracket or panorama that is still open: Keep all is suggested.
    public let suggestsKeepAll: Bool
    public let badges: [CullBadge]
    public let chip: CullChip?
    /// The line on the photo of a decided stack; nil while it is open.
    public let statusLine: CullStatusLine?
    /// The strip under a burst: its first six frames. Empty for a single.
    public let strip: [CullStripItem]
    /// Frames of the burst beyond the strip (`+3`); 0 for none.
    public let stripMore: Int
    public let pressed: CullPressed
    /// Stars lit on the star row of a single card (a burst has none).
    public let stars: Int
    /// `Keep all 7`; a burst only.
    public let keepAllLabel: String
    /// `DSC05040.ARW + DSC05040.JPG · 3/84`.
    public let fileLine: String
}

/// The end-of-day review, ported from `vSummary`.
public struct CullSummary: Sendable, Hashable {
    /// A frame of the day and what the Lightroom label under it says.
    public struct Won: Sendable, Hashable, Identifiable {
        public let frame: Frame
        /// `Picked in LR`, `Rejected in LR`, `★3 in LR`, or `Kept as you set it`.
        public let label: String

        public var id: Int { frame.id }
    }

    /// Frames kept (not hero), hero (5 stars), rejected, and not decided (a frame in a stack
    /// you had already culled in Lightroom is not counted).
    public let kept: Int
    public let hero: Int
    public let rejected: Int
    public let unflagged: Int
    /// `Day finished`, or `Rejects so far` while stacks are open.
    public let subtitle: String
    /// The day's own summary, lines separated by `\n`.
    public let daySummary: String?

    /// Decisions by where they have got to. Missing ones go again with the next Send.
    public let unsent: Int
    public let missing: Int
    public let queued: Int
    public let landed: Int
    public let conflicts: Int
    /// `12 in Lightroom`, `3 waiting for the next Sync AI Cull Data`, `1 not found in the last
    /// sync, will go again`, `2 stacks were already flagged or rated in Lightroom and skipped`.
    public let lightroomLines: [String]

    /// "Your Lightroom flag won": frames whose decision lost to your own flag in Lightroom.
    public let won: [Won]
    /// `The phone said otherwise, but you had flagged these in Lightroom yourself, so …`; nil
    /// when `won` is empty.
    public let wonNote: String?

    /// Rejected frames (not those Lightroom overruled) that were rejected with a burst note:
    /// "From bursts · similar frame kept".
    public let rejectsFromBursts: [Frame]
    /// The other rejects: "Rejected outright".
    public let rejectsOutright: [Frame]

    /// How many stacks are kept beyond the budget; 0 when within it or without one.
    public let overBudget: Int
    /// `Kept · 7 of 5` over the stacks to trim; nil unless over budget.
    public let budgetHeading: String?
    /// `2 over this shoot’s budget of 5 (10 stacks an hour of shooting).` when over, else
    /// `Kept 4 of this shoot’s budget of 5.`; nil without a budget.
    public let budgetNote: String?
    /// `Tap a stack to drop it.`, which follows the over-budget note once the view can drop one.
    public let budgetDropHint: String?

    /// `Send 3 to Lightroom`, `Waiting for Lightroom`, `In Lightroom` or `Send to Lightroom`.
    public let sendLabel: String
    /// Whether there is anything to send. The button is also off while a send is running.
    public let canSend: Bool
}
