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

/// The burst picker: the port of `S.picker`, `openPicker`, `vStrip`, `vKnock` and the picker's
/// part of the click switch in `app.js`.
///
/// A burst of up to six frames opens as a filmstrip: a big frame to swipe through, a tick on each
/// frame to keep, and stars. A bigger one opens as a knock-out grid: every frame at once, tap the
/// weak ones out, keep what is left. The picker decides nothing itself; `CullSessionModel.keepPicked()`
/// saves `keeps` and `keepRates` as one tap.
@MainActor
@Observable
public final class CullPickerModel {
    /// `PICKER_STRIP_MAX`: bursts up to this size open as a filmstrip.
    public static let stripMax = 6
    /// Two taps on a knock-out tile this close together are a double-tap.
    public static let doubleTapWindow: Duration = .milliseconds(300)

    public enum Mode: Sendable, Hashable {
        case strip
        case knockOut
    }

    /// What a tap on a knock-out tile did.
    public enum KnockTap: Sendable, Hashable {
        /// The frame went out or came back.
        case toggled
        /// A double-tap: the first tap's toggle was taken back, and the view should open focus.
        case focus
    }

    public let stack: Stack
    public let mode: Mode
    public let frames: [CullPickerFrame]

    /// The frame on the big picture of the strip.
    public private(set) var viewIndex: Int
    /// The ticked frames (strip), by `Frame.id`.
    public private(set) var selected: Set<Int>
    /// The stars given to frames (strip), by `Frame.id`.
    public private(set) var rates: [Int: Int]
    /// The frames tapped out (knock-out), by `Frame.id`.
    public private(set) var knockedOut: Set<Int>
    /// Whether focus, opened from here, keeps the point and the zoom from frame to frame. It
    /// stays as you left it for the next time focus opens.
    public var linkedFocus = false

    @ObservationIgnored private var lastKnock: (index: Int, at: ContinuousClock.Instant)?

    /// `openPicker`. A card's Choose and a swipe up open on the first frame (`fromStart`: you see
    /// every frame before keeping one); the strip under the card opens on the frame the card
    /// shows. Coming back to a decided burst, the strip starts with its kept frames ticked (and
    /// their stars), and the knock-out starts with the frames that weren't kept out.
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
        if stack.frames.count <= Self.stripMax {
            mode = .strip
            selected = Set(picked.map(\.id))
            // The star row shows the stars a kept frame has, so they are what a keep saves.
            rates = Dictionary(uniqueKeysWithValues: picked.compactMap { frame in
                board.decisions[frame.id]?.stars.flatMap { $0 > 0 ? (frame.id, $0) : nil }
            })
            knockedOut = []
            viewIndex = fromStart ? 0 : stack.frames.firstIndex { $0.id == board.shown(stack).id } ?? 0
        } else {
            mode = .knockOut
            selected = []
            rates = [:]
            knockedOut = picked.isEmpty
                ? [] : Set(stack.frames.filter { !CullBoard.isPick(board.decisions[$0.id]) }.map(\.id))
            viewIndex = 0
        }
    }

    // MARK: Strip

    public var viewed: CullPickerFrame { frames[viewIndex] }

    /// `stripView`: shows frame `index`, stopping at the ends.
    public func show(_ index: Int) {
        guard mode == .strip else { return }
        viewIndex = min(max(index, 0), frames.count - 1)
    }

    /// A swipe: the next frame (`1`) or the one before (`-1`).
    public func step(_ delta: Int) { show(viewIndex + delta) }

    /// `tick`: keeps or drops the frame on the big picture.
    public func tick() {
        guard mode == .strip else { return }
        let id = viewed.id
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// The star row: rates the frame on the big picture, and ticks it.
    public func rate(stars: Int) {
        guard mode == .strip, (1...5).contains(stars) else { return }
        rates[viewed.id] = stars
        selected.insert(viewed.id)
    }

    public func isTicked(_ id: Int) -> Bool { selected.contains(id) }

    /// Stars lit on the star row for the frame on the big picture.
    public var viewedStars: Int { rates[viewed.id] ?? 0 }

    // MARK: Knock-out

    public func isOut(_ id: Int) -> Bool { knockedOut.contains(id) }

    /// Taps a frame out, or back in.
    public func toggleOut(_ id: Int) {
        guard mode == .knockOut else { return }
        if knockedOut.contains(id) { knockedOut.remove(id) } else { knockedOut.insert(id) }
    }

    /// `knockTap`. Every tap toggles at once, so the grid answers without waiting to see whether
    /// a second tap follows; a second tap on the same tile within `doubleTapWindow` takes the
    /// first one's toggle back, and the view opens focus on it.
    public func tapKnockOut(_ index: Int, at now: ContinuousClock.Instant) -> KnockTap {
        guard mode == .knockOut, frames.indices.contains(index) else { return .toggled }
        let id = frames[index].id
        if let last = lastKnock, last.index == index, now - last.at < Self.doubleTapWindow {
            lastKnock = nil
            toggleOut(id)
            return .focus
        }
        lastKnock = (index, now)
        toggleOut(id)
        return .toggled
    }

    // MARK: Keeping

    /// The frames a keep saves as picks, in shooting order: the ticked ones, or every frame not
    /// knocked out.
    public var keeps: [Frame] {
        switch mode {
        case .strip: stack.frames.filter { selected.contains($0.id) }
        case .knockOut: stack.frames.filter { !knockedOut.contains($0.id) }
        }
    }

    /// Their stars. The knock-out has none.
    public var keepRates: [Int: Int] { mode == .strip ? rates : [:] }

    /// A keep with nothing to keep is refused.
    public var canKeep: Bool { !keeps.isEmpty }

    // MARK: Words

    /// `Burst of 5`.
    public var title: String { "Burst of \(frames.count)" }

    /// `Tick the keepers`, or `4 left · tap the weaker frames out`.
    public var subtitle: String {
        mode == .strip ? "Tick the keepers" : "\(keeps.count) left · tap the weaker frames out"
    }

    /// `Keep 2 · reject 3`, `Tick a keeper`, or `Keep the 6 left`.
    public var keepLabel: String {
        switch mode {
        case .strip:
            let n = keeps.count
            return n > 0 ? "Keep \(n) · reject \(frames.count - n)" : "Tick a keeper"
        case .knockOut:
            return "Keep the \(keeps.count) left"
        }
    }

    /// `Reject all 5`.
    public var rejectAllLabel: String { "Reject all \(frames.count)" }

    /// The line under the pictures.
    public var note: String {
        mode == .strip
            ? "A dot marks the sharpest frame. Swipe to look, double-tap to check its focus at 1:1, ✓ or a star to keep."
            : "The dot marks the sharpest. Tap again to bring a frame back; double-tap to check its focus."
    }
}
