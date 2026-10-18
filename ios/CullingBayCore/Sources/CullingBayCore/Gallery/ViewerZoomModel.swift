import Foundation
import Observation

/// Viewer geometry in points. The image is centred in the viewport; offset is from that centre.
@MainActor
@Observable
public final class ViewerZoomModel {
    public private(set) var viewport = Size(width: 1, height: 1)
    public private(set) var imageSize = Size(width: 1, height: 1)
    public private(set) var sourceSize: Size?
    public private(set) var scale = 1.0
    public private(set) var offset = Point(x: 0, y: 0)
    public var showsInfo = true
    @ObservationIgnored private var pinchStart: (scale: Double, offset: Point)?
    @ObservationIgnored private var panStart: Point?
    @ObservationIgnored private var draggedWhileZoomed = false

    public init() {}
    public var isZoomed: Bool { scale > 1.01 }
    public var fitSize: Size {
        let factor = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        return Size(width: imageSize.width * factor, height: imageSize.height * factor)
    }
    public var visible: Rect {
        let fit = fitSize
        let w = fit.width * scale, h = fit.height * scale
        let left = max(0, (w / 2 - viewport.width / 2 - offset.x) / w)
        let top = max(0, (h / 2 - viewport.height / 2 - offset.y) / h)
        let right = min(1, (w / 2 + viewport.width / 2 - offset.x) / w)
        let bottom = min(1, (h / 2 + viewport.height / 2 - offset.y) / h)
        return Rect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }
    public func plan(screenScale: Double) -> TilePlan {
        TilePlanner.plan(sourceSize: sourceSize ?? Size(width: 0, height: 0), fitSize: fitSize,
                         zoomScale: scale, screenScale: screenScale, visible: visible)
    }
    public func resize(_ size: Size) {
        guard size.width > 0, size.height > 0, size != viewport else { return }
        viewport = size
        reset()
    }
    public func setImageSize(_ size: Size) {
        guard size.width > 0, size.height > 0 else { return }
        imageSize = size
        clampPan()
    }
    public func setSourceSize(_ size: Size) { sourceSize = size }
    public func reset() {
        scale = 1; offset = Point(x: 0, y: 0)
        pinchStart = nil; panStart = nil; draggedWhileZoomed = false
    }
    /// Anchor is in viewport points. Keep the point beneath the fingers stationary.
    public func pinch(_ magnification: Double, anchor: Point) {
        guard magnification.isFinite, magnification > 0 else { return }
        if pinchStart == nil { pinchStart = (scale, offset) }
        guard let start = pinchStart else { return }
        zoom(to: start.scale * magnification, anchor: anchor, from: start)
        draggedWhileZoomed = true
    }
    /// A pinch also taints the drag it ends with, so lifting the second finger at fit size
    /// does not turn a page. `beginDrag()` clears that for the next drag.
    public func endPinch() {
        pinchStart = nil
        if scale < 1.05 { reset() }
        draggedWhileZoomed = true
    }
    /// Call when a one-finger drag starts, so an earlier pinch cannot swallow its swipe.
    public func beginDrag() {
        guard pinchStart == nil else { return }
        draggedWhileZoomed = false
    }
    public func doubleTap(at point: Point) {
        if isZoomed { reset() }
        else { zoom(to: 2.5, anchor: point, from: (scale, offset)) }
    }
    public func pan(_ translation: Point) {
        guard pinchStart == nil, isZoomed else { return }
        if panStart == nil { panStart = offset }
        draggedWhileZoomed = true
        guard let start = panStart else { return }
        offset = Point(x: start.x + translation.x, y: start.y + translation.y)
        clampPan()
    }
    /// A horizontal swipe pages only if the entire drag happened at fit size.
    public func endPan(_ translation: Point) -> Int {
        defer { panStart = nil; draggedWhileZoomed = false }
        guard !isZoomed, pinchStart == nil, !draggedWhileZoomed,
              abs(translation.x) > 60, abs(translation.x) > abs(translation.y) else { return 0 }
        return translation.x < 0 ? 1 : -1
    }
    private func zoom(to proposed: Double, anchor: Point, from start: (scale: Double, offset: Point)) {
        scale = min(16, max(1, proposed))
        let ratio = scale / start.scale
        let x = anchor.x - viewport.width / 2, y = anchor.y - viewport.height / 2
        offset = Point(x: x - (x - start.offset.x) * ratio, y: y - (y - start.offset.y) * ratio)
        clampPan()
    }
    private func clampPan() {
        let fit = fitSize
        let x = max(0, (fit.width * scale - viewport.width) / 2)
        let y = max(0, (fit.height * scale - viewport.height) / 2)
        offset = Point(x: min(x, max(-x, offset.x)), y: min(y, max(-y, offset.y)))
    }
}
