import Foundation
import Observation

/// One frame of a burst in the picker, with what the screens draw on and around it.
public struct CullPickerFrame: Sendable, Hashable, Identifiable {
    public let frame: Frame
    /// Position in the burst, in shooting order.
    public let index: Int
    /// The dot under the thumbnail: the stack's lead, the sharpest frame.
    public let isSharpest: Bool
    /// The badges on the big frame of the strip: `Sharpest`, the measured hint, and a Lightroom
    /// flag the flag below doesn't already say.
    public let badges: [CullBadge]
    /// The phone's decision on the frame, else your Lightroom flag or stars; nil for none.
    public let mark: FrameMark?

    public var id: Int { frame.id }
}

/// The burst picker: the port of `S.picker`, `openPicker`, `vStrip` and the picker's part of
/// the click switch in `app.js`.
///
/// Every burst opens as a filmstrip: a big frame to swipe through, a strip of thumbnails that
/// scrolls through the whole burst (tap one to show it), a tick on each frame to keep, and
/// stars. The web app shows bursts over six as a knock-out grid; Danny found the grid's small
/// tiles hard to judge on the phone (2026-11-23), so the app uses the strip for any size. The
/// picker decides nothing itself; `CullSessionModel.keepPicked()` saves `keeps` and
/// `keepRates` as one tap.
@MainActor
@Observable
public final class CullPickerModel {
    public let stack: Stack
    public let frames: [CullPickerFrame]

    /// The frame on the big picture of the strip.
    public private(set) var viewIndex: Int
    /// The ticked frames, by `Frame.id`.
    public private(set) var selected: Set<Int>
    /// The stars given to frames, by `Frame.id`.
    public private(set) var rates: [Int: Int]
    /// Whether focus, opened from here, keeps the point and the zoom from frame to frame. It
    /// stays as you left it for the next time focus opens.
    public var linkedFocus = false

    /// `openPicker`. A card's Choose and a swipe up open on the sharpest frame (`fromStart`;
    /// the strip below shows the rest of the burst); the strip under the card opens on the frame
    /// the card shows. Coming back to a decided burst, the strip starts with its kept frames
    /// ticked, and their stars.
    init(stack: Stack, board: CullBoard, fromStart: Bool) {
        self.stack = stack
        let picked = stack.frames.filter { CullBoard.isPick(board.decisions[$0.id]) }
        frames = stack.frames.enumerated().map { index, frame in
            var badges: [CullBadge] = []
            if frame.id == stack.lead { badges.append(CullBadge(text: "Sharpest", style: .hint)) }
            badges += frame.badges.map { CullBadge(text: $0, style: .measured) }
            let mark = board.frameMark(frame)
            if let word = board.lrWord(frame), !(mark?.text.hasSuffix("in Lightroom") ?? false) {
                badges.append(CullBadge(text: word, style: .lightroom))
            }
            return CullPickerFrame(
                frame: frame, index: index, isSharpest: frame.id == stack.lead, badges: badges, mark: mark)
        }
        selected = Set(picked.map(\.id))
        // The star row shows the stars a kept frame has, so they are what a keep saves.
        rates = Dictionary(uniqueKeysWithValues: picked.compactMap { frame in
            board.decisions[frame.id]?.stars.flatMap { $0 > 0 ? (frame.id, $0) : nil }
        })
        let opening = fromStart ? stack.lead : board.shown(stack).id
        viewIndex = stack.frames.firstIndex { $0.id == opening } ?? 0
    }

    // MARK: Strip

    public var viewed: CullPickerFrame { frames[viewIndex] }

    /// `stripView`: shows frame `index`, stopping at the ends.
    public func show(_ index: Int) {
        viewIndex = min(max(index, 0), frames.count - 1)
    }

    /// A swipe: the next frame (`1`) or the one before (`-1`).
    public func step(_ delta: Int) { show(viewIndex + delta) }

    /// `tick`: keeps or drops the frame on the big picture.
    public func tick() {
        let id = viewed.id
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// The star row: rates the frame on the big picture, and ticks it.
    public func rate(stars: Int) {
        guard (1...5).contains(stars) else { return }
        rates[viewed.id] = stars
        selected.insert(viewed.id)
    }

    public func isTicked(_ id: Int) -> Bool { selected.contains(id) }

    /// Stars lit on the star row for the frame on the big picture.
    public var viewedStars: Int { rates[viewed.id] ?? 0 }

    // MARK: Keeping

    /// The frames a keep saves as picks, in shooting order: the ticked ones.
    public var keeps: [Frame] { stack.frames.filter { selected.contains($0.id) } }

    /// Their stars.
    public var keepRates: [Int: Int] { rates }

    /// A keep with nothing to keep is refused.
    public var canKeep: Bool { !keeps.isEmpty }

    // MARK: Words

    /// `Burst of 5`.
    public var title: String { "Burst of \(frames.count)" }

    /// `Tick the keepers`.
    public var subtitle: String { "Tick the keepers" }

    /// `Keep 2 · reject 3`, or `Tick a keeper`.
    public var keepLabel: String {
        let n = keeps.count
        return n > 0 ? "Keep \(n) · reject \(frames.count - n)" : "Tick a keeper"
    }

    /// `Reject all 5`.
    public var rejectAllLabel: String { "Reject all \(frames.count)" }

    /// The line under the pictures.
    public var note: String {
        "A dot marks the sharpest frame. Swipe or tap the strip to look, double-tap to check its focus at 1:1, ✓ or a star to keep."
    }
}
