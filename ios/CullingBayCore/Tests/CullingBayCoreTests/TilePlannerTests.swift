import Foundation
import Testing
@testable import CullingBayCore

@Suite("TilePlanner")
struct TilePlannerTests {
    /// A 7952 x 5304 frame (a 42 MP Sony) shown 390 pt wide on a 3x screen.
    static let source = Size(width: 7952, height: 5304)
    static let fit = Size(width: 390, height: 260)
    static let whole = Rect(x: 0, y: 0, width: 1, height: 1)

    private func plan(zoom: Double, visible: Rect = whole, screenScale: Double = 3) -> TilePlan {
        TilePlanner.plan(
            sourceSize: Self.source, fitSize: Self.fit, zoomScale: zoom,
            screenScale: screenScale, visible: visible)
    }

    /// Visible region given in source pixels.
    private func visible(x: Double, y: Double, w: Double, h: Double) -> Rect {
        Rect(x: x / 7952, y: y / 5304, width: w / 7952, height: h / 5304)
    }

    // MARK: Level thresholds

    @Test func zoomOneIsTheViewPicture() {
        let result = plan(zoom: 1)
        #expect(result.level == .view)
        #expect(result.renderedPixelWidth == 1170)
        #expect(result.tiles.isEmpty)
    }

    @Test func viewHoldsUpTo115PercentOf1616() {
        // 1616 * 1.15 = 1858.4 device pixels = 619.47 points at 3x.
        let edge = TilePlanner.plan(
            sourceSize: Self.source, fitSize: Size(width: 619.4, height: 400),
            zoomScale: 1, screenScale: 3, visible: Self.whole)
        #expect(edge.level == .view)
        let over = TilePlanner.plan(
            sourceSize: Self.source, fitSize: Size(width: 619.6, height: 400),
            zoomScale: 1, screenScale: 3, visible: Self.whole)
        #expect(over.level == .large)
    }

    @Test func largeHoldsUpTo115PercentOf3000() {
        // 3000 * 1.15 = 3450 device pixels = 1150 points at 3x.
        let edge = TilePlanner.plan(
            sourceSize: Self.source, fitSize: Size(width: 1149.9, height: 700),
            zoomScale: 1, screenScale: 3, visible: Self.whole)
        #expect(edge.level == .large)
        let over = TilePlanner.plan(
            sourceSize: Self.source, fitSize: Size(width: 1150.1, height: 700),
            zoomScale: 1, screenScale: 3, visible: Self.whole)
        guard case .tiles = over.level else {
            Issue.record("expected tiles, got \(over.level)")
            return
        }
    }

    @Test func zoomAndScreenScaleBothFeedTheRenderedWidth() {
        // 390 * 1.58 * 3 = 1848.6 -> view; 390 * 1.6 * 3 = 1872 -> large.
        #expect(plan(zoom: 1.58).level == .view)
        #expect(plan(zoom: 1.6).level == .large)
        // 390 * 2.9 * 3 = 3393 -> large; 390 * 3 * 3 = 3510 -> tiles.
        #expect(plan(zoom: 2.9).level == .large)
        #expect(!plan(zoom: 3).tiles.isEmpty)
        // The same zoom on a 2x screen needs fewer pixels: 390 * 3 * 2 = 2340 -> large.
        #expect(plan(zoom: 3, screenScale: 2).level == .large)
        #expect(plan(zoom: 1, screenScale: 1).level == .view)
    }

    // MARK: Tiles

    @Test func deepZoomPlansTheTilesAroundTheVisibleRegion() {
        // Visible x 3180.8...3976, y 2121.6...2652; plus a 300 px margin that is
        // x 2880.8...4276 (columns 2-3) and y 1821.6...2952 (rows 1-2).
        let result = plan(zoom: 8, visible: Rect(x: 0.4, y: 0.4, width: 0.1, height: 0.1))
        let tiles = result.tiles
        #expect(Set(tiles.map(\.id)) == ["2,1", "3,1", "2,2", "3,2"])
        let tile = tiles.first { $0.id == "2,1" }!
        #expect(tile.pixelRect == Rect(x: 2400, y: 1200, width: 1200, height: 1200))
        #expect(tile.width == 1200 && tile.height == 1200)
        #expect(abs(tile.centerX - 3000.0 / 7952) < 1e-12)
        #expect(abs(tile.centerY - 1800.0 / 5304) < 1e-12)
        #expect(abs(tile.normalizedRect.x - 2400.0 / 7952) < 1e-12)
        #expect(abs(tile.normalizedRect.y - 1200.0 / 5304) < 1e-12)
        #expect(abs(tile.normalizedRect.width - 1200.0 / 7952) < 1e-12)
        #expect(abs(tile.normalizedRect.height - 1200.0 / 5304) < 1e-12)
    }

    @Test func theMarginIsAQuarterTile() {
        // x: 100...850 grows to 0...1150, which stays inside column 0.
        // y: 1600...1900 grows to 1300...2200, which stays inside row 1.
        let inside = plan(zoom: 8, visible: visible(x: 100, y: 1600, w: 750, h: 300))
        #expect(inside.tiles.map(\.id) == ["0,1"])

        // x: 100...1000 grows to 0...1300, which reaches into column 1.
        let reaches = plan(zoom: 8, visible: visible(x: 100, y: 1600, w: 900, h: 300))
        #expect(Set(reaches.tiles.map(\.id)) == ["0,1", "1,1"])

        // x: 1350...1700 grows left to 1050, reaching back into column 0.
        let back = plan(zoom: 8, visible: visible(x: 1350, y: 1600, w: 350, h: 300))
        #expect(Set(back.tiles.map(\.id)) == ["0,1", "1,1"])
    }

    @Test func edgeTilesAreSmaller() throws {
        let result = plan(zoom: 8, visible: Rect(x: 0.9, y: 0.9, width: 0.1, height: 0.1))
        let tiles = result.tiles
        // x: 6856.8...7952 covers columns 5-6, y: 4473.6...5304 covers rows 3-4.
        #expect(Set(tiles.map(\.id)) == ["5,3", "6,3", "5,4", "6,4"])

        let corner = try #require(tiles.first { $0.id == "6,4" })
        #expect(corner.pixelRect == Rect(x: 7200, y: 4800, width: 752, height: 504))
        #expect(corner.width == 752 && corner.height == 504)
        #expect(abs(corner.centerX - (7200.0 + 376) / 7952) < 1e-12)
        #expect(abs(corner.centerY - (4800.0 + 252) / 5304) < 1e-12)
        #expect(abs(corner.normalizedRect.x + corner.normalizedRect.width - 1) < 1e-12)
        #expect(abs(corner.normalizedRect.y + corner.normalizedRect.height - 1) < 1e-12)

        let rightEdge = try #require(tiles.first { $0.id == "6,3" })
        #expect(rightEdge.width == 752 && rightEdge.height == 1200)
        let bottomEdge = try #require(tiles.first { $0.id == "5,4" })
        #expect(bottomEdge.width == 1200 && bottomEdge.height == 504)
    }

    @Test func portraitPhotosSwitchOnTheirLongSide() {
        // A portrait frame 260 pt wide and 390 pt tall needs as many pixels as a landscape one 390 wide.
        let portrait = TilePlanner.plan(sourceSize: Size(width: 5304, height: 7952), fitSize: Size(width: 260, height: 390),
                                        zoomScale: 1.6, screenScale: 3, visible: Rect(x: 0, y: 0, width: 1, height: 1))
        #expect(portrait.level == .large)
        #expect(portrait.renderedPixelWidth == 390 * 1.6 * 3)
    }

    @Test func aSliverAtTheEdgeJoinsTheTileBeforeIt() {
        #expect(TilePlanner.segments(7210).map(\.length) == [1200, 1200, 1200, 1200, 1200, 1210])
        #expect(TilePlanner.segments(7952).map(\.length).last == 752)
        #expect(TilePlanner.segments(1230).map(\.length) == [1230])
        #expect(TilePlanner.segments(40).map(\.length) == [40])
        let result = TilePlanner.plan(sourceSize: Size(width: 7210, height: 1200), fitSize: Size(width: 390, height: 65),
                                      zoomScale: 20, screenScale: 3, visible: Rect(x: 0.95, y: 0, width: 0.05, height: 1))
        #expect(result.tiles.contains { $0.width == 1210 && $0.pixelRect.x == 6000 })
        #expect(!result.tiles.contains { $0.width < TilePlanner.minCrop })
    }

    @Test func tilesAreOrderedByDistanceFromTheVisibleCentre() {
        // The visible region's centre sits at (3000, 1800), the middle of tile 2,1.
        let result = plan(zoom: 8, visible: visible(x: 2700, y: 1500, w: 600, h: 600))
        let tiles = result.tiles
        #expect(tiles.first?.id == "2,1")
        let cx = 3000.0, cy = 1800.0
        let distances = tiles.map { tile -> Double in
            let dx = tile.pixelRect.midX - cx
            let dy = tile.pixelRect.midY - cy
            return (dx * dx + dy * dy).squareRoot()
        }
        #expect(distances == distances.sorted())
        #expect(distances.first.map { $0 < 1e-6 } == true)
    }

    @Test func equalDistancesBreakTiesByRowThenColumn() {
        // A 4096 square keeps every number below exactly representable, so the two tiles
        // really are equidistant: the centre (1200, 600) is 600 px from each tile centre.
        func ids(_ x: Double, _ y: Double) -> [String] {
            TilePlanner.plan(
                sourceSize: Size(width: 4096, height: 4096), fitSize: Self.fit, zoomScale: 8,
                screenScale: 3,
                visible: Rect(x: x / 4096, y: y / 4096, width: 200 / 4096, height: 200 / 4096)
            ).tiles.map(\.id)
        }
        #expect(ids(1100, 500) == ["0,0", "1,0"])
        // Same split vertically, centre (600, 1200): the upper tile comes first.
        #expect(ids(500, 1100) == ["0,0", "0,1"])
    }

    @Test func tilesAreCappedAt16NearestTheCentreFirst() {
        // The whole image is 7 x 5 = 35 tiles.
        let result = plan(zoom: 8, visible: Self.whole)
        let tiles = result.tiles
        #expect(tiles.count == 16)
        #expect(TilePlanner.maxTiles == 16)
        #expect(Set(tiles.map(\.id)).count == 16)
        // Centre of the image is (3976, 2652), the middle of tile 3,2.
        #expect(tiles.first?.id == "3,2")
        // The farthest corner tiles are the ones that got cut.
        let ids = Set(tiles.map(\.id))
        #expect(!ids.contains("0,0") && !ids.contains("6,4"))
        let cx = 3976.0, cy = 2652.0
        let distances = tiles.map { tile -> Double in
            let dx = tile.pixelRect.midX - cx
            let dy = tile.pixelRect.midY - cy
            return (dx * dx + dy * dy).squareRoot()
        }
        #expect(distances == distances.sorted())
    }

    @Test func anOversizedOrOffscreenVisibleRegionIsClamped() {
        let big = plan(zoom: 8, visible: Rect(x: -1, y: -1, width: 5, height: 5))
        #expect(big.tiles.count == 16)
        let corner = plan(zoom: 8, visible: Rect(x: -0.5, y: -0.5, width: 0.5, height: 0.5))
        #expect(!corner.tiles.isEmpty)
        #expect(corner.tiles.allSatisfy { $0.column == 0 && $0.row == 0 })
    }

    @Test func everyTileLiesInsideTheSourceImage() {
        for visibleRect in [Self.whole, Rect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
                            Rect(x: 0, y: 0, width: 0.2, height: 0.2)] {
            for tile in plan(zoom: 8, visible: visibleRect).tiles {
                #expect(tile.pixelRect.x >= 0 && tile.pixelRect.y >= 0)
                #expect(tile.pixelRect.x + tile.pixelRect.width <= 7952)
                #expect(tile.pixelRect.y + tile.pixelRect.height <= 5304)
                #expect(tile.width >= 1 && tile.width <= 1200)
                #expect(tile.height >= 1 && tile.height <= 1200)
            }
        }
    }

    @Test func aDegenerateSourceGivesNoTilesInsteadOfCrashing() {
        let result = TilePlanner.plan(
            sourceSize: Size(width: 0, height: 0), fitSize: Self.fit, zoomScale: 8,
            screenScale: 3, visible: Self.whole)
        #expect(result.level == .tiles([]))
    }

    @Test func aSmallSourceHasASingleSmallTile() {
        let result = TilePlanner.plan(
            sourceSize: Size(width: 900, height: 600), fitSize: Self.fit, zoomScale: 8,
            screenScale: 3, visible: Self.whole)
        #expect(result.tiles.count == 1)
        #expect(result.tiles[0].pixelRect == Rect(x: 0, y: 0, width: 900, height: 600))
        #expect(result.tiles[0].centerX == 0.5 && result.tiles[0].centerY == 0.5)
    }

    @Test func tileCropValuesFeedTheCropURLToTheSamePixels() {
        // The crop route centres the box on (x, y) of the upright frame: recover the box.
        let corner = plan(zoom: 8, visible: Rect(x: 0.9, y: 0.9, width: 0.1, height: 0.1))
            .tiles.first { $0.id == "6,4" }!
        let client = CullingBayClient(baseURL: testBaseURL, transport: fixedTransport())
        let url = client.cropURL(
            id: 1, centerX: corner.centerX, centerY: corner.centerY,
            width: Double(corner.width), height: Double(corner.height))
        #expect(url.absoluteString == "http://100.82.57.4:8000/m/api/crop/1?x=0.952716&y=0.952489&w=752&h=504")
        let left = corner.centerX * 7952 - Double(corner.width) / 2
        let top = corner.centerY * 5304 - Double(corner.height) / 2
        #expect(abs(left - 7200) < 1e-9 && abs(top - 4800) < 1e-9)
    }

    // MARK: linkedZoom

    @Test func linkedZoomIsTheIdentityForEqualSizes() {
        let result = TilePlanner.linkedZoom(
            center: Point(x: 0.3, y: 0.7), scale: 4, from: Self.fit, to: Self.fit)
        #expect(result.scale == 4)
        #expect(result.center == Point(x: 0.3, y: 0.7))
    }

    @Test func linkedZoomMatchesSourcePixelsPerPoint() {
        // A smaller frame needs more zoom to show the same pixels per point.
        let up = TilePlanner.linkedZoom(
            center: Point(x: 0.5, y: 0.5), scale: 4,
            from: Size(width: 300, height: 200), to: Size(width: 200, height: 133))
        #expect(abs(up.scale - 6) < 1e-12)

        // A bigger frame needs less.
        let down = TilePlanner.linkedZoom(
            center: Point(x: 0.5, y: 0.5), scale: 6,
            from: Size(width: 200, height: 133), to: Size(width: 300, height: 200))
        #expect(abs(down.scale - 4) < 1e-12)

        // Going there and back is the identity.
        let back = TilePlanner.linkedZoom(
            center: up.center, scale: up.scale,
            from: Size(width: 200, height: 133), to: Size(width: 300, height: 200))
        #expect(abs(back.scale - 4) < 1e-12)
    }

    @Test func linkedZoomKeepsTheCentre() {
        let center = Point(x: 0.123, y: 0.987)
        let result = TilePlanner.linkedZoom(
            center: center, scale: 3, from: Size(width: 100, height: 80), to: Size(width: 160, height: 90))
        #expect(result.center == center)
    }

    @Test func linkedZoomNeverGoesBelowOne() {
        let result = TilePlanner.linkedZoom(
            center: Point(x: 0.5, y: 0.5), scale: 1,
            from: Size(width: 200, height: 133), to: Size(width: 400, height: 266))
        #expect(result.scale == 1)
    }

    @Test func linkedZoomComparesLongestSidesAcrossOrientations() {
        let result = TilePlanner.linkedZoom(
            center: Point(x: 0.5, y: 0.5), scale: 5,
            from: Size(width: 300, height: 200), to: Size(width: 200, height: 300))
        #expect(result.scale == 5)
    }

    @Test func linkedZoomLeavesTheScaleAloneForZeroSizes() {
        let result = TilePlanner.linkedZoom(
            center: Point(x: 0.5, y: 0.5), scale: 3, from: Size(width: 0, height: 0), to: Self.fit)
        #expect(result.scale == 3)
    }
}
