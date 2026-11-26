import Foundation
import Testing
@testable import CullingBayCore

/// The results screen for a person and for an unnamed group.
@MainActor
@Suite("Feed model: people")
struct FeedModelPeopleTests {
    private func makeModel(
        _ source: FeedModel.Source, transport: any HTTPTransport,
        settings: InMemoryGallerySettings = InMemoryGallerySettings()
    ) -> FeedModel {
        FeedModel(
            source: source, client: CullingBayClient(baseURL: testBaseURL, transport: transport),
            settings: settings)
    }

    /// A person's and a group's photos, as the server answers: 3 shown of `total`.
    private func transport(total: Int = 3) -> FakeTransport {
        FakeTransport { request, _ in
            let photos = [galleryPhoto(1), galleryPhoto(2), galleryPhoto(3)]
            let path = request.url?.path ?? ""
            let body = path.contains("/people/group/")
                ? peopleJSON(GroupPhotos(key: 315, total: total, photos: photos))
                : peopleJSON(PersonPhotos(id: 2, name: "Alex", total: total, photos: photos))
            return jsonResponse(body, for: request)
        }
    }

    @Test func aPersonLoadsFromTheirRouteWithTheFilters() async {
        let fake = transport()
        let model = makeModel(
            .person(2, name: "Alex"), transport: fake, settings: InMemoryGallerySettings(best: true, bursts: false))
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.photos.map(\.id) == [1, 2, 3])
        #expect(model.signals.isEmpty && model.notes.isEmpty)
        let url = await fake.requests.first?.url
        #expect(url?.path == "/m/api/people/2")
        #expect(url?.query == "best=1&bursts=0")
    }

    @Test func aGroupLoadsFromItsRouteWithTheFilters() async {
        let fake = transport()
        let model = makeModel(.group(315), transport: fake)
        await model.load()
        #expect(model.photos.map(\.id) == [1, 2, 3])
        let url = await fake.requests.first?.url
        #expect(url?.path == "/m/api/people/group/315")
        #expect(url?.query == "best=0&bursts=1")
    }

    @Test func theTotalCountsBeforeTheFilters() async {
        let model = makeModel(.person(2, name: "Alex"), transport: transport(total: 31))
        await model.load()
        #expect(model.total == 31)
        #expect(model.photos.count == 3)
    }

    @Test func titlesAreTheNameAndNotNamedYet() {
        #expect(makeModel(.person(2, name: "Alex"), transport: transport()).title == "Alex")
        #expect(makeModel(.group(315), transport: transport()).title == "Not named yet")
    }

    @Test func theSubtitleCountsThePhotosAndTheTopRuleStillNeedsBothFiltersOff() async {
        let model = makeModel(
            .person(2, name: "Alex"), transport: transport(total: 31),
            settings: InMemoryGallerySettings(bursts: false))
        #expect(model.subtitle == "Loading…")
        await model.load()
        #expect(model.subtitle == "3 photos (top 3 of 31)")
        await model.setBursts(true)
        #expect(model.subtitle == "3 photos")
    }

    @Test func theScreensAreNamedForTheTimingLog() {
        #expect(FeedModel.Source.person(2, name: "Alex").screen == "person")
        #expect(FeedModel.Source.group(1).screen == "group")
    }

    @Test func tilesCarryTheirDatesForPeopleAndGroups() {
        #expect(makeModel(.person(2, name: "Alex"), transport: transport()).showsDates)
        #expect(makeModel(.group(1), transport: transport()).showsDates)
    }

    @Test func anEmptyGroupSaysItsFacesAreGone() async {
        let fake = FakeTransport { request, _ in
            jsonResponse(peopleJSON(GroupPhotos(key: 315, total: 0, photos: [])), for: request)
        }
        let model = makeModel(.group(315), transport: fake)
        await model.load()
        #expect(model.photos.isEmpty && model.phase == .loaded)
        #expect(model.emptyMessage == "Nothing is left in this group. Its faces have been named or hidden.")
        let person = makeModel(.person(2, name: "Alex"), transport: fake)
        #expect(person.emptyMessage == "No photos found.")
    }

    @Test func anUnknownPersonIsNotInTheLibraryAnyMore() async {
        let model = makeModel(
            .person(99, name: "Alex"), transport: fixedTransport(status: 404, body: #"{"error":"no such person"}"#))
        await model.load()
        #expect(model.phase == .failed("That isn’t in the library any more."))
    }

    @Test func peopleAndGroupsKeepTheirPhotosForTheViewerAndSave() async {
        let model = makeModel(.person(2, name: "Alex"), transport: transport())
        await model.load()
        model.beginSelection()
        model.toggleSelect(2)
        #expect(model.selectedPhotos.map(\.id) == [2])
    }
}
