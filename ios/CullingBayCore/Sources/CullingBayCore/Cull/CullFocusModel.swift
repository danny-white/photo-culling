import Foundation
import Observation

extension Frame {
    /// `af` as a point: the autofocus point as fractions of the upright frame; nil if not recorded.
    public var afPoint: Point? {
        guard let af, af.count >= 2 else { return nil }
        return Point(x: af[0], y: af[1])
    }

    /// `spotOf`: where a 1:1 check starts, the autofocus point else the middle.
    public var focusSpot: Point { afPoint ?? Point(x: 0.5, y: 0.5) }
}

/// How one frame's page is zoomed and where it looks: the frame's size on screen at zoom 1 (its
/// fit size, in points), the zoom, and the point at the middle of the screen as fractions of
/// the upright frame. The page reports it when you step to another frame.
public struct CullZoomState: Sendable, Hashable {
    public var center: Point
    public var scale: Double
    public var fit: Size

    public init(center: Point, scale: Double, fit: Size) {
        self.center = center
        self.scale = scale
        self.fit = fit
    }
}

/// How a frame's page starts.
public enum CullFocusEntry: Sendable, Hashable {
    /// 1:1 with this point of the frame in the middle of the screen.
    case point(Point)
    /// Linked: the zoom the frame before had, kept in step by `TilePlanner.linkedZoom`.
    case carried(CullZoomState)
}

/// The 1:1 focus check: the port of `S.focus`, `openFocus`, `vFocus` and `closeFocus` in `app.js`,
/// and of the linked 1:1 compare of the burst picker (`linkedUrls`, `toggleLinked`).
///
/// It is on one frame, opened at the camera's AF point or where you tapped. Opened from the burst
/// picker it can step to the other frames of the burst, and with `linked` on, every frame is
/// shown at the same point and the same number of source pixels per point as the one before, so
/// a swipe flips frames with the crop held still. The pictures themselves are loaded by the
/// view; this holds what it needs to start each page.
@MainActor
@Observable
public final class CullFocusModel {
    /// Where the AF box sits, as fractions of the frame: `.af` in `app.css` is 9% of the frame's
    /// width, three to two, centred on the AF point.
    public static let afBoxWidth = 0.09
    public static let afBoxAspect = 1.5

    /// The frames that can be focused: the one frame of a card, or the whole burst from its picker.
    public let frames: [Frame]
    /// Where Close returns to: the cards or the picker.
    public let returnScreen: CullSessionModel.Screen
    public private(set) var index: Int
    /// How the current frame's page starts.
    public private(set) var entry: CullFocusEntry
    /// Whether stepping to another frame keeps the point and the zoom.
    public private(set) var linked: Bool
    @ObservationIgnored private let marks: [Int: FrameMark]
    @ObservationIgnored private var sourceSizes: [Int: Size] = [:]

    init(
        frames: [Frame], index: Int, point: Point, returnScreen: CullSessionModel.Screen, linked: Bool,
        marks: [Int: FrameMark]
    ) {
        self.frames = frames
        self.index = min(max(index, 0), max(frames.count - 1, 0))
        self.entry = .point(point)
        self.returnScreen = returnScreen
        self.linked = linked
        self.marks = marks
    }

    public var frame: Frame { frames[index] }
    /// Whether the burst's other frames can be reached from here.
    public var canStep: Bool { frames.count > 1 }

    // MARK: Words

    /// `Focus · DSC05040`.
    public var title: String { "Focus · " + CullFormat.stem(frame.file) }

    /// `At the camera’s AF point · drag to look around`, or `1:1 from the RAW · …`; `Linked · …`
    /// for a frame that took the zoom of the one before.
    public var subtitle: String {
        let what: String
        switch entry {
        case .carried: what = "Linked · same spot as the last frame"
        case .point(let p):
            let atAF = frame.afPoint.map { abs($0.x - p.x) < 1e-3 && abs($0.y - p.y) < 1e-3 } ?? false
            what = atAF ? "At the camera’s AF point" : "1:1 from the RAW"
        }
        return what + " · drag to look around"
    }

    /// `3/6`; empty for a single frame.
    public var counter: String { canStep ? "\(index + 1)/\(frames.count)" : "" }

    /// What this frame is marked as (`Kept ★★`, `Rejected`, `Picked in Lightroom`); nil for none.
    public var mark: FrameMark? { marks[frame.id] }

    // MARK: Stepping

    /// Turns linked zoom on or off.
    public func setLinked(_ on: Bool) { linked = on }

    /// `stripView` for the focus: moves `delta` frames, stopping at the ends. With `linked` the
    /// new frame starts where `state` (the page just left) was looking, scaled to keep its source
    /// pixels per point; without it, or with no `state` yet, it starts 1:1 at its own AF point.
    /// Returns whether it moved.
    @discardableResult
    public func step(_ delta: Int, from state: CullZoomState?) -> Bool {
        let target = min(max(index + delta, 0), frames.count - 1)
        guard delta != 0, target != index else { return false }
        index = target
        if linked {
            if let state { entry = .carried(state) }     // else the entry stays: the same point again
        } else {
            entry = .point(frame.focusSpot)
        }
        return true
    }

    // MARK: The page's start

    /// Where the current frame's page should look and how far it should zoom, given its size on
    /// screen at zoom 1 (`fit`, in points), its full-resolution size and the screen's scale.
    /// A page that is not linked needs the full-resolution size, so nil means it is not known
    /// yet. A linked page needs no more than `fit`, and gets `TilePlanner.linkedZoom`'s answer.
    public func start(fit: Size, source: Size?, screenScale: Double) -> (center: Point, scale: Double)? {
        guard fit.width > 0, fit.height > 0 else { return nil }
        switch entry {
        case .carried(let state):
            let linked = TilePlanner.linkedZoom(center: state.center, scale: state.scale, from: state.fit, to: fit)
            return (linked.center, linked.scale)
        case .point(let point):
            guard let source else { return nil }
            return (point, Self.oneToOneScale(source: source, fit: fit, screenScale: screenScale))
        }
    }

    /// The zoom at which one source pixel is one device pixel: the frame's longest side in
    /// pixels over its on-screen longest side in pixels. Never below 1.
    public static func oneToOneScale(source: Size, fit: Size, screenScale: Double) -> Double {
        let shown = max(fit.width, fit.height) * screenScale
        guard shown > 0 else { return 1 }
        return max(1, max(source.width, source.height) / shown)
    }

    // MARK: Full-resolution sizes

    /// The frame's full-resolution size, once a crop of it has said (`CropBox.sourceSize`).
    public func sourceSize(for id: Int) -> Size? { sourceSizes[id] }

    public func setSourceSize(_ size: Size, for id: Int) { sourceSizes[id] = size }

    // MARK: Taps

    /// `imagePoint`: where a tap at (`x`, `y`) falls on a picture drawn in `rect`, as fractions of
    /// the picture, kept inside it. The picture is the photo itself, not its box, so a letterboxed
    /// photo is measured by the rect it really covers.
    public static func imagePoint(x: Double, y: Double, in rect: Rect) -> Point {
        guard rect.width > 0, rect.height > 0 else { return Point(x: 0.5, y: 0.5) }
        return Point(
            x: min(1, max(0, (x - rect.x) / rect.width)),
            y: min(1, max(0, (y - rect.y) / rect.height)))
    }
}
