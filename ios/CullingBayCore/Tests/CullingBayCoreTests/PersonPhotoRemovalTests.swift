import Foundation
import Testing
@testable import CullingBayCore

/// "Not Alex" on one photo of the person's grid, and Undo.
@MainActor
@Suite("Person model: take them off one photo")
struct PersonPhotoRemovalTests {
    private let alex = makePerson(2, "Alex", photos: 31, faces: 38, cover: 412)
    /// What the server says about Alex once a removal is saved, and once it is undone.
    private let afterRemoval = makePerson(2, "Alex", photos: 29, faces: 35, cover: 412)
    private let afterUndo = makePerson(2, "Alex", photos: 31, faces: 38, cover: 412)

    private struct FacesWire: Encodable { let faces: [PhotoFace] }

    /// A face in a photo: Alex's (2), Sam's (1) or nobody's.
    private func face(_ id: Int, _ person: Int?) -> PhotoFace {
        let names = [1: "Sam Lee", 2: "Alex"]
        return PhotoFace(
            id: id, box: [0.1, 0.1, 0.3, 0.3], how: person == nil ? .unnamed : .confirmed,
            person: person.map { PersonRef(id: $0, name: names[$0] ?? "?") })
    }

    /// The grid is photos 1 to 5. `faces` says who is in each photo; `day` is the Cull route's answer,
    /// when a test needs the burst lookup.
    private func serve(faces: [Int: [PhotoFace]], day: CullDay? = nil) -> PeopleServer {
        let server = PeopleServer()
        server.reply("GET /m/api/people", peopleListBody(people: [alex]))
        server.reply("GET /m/api/people/2", peopleJSON(
            PersonPhotos(id: 2, name: "Alex", total: 31, photos: (1...5).map { galleryPhoto($0) })))
        for (photo, list) in faces {
            server.reply("GET /m/api/photo/\(photo)/faces", peopleJSON(FacesWire(faces: list)))
        }
        if let day { server.reply("GET /m/api/day/2026/2026-10-01", cullJSON(day)) }
        server.reply("POST /m/api/faces", peopleJSON(afterRemoval))
        server.reply("POST /m/api/people/2/add", peopleJSON(afterUndo))
        return server
    }

    /// The model and a loaded grid over the same server.
    private func rig(_ server: PeopleServer, bursts: Bool = false) async -> (PersonModel, FeedModel) {
        let client = server.client()
        let model = PersonModel(id: 2, person: alex, client: client)
        let feed = FeedModel(
            source: .person(2, name: "Alex"), client: client, settings: InMemoryGallerySettings(bursts: bursts))
        await feed.load()
        return (model, feed)
    }

    private func removed(_ result: PersonModel.PhotoRemovalResult) -> PersonModel.PhotoRemoval? {
        if case .removed(let removal) = result { removal } else { nil }
    }

    // MARK: One face, two faces, none

    @Test func oneFaceOfTheirsIsTakenOffAndTheTileGoesAtOnce() async {
        let server = serve(faces: [3: [face(30, 2), face(31, 1)]])
        let (model, feed) = await rig(server)
        let result = await model.removeFromPhoto(galleryPhoto(3), in: feed)
        let removal = removed(result)
        #expect(removal?.faces == [30], "Sam's face is left alone")
        #expect(removal?.photos == [3])
        let body = server.calls("POST /m/api/faces").first?.json
        #expect(body?["faces"] as? [Int] == [30])
        #expect(body?["action"] as? String == "not")
        #expect(body?["person"] as? Int == 2)
        #expect(feed.photos.map(\.id) == [1, 2, 4, 5])
        #expect(feed.total == 30)
        #expect(model.person == afterRemoval && model.photoCaption == "29 photos")
        #expect(model.message.isEmpty && !model.isWorking)
        #expect(server.calls("GET /m/api/people/2").count == 1, "the grid is not read again")
    }

    @Test func twoFacesOfTheirsInOnePhotoAreBothTakenOffInOneWrite() async {
        let server = serve(faces: [3: [face(30, 2), face(31, 1), face(32, 2)]])
        let (model, feed) = await rig(server)
        let removal = removed(await model.removeFromPhoto(galleryPhoto(3), in: feed))
        #expect(removal?.faces == [30, 32])
        #expect(removal?.photos == [3])
        #expect(server.calls("POST /m/api/faces").count == 1)
        #expect(server.calls("POST /m/api/faces").first?.json["faces"] as? [Int] == [30, 32])
        #expect(feed.photos.map(\.id) == [1, 2, 4, 5])
        #expect(feed.total == 30, "one photo went, not two")
    }

    @Test func noFaceOfTheirsIsTheTypedResultAndNothingIsSentOrChanged() async {
        let server = serve(faces: [3: [face(31, 1), face(32, nil)]])
        let (model, feed) = await rig(server)
        let result = await model.removeFromPhoto(galleryPhoto(3), in: feed)
        #expect(result == .notInPhoto)
        #expect(server.calls("POST /m/api/faces").isEmpty)
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5] && feed.total == 31)
        #expect(model.person == alex)
        #expect(model.message.isEmpty, "the screen says it in its toast")
    }

    @Test func aPhotoWithNoFacesAtAllIsTheSameResult() async {
        let server = serve(faces: [3: []])
        let (model, feed) = await rig(server)
        #expect(await model.removeFromPhoto(galleryPhoto(3), in: feed) == .notInPhoto)
    }

    @Test func theToastWordsNameThePersonAndSendYouToShowFaces() {
        #expect(PeopleFormat.removedFromPhoto("Alex") == "Removed Alex from this photo")
        #expect(PeopleFormat.notInPhoto("Alex") == "Alex’s face isn’t in this photo. Use Show faces to fix it.")
    }

    // MARK: Bursts

    /// Photo 3 is the tile of a burst of 3, 6 and 7. Photos 6 and 7 are not in the grid: "1/burst" hides them.
    private var burstDay: CullDay {
        cullDay([
            cullStack(0, .single, [cullFrame(1)]),
            cullStack(1, .burst, [cullFrame(3), cullFrame(6), cullFrame(7)], lead: 6),
            cullStack(2, .single, [cullFrame(8, partners: ["IMG_8.JPG"])]),
        ])
    }

    @Test func aBurstTileTakesThemOffEveryFrameOfTheBurstThatHasThem() async {
        let server = serve(
            faces: [3: [face(30, 2)], 6: [face(60, 2), face(61, 1)], 7: [face(70, 1)]], day: burstDay)
        let (model, feed) = await rig(server, bursts: true)
        let removal = removed(await model.removeFromPhoto(galleryPhoto(3), in: feed))
        #expect(removal?.faces == [30, 60], "in the burst's shot order; frame 7 has no face of theirs")
        #expect(removal?.photos == [3, 6])
        #expect(server.calls("POST /m/api/faces").count == 1)
        #expect(server.calls("POST /m/api/faces").first?.json["faces"] as? [Int] == [30, 60])
        #expect(server.calls("GET /m/api/day/2026/2026-10-01").count == 1)
        #expect(feed.photos.map(\.id) == [1, 2, 4, 5], "the tile is gone, not changed to the next frame")
        #expect(feed.total == 29, "two of their photos went")
    }

    @Test func aBurstTileWhoseOwnFrameLacksTheirFaceStillGoesWhenAnotherFrameHasIt() async {
        let server = serve(faces: [3: [face(31, 1)], 6: [face(60, 2)], 7: []], day: burstDay)
        let (model, feed) = await rig(server, bursts: true)
        let removal = removed(await model.removeFromPhoto(galleryPhoto(3), in: feed))
        #expect(removal?.faces == [60] && removal?.photos == [6])
        #expect(feed.photos.map(\.id) == [1, 2, 4, 5])
        #expect(feed.total == 30)
    }

    @Test func aBurstWithNoFaceOfTheirsInAnyFrameIsNotInPhoto() async {
        let server = serve(faces: [3: [], 6: [face(61, 1)], 7: []], day: burstDay)
        let (model, feed) = await rig(server, bursts: true)
        #expect(await model.removeFromPhoto(galleryPhoto(3), in: feed) == .notInPhoto)
        #expect(server.calls("POST /m/api/faces").isEmpty)
        #expect(feed.photos.count == 5)
    }

    @Test func aTileThatIsNoFrameOfAnyStackIsOnePhoto() async {
        // Photo 4 is in no stack of the day (a JPEG that rides along with a RAW is like that), so its
        // tile is one photo.
        let server = serve(faces: [4: [face(40, 2)]], day: burstDay)
        let (model, feed) = await rig(server, bursts: true)
        let removal = removed(await model.removeFromPhoto(galleryPhoto(4), in: feed))
        #expect(removal?.faces == [40] && removal?.photos == [4])
        #expect(server.calls("GET /m/api/photo/8/faces").isEmpty)
        #expect(feed.photos.map(\.id) == [1, 2, 3, 5])
    }

    @Test func aDayTheServerDoesNotKnowLeavesTheTileAsOnePhoto() async {
        let server = serve(faces: [3: [face(30, 2)]])
        server.reply("GET /m/api/day/2026/2026-10-01", #"{"error":"not found"}"#, status: 404)
        let (model, feed) = await rig(server, bursts: true)
        let removal = removed(await model.removeFromPhoto(galleryPhoto(3), in: feed))
        #expect(removal?.photos == [3])
        #expect(feed.photos.map(\.id) == [1, 2, 4, 5])
    }

    @Test func withBurstsOffATileIsOnePhotoAndTheDayIsNotRead() async {
        let server = serve(faces: [3: [face(30, 2)], 6: [face(60, 2)]], day: burstDay)
        let (model, feed) = await rig(server, bursts: false)
        let removal = removed(await model.removeFromPhoto(galleryPhoto(3), in: feed))
        #expect(removal?.photos == [3])
        #expect(server.calls("GET /m/api/day/2026/2026-10-01").isEmpty)
        #expect(server.calls("GET /m/api/photo/6/faces").isEmpty)
    }

    // MARK: Undo

    @Test func undoSendsAddWithExactlyTheRemovedFacesAndPutsTheTileBack() async {
        let server = serve(
            faces: [3: [face(30, 2)], 6: [face(60, 2)], 7: []], day: burstDay)
        let (model, feed) = await rig(server, bursts: true)
        guard let removal = removed(await model.removeFromPhoto(galleryPhoto(3), in: feed)) else {
            Issue.record("expected a removal")
            return
        }
        #expect(await model.undoRemoval(removal, in: feed))
        let adds = server.calls("POST /m/api/people/2/add")
        #expect(adds.count == 1)
        #expect(adds.first?.json["faces"] as? [Int] == [30, 60])
        #expect(adds.first?.json["group"] == nil)
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5], "back where it was")
        #expect(feed.total == 31)
        #expect(model.person == afterUndo)
        #expect(server.calls("GET /m/api/people/2").count == 1, "no reload needed")
    }

    @Test func undoPutsBackEveryTileOfAnEarlierRemovalInItsOwnPlace() async throws {
        let server = serve(faces: [2: [face(20, 2)], 4: [face(40, 2)]])
        let (model, feed) = await rig(server)
        let first = try #require(removed(await model.removeFromPhoto(galleryPhoto(2), in: feed)))
        let second = try #require(removed(await model.removeFromPhoto(galleryPhoto(4), in: feed)))
        #expect(feed.photos.map(\.id) == [1, 3, 5])
        // Undone the other way round, which is what a second toast would do.
        #expect(await model.undoRemoval(second, in: feed))
        #expect(feed.photos.map(\.id) == [1, 3, 4, 5])
        #expect(await model.undoRemoval(first, in: feed))
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test func undoAfterTheGridWasLoadedAgainLoadsItAgainInsteadOfGuessingWhereTheTileWas() async {
        let server = serve(faces: [3: [face(30, 2)]])
        let (model, feed) = await rig(server)
        guard let removal = removed(await model.removeFromPhoto(galleryPhoto(3), in: feed)) else {
            Issue.record("expected a removal")
            return
        }
        await feed.setBursts(true)   // the grid is read again, as the server has it by now
        #expect(server.calls("GET /m/api/people/2").count == 2)
        #expect(await model.undoRemoval(removal, in: feed))
        #expect(server.calls("GET /m/api/people/2").count == 3, "loaded once more")
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test func aFailedUndoPutsNothingBackAndSaysWhy() async {
        let server = serve(faces: [3: [face(30, 2)]])
        let (model, feed) = await rig(server)
        guard let removal = removed(await model.removeFromPhoto(galleryPhoto(3), in: feed)) else {
            Issue.record("expected a removal")
            return
        }
        server.reply("POST /m/api/people/2/add", #"{"error":"busy"}"#, status: 503)
        #expect(await model.undoRemoval(removal, in: feed) == false)
        #expect(feed.photos.map(\.id) == [1, 2, 4, 5])
        #expect(model.person == afterRemoval)
        #expect(model.message == "Couldn’t save that: busy")
        #expect(!model.isWorking)
    }

    // MARK: Failures

    @Test func aFailedWriteLeavesTheFeedAndThePersonAsTheyWereAndSaysWhy() async {
        let server = serve(faces: [3: [face(30, 2)]])
        server.reply("POST /m/api/faces", #"{"error":"busy"}"#, status: 503)
        let (model, feed) = await rig(server)
        let result = await model.removeFromPhoto(galleryPhoto(3), in: feed)
        #expect(result == .failed)
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5] && feed.total == 31)
        #expect(model.person == alex)
        #expect(model.message == "Couldn’t save that: busy")
        #expect(!model.isWorking)
    }

    @Test func withTheServerUnreachableItSaysTheExistingThing() async {
        let client = CullingBayClient(
            baseURL: testBaseURL, transport: FakeTransport { request, _ in
                if request.url?.path == "/m/api/people/2" {
                    return jsonResponse(
                        peopleJSON(PersonPhotos(id: 2, name: "Alex", total: 1, photos: [galleryPhoto(3)])),
                        for: request)
                }
                throw URLError(.notConnectedToInternet)
            })
        let model = PersonModel(id: 2, person: alex, client: client)
        let feed = FeedModel(
            source: .person(2, name: "Alex"), client: client, settings: InMemoryGallerySettings(bursts: false))
        await feed.load()
        #expect(await model.removeFromPhoto(galleryPhoto(3), in: feed) == .failed)
        #expect(model.message == "Can’t reach the photo server. Is the PC on and in Ubuntu?")
        #expect(feed.photos.map(\.id) == [3])
    }

    @Test func withWorkOfflineOnItSaysSo() async {
        let client = CullingBayClient(
            baseURL: testBaseURL, transport: FakeTransport { request, _ in
                if request.url?.path == "/m/api/people/2" {
                    return jsonResponse(
                        peopleJSON(PersonPhotos(id: 2, name: "Alex", total: 1, photos: [galleryPhoto(3)])),
                        for: request)
                }
                throw CullingBayError.transport(ServerLink.forcedMessage)
            })
        let model = PersonModel(id: 2, person: alex, client: client)
        let feed = FeedModel(
            source: .person(2, name: "Alex"), client: client, settings: InMemoryGallerySettings(bursts: false))
        await feed.load()
        #expect(await model.removeFromPhoto(galleryPhoto(3), in: feed) == .failed)
        #expect(model.message == "Work offline is on. Turn it off to change people.")
    }

    @Test func aFailureReadingTheFacesSendsNothingAndLeavesTheFeed() async {
        let server = serve(faces: [:])
        server.reply("GET /m/api/photo/3/faces", #"{"error":"not found"}"#, status: 404)
        let (model, feed) = await rig(server)
        #expect(await model.removeFromPhoto(galleryPhoto(3), in: feed) == .failed)
        #expect(server.calls("POST /m/api/faces").isEmpty)
        #expect(feed.photos.count == 5)
        #expect(model.message == "That person or face isn’t there any more.")
    }

    @Test func aFailureReadingTheBurstSendsNothingAndLeavesTheFeed() async {
        let server = serve(faces: [3: [face(30, 2)]])
        server.reply("GET /m/api/day/2026/2026-10-01", #"{"error":"busy"}"#, status: 503)
        let (model, feed) = await rig(server, bursts: true)
        #expect(await model.removeFromPhoto(galleryPhoto(3), in: feed) == .failed)
        #expect(server.calls("POST /m/api/faces").isEmpty)
        #expect(feed.photos.count == 5)
        #expect(model.message == "Couldn’t save that: busy")
    }

    @Test func aSecondRemovalWhileOneIsInFlightIsTurnedAwayNotQueued() async {
        let gate = GatedTransport { request, _ in
            let path = request.url?.path ?? ""
            let body: String
            switch path {
            case "/m/api/photo/3/faces": body = peopleJSON(FacesWire(faces: [PhotoFace(
                id: 30, box: [0, 0, 1, 1], how: .confirmed, person: PersonRef(id: 2, name: "Alex"))]))
            case "/m/api/people/2":
                body = peopleJSON(
                    PersonPhotos(id: 2, name: "Alex", total: 2, photos: [galleryPhoto(3), galleryPhoto(4)]))
            default: body = peopleJSON(makePerson(2, "Alex", photos: 1))
            }
            return jsonResponse(body, for: request)
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: gate)
        let model = PersonModel(id: 2, person: alex, client: client)
        let feed = FeedModel(
            source: .person(2, name: "Alex"), client: client, settings: InMemoryGallerySettings(bursts: false))
        await gate.release(0)
        await feed.load()
        let first = Task { await model.removeFromPhoto(galleryPhoto(3), in: feed) }
        await gate.waitForRequests(2)
        #expect(model.isWorking)
        #expect(await model.removeFromPhoto(galleryPhoto(4), in: feed) == .failed)
        #expect(model.message == "Still saving the last change. Try again in a moment.")
        await gate.release(1)
        await gate.release(2)
        _ = await first.value
        #expect(feed.photos.map(\.id) == [4])
    }

    // MARK: The grid is not reloaded for it

    @Test func theGridKeyFollowsReviewsAndLoadsButNotTheTilesOwnRemoval() async throws {
        let server = serve(faces: [3: [face(30, 2)]])
        server.reply("GET /m/api/people", peopleListBody(people: [makePerson(2, "Alex", photos: 40, faces: 50)]))
        let (model, feed) = await rig(server)
        #expect(model.feedKey == [31, 38])
        let removal = try #require(removed(await model.removeFromPhoto(galleryPhoto(3), in: feed)))
        #expect(model.person?.photos == 29)
        #expect(model.feedKey == [31, 38], "the grid already shows the removal")
        #expect(await model.undoRemoval(removal, in: feed))
        #expect(model.feedKey == [31, 38])
        model.update(makePerson(2, "Alex", photos: 35, faces: 41))
        #expect(model.feedKey == [35, 41], "a review added photos the grid has not seen")
        await model.load()
        #expect(model.feedKey == [40, 50], "so did the fix screen")
    }

    @Test func withNoPersonYetTheKeyIsZerosAsTheScreenAlwaysHadIt() {
        let model = PersonModel(id: 2, client: PeopleServer().client())
        #expect(model.feedKey == [0, 0])
    }
}

/// Taking tiles out of a grid and putting them back.
@MainActor
@Suite("Feed model: removing and restoring tiles")
struct FeedModelRemovalTests {
    private func loaded(total: Int = 5) async -> (FeedModel, FakeTransport) {
        let fake = FakeTransport { request, _ in
            jsonResponse(
                peopleJSON(PersonPhotos(id: 2, name: "Alex", total: total, photos: (1...5).map { galleryPhoto($0) })),
                for: request)
        }
        let feed = FeedModel(
            source: .person(2, name: "Alex"), client: CullingBayClient(baseURL: testBaseURL, transport: fake),
            settings: InMemoryGallerySettings(bursts: false))
        await feed.load()
        return (feed, fake)
    }

    @Test func removeTakesTilesOutAndRestoreReturnsThemToTheirPlaces() async {
        let (feed, _) = await loaded()
        let removed = feed.remove([2, 4], lowersTotalBy: 2)
        #expect(feed.photos.map(\.id) == [1, 3, 5])
        #expect(feed.total == 3)
        #expect(removed.tiles.map(\.index) == [1, 3])
        #expect(feed.restore(removed))
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5])
        #expect(feed.total == 5)
    }

    @Test func idsNotInTheGridAreIgnoredAndTotalNeverGoesBelowZero() async {
        let (feed, _) = await loaded(total: 1)
        let removed = feed.remove([99], lowersTotalBy: 3)
        #expect(removed.isEmpty && feed.photos.count == 5)
        #expect(feed.total == 0)
    }

    @Test func editsCountTakingOutAndPuttingBackButNotLoads() async {
        let (feed, _) = await loaded()
        #expect(feed.edits == 0)
        feed.remove([99])
        #expect(feed.edits == 0, "nothing was in the grid to take out")
        let removed = feed.remove([2])
        #expect(feed.edits == 1)
        feed.restore(removed)
        #expect(feed.edits == 2)
        feed.restore(removed)
        #expect(feed.edits == 2, "nothing went back the second time")
        await feed.load()
        #expect(feed.edits == 2, "a load is not an edit")
    }

    @Test func removedTilesLeaveTheSelection() async {
        let (feed, _) = await loaded()
        feed.beginSelection()
        feed.toggleSelect(2)
        feed.toggleSelect(3)
        feed.remove([2])
        #expect(feed.selected == [3])
    }

    @Test func restoreDoesNotDoubleATileTheGridHasAgain() async {
        let (feed, _) = await loaded()
        let removed = feed.remove([2])
        #expect(feed.restore(removed))
        #expect(feed.restore(removed))
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test func restoreRefusesOnceTheGridHasBeenLoadedAgain() async {
        let (feed, _) = await loaded()
        let removed = feed.remove([2])
        await feed.load()
        #expect(feed.restore(removed) == false)
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5], "the load brought it back")
    }
}
