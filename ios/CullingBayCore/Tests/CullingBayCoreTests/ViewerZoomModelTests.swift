import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Viewer zoom model")
struct ViewerZoomModelTests {
    /// A 400 x 800 point screen showing a 3:2 landscape picture: it fits 400 x 266.67.
    private func makeModel() -> ViewerZoomModel {
        let model = ViewerZoomModel()
        model.resize(Size(width: 400, height: 800))
        model.setImageSize(Size(width: 1500, height: 1000))
        model.setSourceSize(Size(width: 6000, height: 4000))
        return model
    }

    private let centre = Point(x: 200, y: 400)

    @Test func startsFitAndWhole() {
        let model = makeModel()
        #expect(!model.isZoomed)
        #expect(model.fitSize.width == 400)
        #expect(abs(model.fitSize.height - 266.6667) < 0.001)
        #expect(model.visible == Rect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func pinchingAtTheCentreKeepsTheCentre() {
        let model = makeModel()
        model.pinch(2, anchor: centre)
        #expect(model.scale == 2)
        #expect(model.offset == Point(x: 0, y: 0))
        #expect(abs(model.visible.width - 0.5) < 1e-9)
        #expect(abs(model.visible.midX - 0.5) < 1e-9)
    }

    @Test func pinchingAtAnEdgeKeepsThePointUnderTheFingers() {
        let model = makeModel()
        // The left edge of the picture is under the finger and stays there.
        model.pinch(2, anchor: Point(x: 0, y: 400))
        #expect(abs(model.visible.x) < 1e-9)
        #expect(abs(model.visible.width - 0.5) < 1e-9)
    }

    @Test func zoomIsCappedAt16AndFloorsAtOne() {
        let model = makeModel()
        model.pinch(100, anchor: centre)
        #expect(model.scale == 16)
        model.endPinch()
        model.pinch(0.01, anchor: centre)
        #expect(model.scale == 1)
    }

    @Test func nonsenseMagnificationIsIgnored() {
        let model = makeModel()
        model.pinch(.nan, anchor: centre)
        model.pinch(0, anchor: centre)
        model.pinch(-1, anchor: centre)
        #expect(model.scale == 1)
    }

    @Test func endingAPinchNearOneSnapsBackToFit() {
        let model = makeModel()
        model.pinch(1.03, anchor: centre)
        model.endPinch()
        #expect(model.scale == 1 && model.offset == Point(x: 0, y: 0))
    }

    @Test func doubleTapZoomsInThenOut() {
        let model = makeModel()
        model.doubleTap(at: centre)
        #expect(model.scale == 2.5)
        model.doubleTap(at: centre)
        #expect(model.scale == 1)
    }

    @Test func panningIsClampedToThePicture() {
        let model = makeModel()
        model.pinch(2, anchor: centre)
        model.endPinch()
        model.pan(Point(x: 5000, y: 5000))
        // Zoomed width 800 on a 400 wide screen: 200 points of travel either way.
        #expect(model.offset.x == 200)
        #expect(model.visible.x == 0)
        // The zoomed picture is 533 tall on an 800 tall screen, so it cannot move up or down.
        #expect(model.offset.y == 0)
        _ = model.endPan(Point(x: 5000, y: 5000))
        model.pan(Point(x: -5000, y: 0))
        #expect(model.offset.x == -200)
        #expect(abs(model.visible.x + model.visible.width - 1) < 1e-9)
    }

    @Test func panWhileFitDoesNotMove() {
        let model = makeModel()
        model.pan(Point(x: 30, y: 30))
        #expect(model.offset == Point(x: 0, y: 0))
    }

    @Test func aSwipeAtFitSizePagesByDirection() {
        let model = makeModel()
        #expect(model.endPan(Point(x: -120, y: 10)) == 1)
        #expect(model.endPan(Point(x: 120, y: 10)) == -1)
        #expect(model.endPan(Point(x: 30, y: 0)) == 0)
        #expect(model.endPan(Point(x: 100, y: 200)) == 0)
    }

    @Test func aSwipeWhileZoomedNeverPages() {
        let model = makeModel()
        model.pinch(2, anchor: centre)
        model.endPinch()
        #expect(model.endPan(Point(x: -300, y: 0)) == 0)
    }

    @Test func aSwipeAfterZoomingInAndBackOutOfOneGestureNeverPages() {
        let model = makeModel()
        model.pinch(2, anchor: centre)
        model.pinch(1, anchor: centre)
        model.endPinch()
        #expect(!model.isZoomed)
        #expect(model.endPan(Point(x: -300, y: 0)) == 0)
        // The next gesture is a fresh one.
        #expect(model.endPan(Point(x: -300, y: 0)) == 1)
    }

    @Test func aNewDragAfterAPinchCanPage() {
        let model = makeModel()
        model.pinch(2, anchor: centre)
        model.pinch(1, anchor: centre)
        model.endPinch()
        model.beginDrag()
        #expect(model.endPan(Point(x: -300, y: 0)) == 1)
    }

    @Test func resizingResetsTheZoom() {
        let model = makeModel()
        model.pinch(3, anchor: centre)
        model.resize(Size(width: 800, height: 400))
        #expect(model.scale == 1)
        #expect(model.viewport == Size(width: 800, height: 400))
    }

    @Test func theTilePlanFollowsTheZoom() {
        let model = makeModel()
        model.setSourceSize(Size(width: 6000, height: 4000))
        #expect(model.plan(screenScale: 3).level == .view)
        model.pinch(8, anchor: centre)
        model.endPinch()
        let plan = model.plan(screenScale: 3)
        #expect(!plan.tiles.isEmpty)
        // The centre of the picture is what is shown, so a centre tile comes first.
        let first = plan.tiles[0].normalizedRect
        #expect(first.x <= 0.5 && first.x + first.width >= 0.5)
    }

    @Test func zeroSizesAreIgnored() {
        let model = makeModel()
        model.resize(Size(width: 0, height: 100))
        model.setImageSize(Size(width: 10, height: 0))
        #expect(model.viewport == Size(width: 400, height: 800))
        #expect(model.imageSize == Size(width: 1500, height: 1000))
    }
}
