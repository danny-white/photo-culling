import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Feed model")
struct FeedModelTests {
    private func makeModel(
        _ source: FeedModel.Source, transport: any HTTPTransport,
        settings: InMemoryGallerySettings = InMemoryGallerySettings()
    ) -> FeedModel {
        FeedModel(
            source: source, client: CullingBayClient(baseURL: testBaseURL, transport: transport),
            settings: settings)
    }

    /// Answers search, like and day requests with these photos.
    private func transport(
        _ photos: [Photo], total: Int? = nil, notes: [String] = [], summary: String? = nil
    ) -> FakeTransport {
        FakeTransport { request, _ in
            let path = request.url?.path ?? ""
            let body = path.contains("/gallery/day/")
                ? galleryDayBody(photos, summary: summary)
                : photoListBody(photos, total: total, notes: notes, signals: ["words", "captions"])
            return jsonResponse(body, for: request)
        }
    }

    private let three = [
        galleryPhoto(1, place: "greenwood, washington, us"), galleryPhoto(2), galleryPhoto(3),
    ]

    // MARK: Loading

    @Test func aSearchLoadsPhotosNotesAndSignals() async {
        let model = makeModel(
            .search("sunset"), transport: transport(three, total: 3, notes: ["No picture search.", "Try words."]))
        #expect(model.phase == .idle)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.photos.map(\.id) == [1, 2, 3])
        #expect(model.total == 3)
        #expect(model.signals == ["words", "captions"])
        #expect(model.notes.count == 2)
        #expect(model.note == "No picture search. Try words.")
    }

    @Test func eachSourceAsksTheRightRouteWithTheFilters() async {
        let settings = InMemoryGallerySettings(best: true, bursts: false)
        let fake = transport(three)
        for source in [FeedModel.Source.search("c++"), .like(43203, file: "DSC05040.ARW"), .day("2026/2026-10-01")] {
            await makeModel(source, transport: fake, settings: settings).load()
        }
        let urls = await fake.requests.map { $0.url?.absoluteString ?? "" }
        #expect(urls[0].hasSuffix("/m/api/gallery/search?q=c%2B%2B&best=1&bursts=0"))
        #expect(urls[1].hasSuffix("/m/api/gallery/like/43203?best=1&bursts=0"))
        #expect(urls[2].hasSuffix("/m/api/gallery/day/2026/2026-10-01?best=1&bursts=0"))
    }

    @Test func aDayLoadsItsPhotosAndCountsThem() async {
        let model = makeModel(.day("2026/2026-10-01"), transport: transport(three, summary: "Dune walk"))
        await model.load()
        #expect(model.photos.count == 3)
        #expect(model.total == 3)
        #expect(model.signals.isEmpty && model.notes.isEmpty)
    }

    // MARK: Titles

    @Test func searchTitleHasCurlyQuotesAndASubtitleWithTheTopRule() async {
        let model = makeModel(
            .search("sunset"), transport: transport(three, total: 340),
            settings: InMemoryGallerySettings(bursts: false))
        #expect(model.title == "“sunset”")
        #expect(model.subtitle == "Loading…")
        await model.load()
        #expect(model.subtitle == "3 photos (top 3 of 340)")
    }

    @Test func theTopRuleNeedsBothFiltersOff() async {
        for (best, bursts, expected) in [
            (false, true, "3 photos"), (true, false, "3 photos · best only"), (true, true, "3 photos · best only"),
            (false, false, "3 photos (top 3 of 340)"),
        ] {
            let model = makeModel(
                .search("x"), transport: transport(three, total: 340),
                settings: InMemoryGallerySettings(best: best, bursts: bursts))
            await model.load()
            #expect(model.subtitle == expected, "best=\(best) bursts=\(bursts)")
        }
    }

    @Test func aSingularCountIsOnePhoto() async {
        let model = makeModel(.like(5, file: nil), transport: transport([galleryPhoto(9)]))
        await model.load()
        #expect(model.title == "Similar photos")
        #expect(model.subtitle == "1 photo")
    }

    @Test func aDayTitleIsTheDateAndTheSubtitleHasTownCountAndSummary() async {
        let model = makeModel(.day("2026/2026-10-01"), transport: transport(three, summary: "Dune walk"))
        #expect(model.title == "Thu, Oct 1 2026")   // from the folder name before it loads
        #expect(model.subtitle == "Loading…")
        await model.load()
        #expect(model.title == "Thu, Oct 1 2026")
        #expect(model.subtitle == "Greenwood · 3 photos · Dune walk")
    }

    @Test func aDaySubtitleLeavesOutWhatIsMissing() async {
        let model = makeModel(
            .day("2026/2026-10-01"), transport: transport([galleryPhoto(1), galleryPhoto(2)]),
            settings: InMemoryGallerySettings(best: true))
        await model.load()
        #expect(model.subtitle == "2 photos · best only")
    }

    @Test func anUndatedDayIsUndatedOnceLoaded() async {
        let fake = FakeTransport { request, _ in
            jsonResponse(galleryDayBody([galleryPhoto(1, date: nil)], date: nil), for: request)
        }
        let model = makeModel(.day("misc/unsorted"), transport: fake)
        #expect(model.title == "unsorted")
        await model.load()
        #expect(model.title == "Undated")
    }

    @Test func emptyMessagesDependOnBest() {
        let normal = makeModel(.search("x"), transport: transport([]))
        #expect(normal.emptyMessage == "No photos found.")
        let best = makeModel(.search("x"), transport: transport([]), settings: InMemoryGallerySettings(best: true))
        #expect(best.emptyMessage == "Nothing you picked or rated 3★ or more. Turn off ★ Best to see everything.")
    }

    @Test func onlyADayHidesTheDatesOnItsTiles() {
        let fake = transport([])
        #expect(makeModel(.search("x"), transport: fake).showsDates)
        #expect(makeModel(.like(1, file: nil), transport: fake).showsDates)
        #expect(!makeModel(.day("2026/2026-10-01"), transport: fake).showsDates)
    }

    // MARK: Filters

    @Test func changingBestSavesItAndReloads() async {
        let settings = InMemoryGallerySettings()
        let fake = transport(three)
        let model = makeModel(.search("x"), transport: fake, settings: settings)
        await model.load()
        await model.setBest(true)
        #expect(model.best)
        #expect(settings.best)
        await model.setBursts(false)
        #expect(!model.bursts)
        #expect(!settings.bursts)
        let urls = await fake.requests.map { $0.url?.query ?? "" }
        #expect(urls == ["q=x&best=0&bursts=1", "q=x&best=1&bursts=1", "q=x&best=1&bursts=0"])
    }

    @Test func theFiltersStartFromTheSettings() {
        let model = makeModel(
            .search("x"), transport: transport([]), settings: InMemoryGallerySettings(best: true, bursts: false))
        #expect(model.best && !model.bursts)
    }

    // MARK: Latest wins

    @Test func aLoadSupersededByANewerOneNeverOverwritesIt() async {
        let gate = GatedTransport { request, _ in
            let best = request.url?.query?.contains("best=1") == true
            return jsonResponse(photoListBody(best ? [galleryPhoto(20)] : [galleryPhoto(10)]), for: request)
        }
        let model = makeModel(.search("x"), transport: gate)
        let first = Task { await model.load() }
        await gate.waitForRequests(1)
        let second = Task { await model.setBest(true) }
        await gate.waitForRequests(2)
        await gate.release(1)          // the newer answer first
        await second.value
        #expect(model.photos.map(\.id) == [20])
        await gate.release(0)          // then the stale one
        await first.value
        #expect(model.photos.map(\.id) == [20])
        #expect(model.phase == .loaded)
    }

    @Test func aStaleFailureDoesNotReplaceANewerResult() async {
        let gate = GatedTransport { request, index in
            index == 0
                ? jsonResponse("{\"error\":\"late\"}", for: request, status: 500)
                : jsonResponse(photoListBody([galleryPhoto(20)]), for: request)
        }
        let model = makeModel(.search("x"), transport: gate)
        let first = Task { await model.load() }
        await gate.waitForRequests(1)
        let second = Task { await model.setBursts(false) }
        await gate.waitForRequests(2)
        await gate.release(1)
        await second.value
        await gate.release(0)
        await first.value
        #expect(model.phase == .loaded)
        #expect(model.photos.map(\.id) == [20])
    }

    @Test func oldPhotosStayWhileAReloadIsInFlight() async {
        let gate = GatedTransport { request, index in
            jsonResponse(photoListBody(index == 0 ? [galleryPhoto(10)] : [galleryPhoto(20)]), for: request)
        }
        let model = makeModel(.search("x"), transport: gate)
        await gate.release(0)
        await model.load()
        let reload = Task { await model.setBest(true) }
        await gate.waitForRequests(2)
        #expect(model.phase == .loading)
        #expect(model.photos.map(\.id) == [10])
        #expect(model.subtitle == "1 photo · best only")
        await gate.release(1)
        await reload.value
        #expect(model.photos.map(\.id) == [20])
    }

    // MARK: Errors

    @Test func aTransportFailureAsksIfThePCIsOn() async {
        let model = makeModel(.search("x"), transport: FakeTransport { _, _ in throw URLError(.cannotConnectToHost) })
        await model.load()
        #expect(model.phase == .failed("Can’t reach the photo server. Is the PC on and in Ubuntu?"))
        #expect(model.subtitle == "")
    }

    @Test func a404SaysItIsNotInTheLibrary() async {
        let model = makeModel(
            .day("1900/1900-01-01"), transport: fixedTransport(status: 404, body: "{\"error\":\"no such day\"}"))
        await model.load()
        #expect(model.phase == .failed("That isn’t in the library any more."))
    }

    @Test func otherErrorsCarryTheServersMessage() async {
        let withMessage = makeModel(.search("x"), transport: fixedTransport(status: 500, body: "{\"error\":\"index is rebuilding\"}"))
        await withMessage.load()
        #expect(withMessage.phase == .failed("Couldn’t load that: index is rebuilding"))
        let without = makeModel(.search("x"), transport: fixedTransport(status: 502, body: "bad gateway"))
        await without.load()
        #expect(without.phase == .failed("Couldn’t load that: HTTP 502"))
        let garbled = makeModel(.search("x"), transport: fixedTransport(body: "[1,2]"))
        await garbled.load()
        guard case .failed(let message) = garbled.phase else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.hasPrefix("Couldn’t load that: "))
    }

    @Test func aFailedReloadKeepsThePhotos() async {
        let fake = FakeTransport { request, index in
            index == 0
                ? jsonResponse(photoListBody([galleryPhoto(10)]), for: request)
                : jsonResponse("{\"error\":\"busy\"}", for: request, status: 503)
        }
        let model = makeModel(.search("x"), transport: fake)
        await model.load()
        await model.setBest(true)
        #expect(model.phase == .failed("Couldn’t load that: busy"))
        #expect(model.photos.map(\.id) == [10])
    }

    // MARK: Selection

    @Test func selectionKeepsDisplayOrderAndEndsClean() async {
        let model = makeModel(.search("x"), transport: transport(three))
        await model.load()
        #expect(!model.isSelecting)
        model.toggleSelect(2)
        #expect(model.selected.isEmpty, "ignored until selecting")
        model.beginSelection()
        model.toggleSelect(3)
        model.toggleSelect(1)
        model.toggleSelect(2)
        model.toggleSelect(2)
        #expect(model.selected == [1, 3])
        #expect(model.selectedPhotos.map(\.id) == [1, 3])
        model.clearSelection()
        #expect(model.isSelecting && model.selected.isEmpty)
        model.toggleSelect(2)
        model.endSelection()
        #expect(!model.isSelecting)
        #expect(model.selected.isEmpty && model.selectedPhotos.isEmpty)
    }

    @Test func aReloadDropsSelectedPhotosThatAreGone() async {
        let fake = FakeTransport { request, index in
            jsonResponse(photoListBody(index == 0 ? [galleryPhoto(1), galleryPhoto(2)] : [galleryPhoto(2)]), for: request)
        }
        let model = makeModel(.search("x"), transport: fake)
        await model.load()
        model.beginSelection()
        model.toggleSelect(1)
        model.toggleSelect(2)
        await model.setBest(true)
        #expect(model.selected == [2])
    }
}
