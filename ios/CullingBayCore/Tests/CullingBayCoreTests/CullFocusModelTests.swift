import Foundation
import Testing
@testable import CullingBayCore

/// The 1:1 focus check and linked zoom: `openFocus`, `vFocus`, `closeFocus`, `imagePoint`,
/// `spotOf`, and the burst picker's linked 1:1 compare.
@MainActor
@Suite("Cull: focus and linked zoom")
struct CullFocusModelTests {
    /// A burst of `count` frames (ids 101...) with AF points, a single to move on to.
    private func day(_ count: Int = 4, af: [Int: [Double]]? = nil, decisions: [Int: Decision] = [:]) -> CullDay {
        let points = af ?? Dictionary(uniqueKeysWithValues: (1...count).map { (100 + $0, [0.1 * Double($0), 0.5]) })
        let frames = (1...count).map { i in
            cullFrame(100 + i, file: "B\(100 + i).ARW", decision: decisions[100 + i], af: points[100 + i])
        }
        return cullDay([
            cullStack(0, .burst, frames),
            cullStack(1, .single, [cullFrame(900, file: "S900.ARW")]),
        ])
    }

    private func open(_ day: CullDay) async -> (CullSessionModel, CullRig) {
        let rig = CullRig(day: day)
        let model = rig.session()
        await model.load()
        return (model, rig)
    }

    private func focus(_ model: CullSessionModel) throws -> CullFocusModel {
        try #require(model.focus)
    }

    private let fit = Size(width: 390, height: 260)
    private let source = Size(width: 7952, height: 5304)

    // MARK: Opening

    @Test func opensOnTheFrameTheCardShowsAtItsAFPoint() async throws {
        let (model, _) = await open(day())
        model.openFocus(tapped: Point(x: 0.9, y: 0.9))                     // a frame with an AF point ignores the tap
        #expect(model.screen == .focus)
        let f = try focus(model)
        #expect(f.frame.id == 101 && f.frames.count == 1 && !f.canStep)
        #expect(f.entry == .point(Point(x: 0.1, y: 0.5)))
        #expect(f.returnScreen == .cards && f.counter == "")
        #expect(f.title == "Focus · B101")
        #expect(f.subtitle == "At the camera’s AF point · drag to look around")
    }

    @Test func aFrameWithoutAFOpensWhereYouTappedElseTheMiddle() async throws {
        let (model, _) = await open(day(3, af: [:]))
        model.openFocus(tapped: Point(x: 0.2, y: 0.7))
        #expect(try focus(model).entry == .point(Point(x: 0.2, y: 0.7)))
        #expect(try focus(model).subtitle == "1:1 from the RAW · drag to look around")
        model.closeFocus()
        model.openFocus()
        #expect(try focus(model).entry == .point(Point(x: 0.5, y: 0.5)))
    }

    @Test func aBurstCardFocusesTheFrameItShows() async throws {
        let decisions: [Int: Decision] = [102: draft(.pick, stars: 2), 101: draft(.reject), 103: draft(.reject), 104: draft(.reject)]
        let (model, _) = await open(day(decisions: decisions))
        model.go(-1)
        model.openFocus()
        #expect(try focus(model).frame.id == 102)
        #expect(try focus(model).mark?.text == "Kept" && focus(model).mark?.stars == 2)
    }

    @Test func focusOpensOnlyOverTheCardsOrThePicker() async throws {
        let (model, _) = await open(cullDay([cullStack(0, .single, [cullFrame(1, decision: draft(.pick))])]))
        #expect(model.screen == .summary)
        model.openFocus()
        #expect(model.focus == nil && model.screen == .summary)
        let (cards, _) = await open(day())
        cards.openFocus()
        cards.openFocus(frameIndex: 2)                                      // already open: not over itself
        #expect(try focus(cards).frame.id == 101)
    }

    @Test func fromThePickerItFocusesTheFrameOnShowOrTheOneTapped() async throws {
        let (model, _) = await open(day())
        model.openPicker()
        try #require(model.picker).show(2)
        model.openFocus()
        var f = try focus(model)
        #expect(f.frame.id == 103 && f.frames.map(\.id) == [101, 102, 103, 104] && f.canStep)
        #expect(f.returnScreen == .picker && f.counter == "3/4")
        #expect(f.entry == .point(Point(x: 0.1 * 3, y: 0.5)))
        model.closeFocus()
        model.openFocus(frameIndex: 0)
        f = try focus(model)
        #expect(f.frame.id == 101 && f.counter == "1/4")
        model.closeFocus()
        model.openFocus(frameIndex: 9)                                      // no such frame
        #expect(model.screen == .picker && model.focus == nil)
    }

    @Test func closingReturnsToWhereTheCheckWasOpened() async throws {
        let (model, _) = await open(day())
        model.openFocus()
        model.closeFocus()
        #expect(model.screen == .cards && model.focus == nil && model.baseScreen == .cards)
        model.openPicker()
        model.openFocus()
        #expect(model.screen == .focus && model.baseScreen == .picker)
        model.closeFocus()
        #expect(model.screen == .picker && model.picker != nil)
        model.closeFocus()                                                  // nothing to close
        #expect(model.screen == .picker)
    }

    @Test func openingAndClosingFocusDecidesAndSavesNothing() async throws {
        let (model, rig) = await open(day())
        model.openPicker()
        model.openFocus()
        try focus(model).setLinked(true)
        _ = try focus(model).step(1, from: CullZoomState(center: Point(x: 0.4, y: 0.4), scale: 5, fit: fit))
        model.closeFocus()
        model.closePicker()
        model.look(at: 1)
        #expect(model.decisions.isEmpty && !model.canUndo && model.cursor == 1)
        await rig.settle()
        #expect(rig.server.allCalls.map(\.path) == ["/m/api/day/2026/2026-10-01"])   // only the day was read
        #expect(await rig.sleeper.requested.isEmpty)
    }

    // MARK: 1:1

    @Test func oneToOneIsOneSourcePixelPerDevicePixel() {
        // 7952 px across a 390 pt picture at 3 pixels per point: 6.8 times.
        let scale = CullFocusModel.oneToOneScale(source: source, fit: fit, screenScale: 3)
        #expect(abs(scale - 7952 / 1170) < 1e-9)
        // The longest sides are compared, so an upright frame lines up the same way.
        let upright = CullFocusModel.oneToOneScale(
            source: Size(width: 5304, height: 7952), fit: Size(width: 260, height: 390), screenScale: 3)
        #expect(abs(upright - scale) < 1e-9)
        #expect(CullFocusModel.oneToOneScale(source: Size(width: 800, height: 600), fit: fit, screenScale: 3) == 1)
        #expect(CullFocusModel.oneToOneScale(source: source, fit: Size(width: 0, height: 0), screenScale: 3) == 1)
    }

    @Test func aPageStartsAtOneToOneOnceItsFullSizeIsKnown() async throws {
        let (model, _) = await open(day())
        model.openFocus()
        let f = try focus(model)
        #expect(f.start(fit: fit, source: nil, screenScale: 3) == nil)     // needs the crop's X-Crop-Box first
        let start = try #require(f.start(fit: fit, source: source, screenScale: 3))
        #expect(start.center == Point(x: 0.1, y: 0.5))
        #expect(abs(start.scale - 7952 / 1170) < 1e-9)
        #expect(f.start(fit: Size(width: 0, height: 0), source: source, screenScale: 3) == nil)
        f.setSourceSize(source, for: 101)
        #expect(f.sourceSize(for: 101) == source && f.sourceSize(for: 102) == nil)
    }

    // MARK: Stepping and linked zoom

    @Test func steppingWithoutLinkAimsAtTheNextFramesOwnAFPoint() async throws {
        let (model, _) = await open(day())
        model.openPicker()
        model.openFocus()
        let f = try focus(model)
        let state = CullZoomState(center: Point(x: 0.7, y: 0.2), scale: 6, fit: fit)
        #expect(f.step(1, from: state))
        #expect(f.frame.id == 102 && f.entry == .point(Point(x: 0.2, y: 0.5)))
        #expect(f.subtitle == "At the camera’s AF point · drag to look around")
        #expect(f.step(-2, from: state) && f.frame.id == 101)              // stops at the first frame
        #expect(!f.step(-1, from: state))                                   // at the start
        #expect(!f.step(0, from: state))
        #expect(f.step(9, from: state) && f.frame.id == 104)
        #expect(!f.step(1, from: state))                                    // at the end
    }

    @Test func linkedSteppingKeepsThePointAndTheScaleOfTheFrameBefore() async throws {
        let (model, _) = await open(day())
        model.openPicker()
        model.openFocus()
        let f = try focus(model)
        f.setLinked(true)
        let state = CullZoomState(center: Point(x: 0.7, y: 0.2), scale: 6, fit: fit)
        #expect(f.step(1, from: state))
        #expect(f.entry == .carried(state))
        #expect(f.subtitle == "Linked · same spot as the last frame · drag to look around")
        // The next frame has the same fit size: same centre, same zoom, and no full size needed.
        let next = try #require(f.start(fit: fit, source: nil, screenScale: 3))
        #expect(next.center == Point(x: 0.7, y: 0.2) && next.scale == 6)
        // Stepping on from the page that carried it keeps what that page reports it is looking at.
        let panned = CullZoomState(center: Point(x: 0.6, y: 0.3), scale: 8, fit: fit)
        #expect(f.step(1, from: panned))
        #expect(f.entry == .carried(panned))
        // Back to 1:1 on each frame's own point with Linked off.
        f.setLinked(false)
        #expect(f.step(-1, from: panned))
        #expect(f.entry == .point(Point(x: 0.2, y: 0.5)))
    }

    @Test func linkedZoomKeepsSourcePixelsPerPointWhenTheFramesFitDifferently() async throws {
        let (model, _) = await open(day())
        model.openPicker()
        model.openFocus()
        let f = try focus(model)
        f.setLinked(true)
        let landscape = Size(width: 390, height: 260)
        let state = CullZoomState(center: Point(x: 0.3, y: 0.6), scale: 6, fit: landscape)
        _ = f.step(1, from: state)
        // An upright frame with the same longest side on screen: the same zoom.
        let sameSide = try #require(f.start(fit: Size(width: 260, height: 390), source: nil, screenScale: 3))
        #expect(sameSide.center == Point(x: 0.3, y: 0.6) && sameSide.scale == 6)
        // An upright frame that fits half as large on screen needs twice the zoom for the same pixels.
        let half = try #require(f.start(fit: Size(width: 130, height: 195), source: nil, screenScale: 3))
        #expect(half.center == Point(x: 0.3, y: 0.6) && half.scale == 12)
        // And one that fits twice as large needs half, but never less than fitting the screen.
        let twice = try #require(f.start(fit: Size(width: 520, height: 780), source: nil, screenScale: 3))
        #expect(twice.scale == 3)
        let huge = try #require(f.start(fit: Size(width: 5200, height: 7800), source: nil, screenScale: 3))
        #expect(huge.scale == 1)
        // These are TilePlanner's numbers.
        let planner = TilePlanner.linkedZoom(center: state.center, scale: 6, from: landscape, to: Size(width: 130, height: 195))
        #expect(planner.center == half.center && planner.scale == half.scale)
    }

    @Test func linkedWithNothingReportedYetKeepsAimingAtTheSamePoint() async throws {
        let (model, _) = await open(day())
        model.openPicker()
        model.openFocus()
        let f = try focus(model)
        f.setLinked(true)
        #expect(f.step(1, from: nil))                                       // the first page had not reported a state
        #expect(f.entry == .point(Point(x: 0.1, y: 0.5)))                   // so the frame before's point carries over
        f.setLinked(false)
        #expect(f.step(1, from: nil))
        #expect(f.entry == .point(Point(x: 0.1 * 3, y: 0.5)))
    }

    @Test func closingFocusLeavesThePickerOnTheLastFrameLookedAtAndRemembersLinked() async throws {
        let (model, _) = await open(day())
        model.openPicker()
        model.openFocus()
        let f = try focus(model)
        f.setLinked(true)
        _ = f.step(1, from: CullZoomState(center: Point(x: 0.5, y: 0.5), scale: 4, fit: fit))
        _ = f.step(1, from: nil)
        model.closeFocus()
        #expect(try #require(model.picker).viewIndex == 2 && model.picker?.linkedFocus == true)
        model.openFocus()
        #expect(try focus(model).linked && focus(model).frame.id == 103)    // as it was left
        model.closeFocus()
        model.closePicker()
        model.openPicker()
        #expect(try #require(model.picker).linkedFocus == false)            // a new picker starts unlinked
    }

    @Test func aKnockOutFrameOpensFocusToo() async throws {
        let (model, _) = await open(day(8))
        model.openPicker()
        let picker = try #require(model.picker)
        let tap = picker.tapKnockOut(4, at: .now)
        #expect(tap == .toggled && picker.isOut(105))
        let tap2 = picker.tapKnockOut(4, at: .now)                          // a double tap
        #expect(tap2 == .focus && !picker.isOut(105))
        model.openFocus(frameIndex: 4)
        #expect(try focus(model).frame.id == 105 && focus(model).counter == "5/8")
        model.closeFocus()
        #expect(picker.knockedOut.isEmpty)
    }

    // MARK: Keep and Reject from a card's focus

    @Test func keepAndRejectInFocusDecideTheCardsFrame() async throws {
        let (model, rig) = await open(day())
        model.openFocus()
        model.keepFromFocus()
        #expect(model.screen == .cards && model.focus == nil && model.cursor == 1)
        #expect(model.decisions[101] == draft(.pick))                       // the shown frame; the other three rejected
        #expect(model.decisions[102]?.flag == .reject)
        await rig.settle()
        #expect(rig.server.calls("/m/api/decide").first?.json["changes"] != nil)
        model.openFocus()                                                   // on the single now
        model.rejectFromFocus()
        #expect(model.decisions[900] == draft(.reject))
    }

    @Test func keepAndRejectInFocusDoNothingOverThePicker() async throws {
        let (model, rig) = await open(day())
        model.openPicker()
        model.openFocus()
        model.keepFromFocus()
        model.rejectFromFocus()
        #expect(model.screen == .focus && model.decisions.isEmpty)
        await rig.settle()
        #expect(rig.server.calls("/m/api/decide").isEmpty)
    }

    @Test func undoAndAFreshLoadLeaveNoFocusOrPickerBehind() async throws {
        let (model, rig) = await open(day())
        model.keepAll()
        model.go(-1)
        model.openPicker()
        model.openFocus()
        model.undo()
        #expect(model.screen == .cards && model.focus == nil && model.picker == nil)
        model.openPicker()
        model.openFocus()
        rig.server.setDay(day())
        await model.refresh()
        #expect(model.screen == .cards && model.focus == nil && model.picker == nil)
    }

    // MARK: Where a tap falls

    @Test func aTapIsMeasuredOnThePhotoNotItsBox() {
        // A 300 x 200 photo at (50, 100) inside a bigger box.
        let rect = Rect(x: 50, y: 100, width: 300, height: 200)
        #expect(CullFocusModel.imagePoint(x: 200, y: 200, in: rect) == Point(x: 0.5, y: 0.5))
        #expect(CullFocusModel.imagePoint(x: 80, y: 250, in: rect) == Point(x: 0.1, y: 0.75))
        // Off the photo, in the letterbox bars: the nearest edge.
        #expect(CullFocusModel.imagePoint(x: 0, y: 400, in: rect) == Point(x: 0, y: 1))
        #expect(CullFocusModel.imagePoint(x: 999, y: -5, in: rect) == Point(x: 1, y: 0))
        #expect(CullFocusModel.imagePoint(x: 10, y: 10, in: Rect(x: 0, y: 0, width: 0, height: 0)) == Point(x: 0.5, y: 0.5))
    }

    @Test func theAFBoxIsNinePercentOfTheWidthThreeToTwo() {
        #expect(CullFocusModel.afBoxWidth == 0.09 && CullFocusModel.afBoxAspect == 1.5)
        #expect(cullFrame(1, af: [0.25, 0.75]).afPoint == Point(x: 0.25, y: 0.75))
        #expect(cullFrame(1).afPoint == nil && cullFrame(1).focusSpot == Point(x: 0.5, y: 0.5))
        #expect(cullFrame(1, af: [0.25]).afPoint == nil)
    }
}
