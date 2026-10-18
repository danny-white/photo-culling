import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Viewer model")
struct ViewerModelTests {
    let pacific = TimeZone(identifier: "America/Los_Angeles")!
    let english = Locale(identifier: "en_US")

    /// Photos with ids 100, 101, ... so an id is never mistaken for an index.
    private func photos(_ count: Int) -> [Photo] {
        (0..<count).map { galleryPhoto(100 + $0) }
    }

    private func makeModel(
        _ photos: [Photo], at index: Int = 0, source: FeedModel.Source = .search("x")
    ) -> ViewerModel {
        ViewerModel(photos: photos, index: index, source: source, timeZone: pacific, locale: english)
    }

    @Test func counterAndCurrentFollowTheIndex() {
        let model = makeModel(photos(120), at: 2)
        #expect(model.counter == "3 / 120")
        #expect(model.current?.id == 102)
        model.step(1)
        #expect(model.counter == "4 / 120")
    }

    @Test func theStartIndexIsClamped() {
        #expect(makeModel(photos(3), at: 9).index == 2)
        #expect(makeModel(photos(3), at: -4).index == 0)
    }

    @Test func noPhotosGiveEmptyText() {
        let model = makeModel([])
        #expect(model.current == nil)
        #expect(model.counter == "")
        #expect(model.whenText == "" && model.whereText == "" && model.caption == "")
        #expect(model.prefetchIDs.isEmpty)
        #expect(!model.step(1))
    }

    @Test func whenAndWhereTextJoinTheirParts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        let when = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 17, hour: 15, minute: 41))).timeIntervalSince1970
        let photo = galleryPhoto(
            1, date: "2026-10-17", ts: when, place: "greenwood, washington, us",
            camera: "SONY ILCE-7RM3", caption: "silhouettes on a cliff", stars: 3)
        let model = makeModel([photo])
        #expect(normalizeSpaces(model.whenText) == "Sat, Oct 17 2026 · 3:41 PM")
        #expect(model.whereText == "Greenwood · SONY ILCE-7RM3 · ★★★")
        #expect(model.caption == "silhouettes on a cliff")
    }

    @Test func missingPartsAreLeftOut() {
        let model = makeModel([galleryPhoto(1, date: nil, ts: nil)])
        #expect(model.whenText == "Undated")
        #expect(model.whereText == "")
        let onlyCamera = makeModel([galleryPhoto(1, camera: "Leica Q3")])
        #expect(onlyCamera.whereText == "Leica Q3")
        #expect(onlyCamera.caption == "")
    }

    @Test func theDayButtonIsHiddenOnADay() {
        #expect(makeModel(photos(1), source: .search("x")).showsDayButton)
        #expect(makeModel(photos(1), source: .like(3, file: nil)).showsDayButton)
        #expect(!makeModel(photos(1), source: .day("2026/2026-10-01")).showsDayButton)
    }

    // MARK: Stepping

    @Test func stepIsClampedAndSaysWhetherItMoved() {
        let model = makeModel(photos(3))
        #expect(!model.step(-1))
        #expect(model.index == 0)
        #expect(model.step(1))
        #expect(model.step(1))
        #expect(!model.step(1))
        #expect(model.index == 2)
        #expect(model.step(-2))
        #expect(model.index == 0)
        #expect(!model.step(5))
        #expect(!model.step(0))
    }

    // MARK: Prefetch

    @Test func prefetchIsTwoAheadAndOneBehind() {
        let model = makeModel(photos(10), at: 5)
        #expect(model.prefetchIDs == [106, 107, 104])
    }

    @Test func prefetchAtTheStartHasNothingBehind() {
        let model = makeModel(photos(10), at: 0)
        #expect(model.prefetchIDs == [101, 102])
    }

    @Test func prefetchAtTheEndHasNothingAhead() {
        let model = makeModel(photos(10), at: 9)
        #expect(model.prefetchIDs == [108])
        let nearEnd = makeModel(photos(10), at: 8)
        #expect(nearEnd.prefetchIDs == [109, 107])
    }

    @Test func prefetchFollowsTheDirectionOfTravel() {
        let model = makeModel(photos(10), at: 5)
        model.step(-1)
        #expect(model.index == 4)
        #expect(model.prefetchIDs == [103, 102, 105])
        model.step(1)
        #expect(model.prefetchIDs == [106, 107, 104])
    }

    @Test func aRefusedStepKeepsTheDirection() {
        let model = makeModel(photos(10), at: 0)
        #expect(!model.step(-1))
        #expect(model.prefetchIDs == [101, 102])
    }

    @Test func aSinglePhotoHasNothingToPrefetch() {
        #expect(makeModel(photos(1)).prefetchIDs.isEmpty)
    }

    // MARK: Source sizes

    @Test func sourceSizesAreRememberedPerPhoto() {
        let model = makeModel(photos(2))
        #expect(model.sourceSize(for: 100) == nil)
        model.setSourceSize(Size(width: 7952, height: 5304), for: 100)
        #expect(model.sourceSize(for: 100) == Size(width: 7952, height: 5304))
        #expect(model.sourceSize(for: 101) == nil)
        model.setSourceSize(Size(width: 6000, height: 4000), for: 100)
        #expect(model.sourceSize(for: 100) == Size(width: 6000, height: 4000))
    }
}
