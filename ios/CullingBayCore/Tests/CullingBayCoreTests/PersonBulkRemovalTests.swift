import Foundation
import Testing
@testable import CullingBayCore

/// "Not Alex" on a selection of tiles of the person's grid, and Undo. The one-tile version and the
/// rules they share are in `PersonPhotoRemovalTests`.
@MainActor
@Suite("Person model: take them off several photos")
struct PersonBulkRemovalTests {
    private let alex = makePerson(2, "Alex", photos: 31, faces: 38, cover: 412)
    /// What the server says about Alex once a removal is saved, and once it is undone.
    private let afterRemoval = makePerson(2, "Alex", photos: 27, faces: 33, cover: 412)
    private let afterUndo = makePerson(2, "Alex", photos: 31, faces: 38, cover: 412)

    private struct FacesWire: Encodable { let faces: [PhotoFace] }

    /// A face in a photo: Alex's (2), Sam's (1) or nobody's.
    private static func face(_ id: Int, _ person: Int?) -> PhotoFace {
        let names = [1: "Sam Lee", 2: "Alex"]
        return PhotoFace(
            id: id, box: [0.1, 0.1, 0.3, 0.3], how: person == nil ? .unnamed : .confirmed,
            person: person.map { PersonRef(id: $0, name: names[$0] ?? "?") })
    }

    private func face(_ id: Int, _ person: Int?) -> PhotoFace { Self.face(id, person) }

    /// A photo of the second day, which `galleryPhoto` can't make.
    private func laterPhoto(_ id: Int) -> Photo {
        Photo(
            id: id, day: "2026/2026-10-02", date: "2026-10-02", ts: nil, file: "IMG_\(id).JPG", bytes: nil,
            camera: nil, caption: nil, place: nil, stars: 0, picked: false, rejected: false, raw: false)
    }

    private static let firstDay = "GET /m/api/day/2026/2026-10-01"
    private static let secondDay = "GET /m/api/day/2026/2026-10-02"

    /// The grid is `grid` (photos 1 to 5 unless a test says otherwise). `faces` says who is in each photo;
    /// `day` is the Cull route's answer for the first day, when a test needs the burst lookup.
    private func serve(
        faces: [Int: [PhotoFace]], day: CullDay? = nil, grid: [Photo] = (1...5).map { galleryPhoto($0) }
    ) -> PeopleServer {
        let server = PeopleServer()
        server.reply("GET /m/api/people", peopleListBody(people: [alex]))
        server.reply("GET /m/api/people/2", peopleJSON(PersonPhotos(id: 2, name: "Alex", total: 31, photos: grid)))
        for (photo, list) in faces {
            server.reply("GET /m/api/photo/\(photo)/faces", peopleJSON(FacesWire(faces: list)))
        }
        if let day { server.reply(Self.firstDay, cullJSON(day)) }
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

    /// Tiles of the grid by id, in the order given.
    private func tiles(_ ids: Int...) -> [Photo] { ids.map { galleryPhoto($0) } }

    private func removed(_ result: PersonModel.PhotoRemovalResult) -> PersonModel.PhotoRemoval? {
        if case .removed(let removal) = result { removal } else { nil }
    }

    // MARK: Several tiles, one write

    @Test func severalTilesEachWithTheirFaceAreTakenOffInOneWriteAndGoAtOnce() async {
        let server = serve(faces: [
            2: [face(20, 2)], 4: [face(40, 2), face(41, 1)], 5: [face(50, 2), face(51, 2)],
        ])
        let (model, feed) = await rig(server)
        let result = await model.removeFromPhotos(tiles(2, 4, 5), in: feed)
        let removal = removed(result)
        #expect(removal?.faces == [20, 40, 50, 51], "Sam's face is left alone")
        #expect(removal?.photos == [2, 4, 5])
        #expect(removal?.skippedTiles == 0)
        let writes = server.calls("POST /m/api/faces")
        #expect(writes.count == 1)
        #expect(writes.first?.json["faces"] as? [Int] == [20, 40, 50, 51])
        #expect(writes.first?.json["action"] as? String == "not")
        #expect(writes.first?.json["person"] as? Int == 2)
        #expect(feed.photos.map(\.id) == [1, 3])
        #expect(feed.total == 28, "three photos went, however many faces they had")
        #expect(model.person == afterRemoval && model.photoCaption == "27 photos")
        #expect(model.message.isEmpty && !model.isWorking)
        #expect(server.calls("GET /m/api/people/2").count == 1, "the grid is not read again")
        #expect(server.calls("GET /m/api/photo/1/faces").isEmpty, "photos nobody picked are not read")
        #expect(server.calls("GET /m/api/photo/3/faces").isEmpty)
    }

    @Test func tilesThatLackTheirFaceStayAndAreCounted() async {
        let server = serve(faces: [2: [face(20, 2)], 3: [face(31, 1), face(32, nil)], 4: [face(40, 2)], 5: []])
        let (model, feed) = await rig(server)
        let removal = removed(await model.removeFromPhotos(tiles(2, 3, 4, 5), in: feed))
        #expect(removal?.faces == [20, 40] && removal?.photos == [2, 4])
        #expect(removal?.skippedTiles == 2, "Sam's photo and the one with no faces")
        #expect(server.calls("POST /m/api/faces").first?.json["faces"] as? [Int] == [20, 40])
        #expect(feed.photos.map(\.id) == [1, 3, 5])
        #expect(feed.total == 29)
    }

    @Test func noFaceOfTheirsInAnyTileIsTheTypedResultAndNothingIsSentOrChanged() async {
        let server = serve(faces: [2: [face(21, 1)], 3: [], 4: [face(41, nil)]])
        let (model, feed) = await rig(server)
        #expect(await model.removeFromPhotos(tiles(2, 3, 4), in: feed) == .notInPhoto)
        #expect(server.calls("POST /m/api/faces").isEmpty)
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5] && feed.total == 31)
        #expect(model.person == alex)
        #expect(model.message.isEmpty, "the screen says it in its toast")
        #expect(!model.isWorking)
    }

    @Test func noTilesAtAllIsNotInPhotoAndAsksNothing() async {
        let server = serve(faces: [:])
        let (model, feed) = await rig(server)
        #expect(await model.removeFromPhotos([], in: feed) == .notInPhoto)
        #expect(server.calls().count == 1, "only the grid's own load")
    }

    @Test func aTileInTheListTwiceIsReadAndRemovedOnce() async {
        let server = serve(faces: [3: [face(30, 2)]])
        let (model, feed) = await rig(server)
        let removal = removed(await model.removeFromPhotos(tiles(3, 3), in: feed))
        #expect(removal?.faces == [30] && removal?.photos == [3] && removal?.skippedTiles == 0)
        #expect(server.calls("GET /m/api/photo/3/faces").count == 1)
        #expect(server.calls("POST /m/api/faces").first?.json["faces"] as? [Int] == [30])
        #expect(feed.total == 30)
    }

    @Test func oneTileThroughTheOneTileDoorHasNothingSkipped() async {
        let server = serve(faces: [3: [face(30, 2)]])
        let (model, feed) = await rig(server)
        let removal = removed(await model.removeFromPhoto(galleryPhoto(3), in: feed))
        #expect(removal?.skippedTiles == 0)
        #expect(removal?.faces == [30])
    }

    @Test func removedTilesLeaveTheSelectionAndTheOnesThatStayKeepTheirs() async {
        let server = serve(faces: [2: [face(20, 2)], 3: [face(31, 1)], 4: [face(40, 2)]])
        let (model, feed) = await rig(server)
        feed.beginSelection()
        for id in [2, 3, 4] { feed.toggleSelect(id) }
        _ = await model.removeFromPhotos(feed.selectedPhotos, in: feed)
        #expect(feed.selected == [3], "the tile that stayed is still selected until the screen ends the selection")
        #expect(feed.isSelecting)
    }

    // MARK: Bursts

    /// Photo 3 is the tile of a burst of 3, 6 and 7, and photo 4 of 4 and 9. Photos 2 and 5 are in no stack
    /// of the day. Photos 6, 7 and 9 are not in the grid: "1/burst" hides them.
    private var burstDay: CullDay {
        cullDay([
            cullStack(0, .single, [cullFrame(1)]),
            cullStack(1, .burst, [cullFrame(3), cullFrame(6), cullFrame(7)], lead: 6),
            cullStack(2, .burst, [cullFrame(4), cullFrame(9)]),
        ])
    }

    @Test func twoBurstTilesOfOneDayReadTheDayOnceAndTakeThemOffEveryFrameThatHasThem() async {
        let server = serve(
            faces: [
                2: [face(20, 2)], 3: [face(30, 2)], 4: [face(41, 1)], 6: [face(60, 2), face(61, 1)], 7: [],
                9: [face(90, 2)],
            ], day: burstDay)
        let (model, feed) = await rig(server, bursts: true)
        let removal = removed(await model.removeFromPhotos(tiles(2, 3, 4), in: feed))
        #expect(server.calls(Self.firstDay).count == 1, "one read of the day for three tiles")
        #expect(removal?.faces == [20, 30, 60, 90], "tile by tile, in each burst's shot order")
        #expect(removal?.photos == [2, 3, 6, 9])
        #expect(removal?.skippedTiles == 0, "tile 4's own frame lacks the face but its burst has it")
        #expect(server.calls("POST /m/api/faces").count == 1)
        #expect(server.calls("POST /m/api/faces").first?.json["faces"] as? [Int] == [20, 30, 60, 90])
        #expect(feed.photos.map(\.id) == [1, 5], "the tiles are gone, not changed to the next frame")
        #expect(feed.total == 27, "four of their photos went")
    }

    @Test func aBurstWithNoFaceOfTheirsInAnyFrameStaysAndIsCounted() async {
        let server = serve(
            faces: [3: [], 6: [face(61, 1)], 7: [], 4: [face(40, 2)], 9: []], day: burstDay)
        let (model, feed) = await rig(server, bursts: true)
        let removal = removed(await model.removeFromPhotos(tiles(3, 4), in: feed))
        #expect(removal?.faces == [40] && removal?.photos == [4])
        #expect(removal?.skippedTiles == 1)
        #expect(feed.photos.map(\.id) == [1, 2, 3, 5])
    }

    @Test func eachDayIsReadOnceWhenTilesComeFromSeveralDays() async {
        let grid = [galleryPhoto(3), galleryPhoto(4), laterPhoto(6), laterPhoto(8), laterPhoto(11)]
        let server = serve(
            faces: [3: [face(30, 2)], 7: [face(70, 2)], 4: [], 6: [face(60, 2)], 8: [face(80, 2)], 11: []],
            day: cullDay([cullStack(0, .burst, [cullFrame(3), cullFrame(7)]), cullStack(1, .single, [cullFrame(4)])]),
            grid: grid)
        server.reply(
            Self.secondDay,
            cullJSON(cullDay([
                cullStack(0, .single, [cullFrame(6)]), cullStack(1, .single, [cullFrame(8)]),
                cullStack(2, .single, [cullFrame(11)]),
            ])))
        let (model, feed) = await rig(server, bursts: true)
        let removal = removed(await model.removeFromPhotos(grid, in: feed))
        #expect(server.calls(Self.firstDay).count == 1)
        #expect(server.calls(Self.secondDay).count == 1, "three tiles of the second day, one read")
        #expect(removal?.faces == [30, 70, 60, 80])
        #expect(removal?.skippedTiles == 2)
        #expect(feed.photos.map(\.id) == [4, 11])
    }

    @Test func aDayTheServerDoesNotKnowLeavesItsTilesAsOnePhotoEach() async {
        let server = serve(faces: [3: [face(30, 2)], 4: [face(40, 2)]])
        server.reply(Self.firstDay, #"{"error":"not found"}"#, status: 404)
        let (model, feed) = await rig(server, bursts: true)
        let removal = removed(await model.removeFromPhotos(tiles(3, 4), in: feed))
        #expect(server.calls(Self.firstDay).count == 1)
        #expect(removal?.faces == [30, 40] && removal?.photos == [3, 4])
        #expect(server.calls("GET /m/api/photo/6/faces").isEmpty)
        #expect(feed.photos.map(\.id) == [1, 2, 5])
    }

    @Test func withBurstsOffTilesAreOnePhotoEachAndTheDayIsNotRead() async {
        let server = serve(faces: [3: [face(30, 2)], 4: [face(40, 2)], 6: [face(60, 2)]], day: burstDay)
        let (model, feed) = await rig(server, bursts: false)
        let removal = removed(await model.removeFromPhotos(tiles(3, 4), in: feed))
        #expect(removal?.photos == [3, 4])
        #expect(server.calls(Self.firstDay).isEmpty)
        #expect(server.calls("GET /m/api/photo/6/faces").isEmpty)
    }

    // MARK: Failures

    @Test func aFailureReadingOneFaceSendsNothingAndLeavesTheFeed() async {
        let server = serve(faces: [2: [face(20, 2)], 3: [face(30, 2)]])
        server.reply("GET /m/api/photo/4/faces", #"{"error":"busy"}"#, status: 503)
        let (model, feed) = await rig(server)
        #expect(await model.removeFromPhotos(tiles(2, 3, 4), in: feed) == .failed)
        #expect(server.calls("POST /m/api/faces").isEmpty, "the reading is done before the writing")
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5] && feed.total == 31)
        #expect(model.person == alex)
        #expect(model.message == "Couldn’t save that: busy")
        #expect(!model.isWorking)
    }

    @Test func aFailureReadingTheDaySendsNothingAndLeavesTheFeed() async {
        let server = serve(faces: [3: [face(30, 2)], 4: [face(40, 2)]])
        server.reply(Self.firstDay, #"{"error":"busy"}"#, status: 503)
        let (model, feed) = await rig(server, bursts: true)
        #expect(await model.removeFromPhotos(tiles(3, 4), in: feed) == .failed)
        #expect(server.calls("POST /m/api/faces").isEmpty)
        #expect(feed.photos.count == 5 && feed.total == 31)
        #expect(model.message == "Couldn’t save that: busy")
    }

    @Test func aFailedWriteLeavesTheFeedAndThePersonAsTheyWereAndSaysWhy() async {
        let server = serve(faces: [2: [face(20, 2)], 3: [face(30, 2)]])
        server.reply("POST /m/api/faces", #"{"error":"busy"}"#, status: 503)
        let (model, feed) = await rig(server)
        #expect(await model.removeFromPhotos(tiles(2, 3), in: feed) == .failed)
        #expect(server.calls("POST /m/api/faces").count == 1)
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5] && feed.total == 31)
        #expect(model.person == alex)
        #expect(model.message == "Couldn’t save that: busy")
        #expect(!model.isWorking)
    }

    @Test func aSecondRemovalWhileOneIsInFlightIsTurnedAwayNotQueued() async {
        let gate = GatedTransport { request, _ in
            let path = request.url?.path ?? ""
            let body: String
            switch path {
            case "/m/api/photo/3/faces", "/m/api/photo/4/faces":
                let id = Int(path.split(separator: "/")[3]) ?? 0
                body = peopleJSON(FacesWire(faces: [
                    PhotoFace(id: id * 10, box: [0, 0, 1, 1], how: .confirmed, person: PersonRef(id: 2, name: "Alex")),
                ]))
            case "/m/api/people/2":
                body = peopleJSON(PersonPhotos(
                    id: 2, name: "Alex", total: 3, photos: [galleryPhoto(3), galleryPhoto(4), galleryPhoto(5)]))
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
        let first = Task { await model.removeFromPhotos([galleryPhoto(3), galleryPhoto(4)], in: feed) }
        await gate.waitForRequests(3)
        #expect(model.isWorking)
        #expect(await model.removeFromPhotos([galleryPhoto(5)], in: feed) == .failed)
        #expect(model.message == "Still saving the last change. Try again in a moment.")
        for index in 1...3 { await gate.release(index) }
        _ = await first.value
        #expect(feed.photos.map(\.id) == [5])
        #expect(!model.isWorking)
    }

    // MARK: Many tiles at once

    @Test func noMoreThanSixFaceReadsAreInFlightAtOnce() async {
        let grid = (1...12).map { galleryPhoto($0) }
        let gate = GatedTransport { request, _ in
            let path = request.url?.path ?? ""
            let body: String
            if path == "/m/api/people/2" {
                body = peopleJSON(PersonPhotos(id: 2, name: "Alex", total: 12, photos: grid))
            } else if path.hasPrefix("/m/api/photo/"), path.hasSuffix("/faces") {
                let id = Int(path.split(separator: "/")[3]) ?? 0
                body = peopleJSON(FacesWire(faces: [
                    PhotoFace(id: id * 10, box: [0, 0, 1, 1], how: .confirmed, person: PersonRef(id: 2, name: "Alex")),
                ]))
            } else {
                body = peopleJSON(makePerson(2, "Alex", photos: 19))
            }
            return jsonResponse(body, for: request)
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: gate)
        let model = PersonModel(id: 2, person: alex, client: client)
        let feed = FeedModel(
            source: .person(2, name: "Alex"), client: client, settings: InMemoryGallerySettings(bursts: false))
        await gate.release(0)
        await feed.load()
        let task = Task { await model.removeFromPhotos(grid, in: feed) }
        // Request 0 was the grid; the next six are the face reads that may be in flight.
        await gate.waitForRequests(7)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await gate.requests.count == 7, "six reads are out; the other six wait their turn")
        await gate.release(1)
        await gate.waitForRequests(8)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await gate.requests.count == 8, "one finished, so one more went out")
        // The rest, and the write (request 13), go straight through.
        for index in 2...13 { await gate.release(index) }
        let removal = removed(await task.value)
        #expect(removal?.photos == Array(1...12))
        #expect(removal?.faces == (1...12).map { $0 * 10 }, "in the order of the tiles, not of the answers")
        #expect(await gate.requests.count == 14)
        #expect(feed.photos.isEmpty)
    }

    // MARK: Undo

    @Test func undoSendsOneAddWithEveryRemovedFaceAndPutsEveryTileBackInItsPlace() async throws {
        let server = serve(faces: [2: [face(20, 2)], 4: [face(40, 2), face(41, 2)], 5: [face(50, 2)]])
        let (model, feed) = await rig(server)
        let removal = try #require(removed(await model.removeFromPhotos(tiles(2, 4, 5), in: feed)))
        #expect(feed.photos.map(\.id) == [1, 3])
        #expect(await model.undoRemoval(removal, in: feed))
        let adds = server.calls("POST /m/api/people/2/add")
        #expect(adds.count == 1)
        #expect(adds.first?.json["faces"] as? [Int] == [20, 40, 41, 50])
        #expect(adds.first?.json["group"] == nil)
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5], "every tile is back at its index")
        #expect(feed.total == 31)
        #expect(model.person == afterUndo)
        #expect(server.calls("GET /m/api/people/2").count == 1, "no reload needed")
        #expect(model.message.isEmpty && !model.isWorking)
    }

    @Test func undoOfABurstSelectionBringsBackTheTilesAndTheirFrames() async throws {
        let server = serve(
            faces: [3: [face(30, 2)], 4: [face(40, 2)], 6: [face(60, 2)], 7: [], 9: []], day: burstDay)
        let (model, feed) = await rig(server, bursts: true)
        let removal = try #require(removed(await model.removeFromPhotos(tiles(3, 4), in: feed)))
        #expect(feed.photos.map(\.id) == [1, 2, 5])
        #expect(await model.undoRemoval(removal, in: feed))
        #expect(server.calls("POST /m/api/people/2/add").first?.json["faces"] as? [Int] == [30, 60, 40])
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5])
        #expect(feed.total == 31)
    }

    @Test func undoAfterTheGridWasLoadedAgainLoadsItAgainInsteadOfGuessingWhereTheTilesWere() async throws {
        let server = serve(faces: [2: [face(20, 2)], 3: [face(30, 2)]])
        let (model, feed) = await rig(server)
        let removal = try #require(removed(await model.removeFromPhotos(tiles(2, 3), in: feed)))
        await feed.setBursts(true)   // the grid is read again, as the server has it by now
        #expect(server.calls("GET /m/api/people/2").count == 2)
        #expect(await model.undoRemoval(removal, in: feed))
        #expect(server.calls("GET /m/api/people/2").count == 3, "loaded once more")
        #expect(server.calls("POST /m/api/people/2/add").count == 1)
        #expect(feed.photos.map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test func aFailedUndoPutsNothingBackAndSaysWhy() async throws {
        let server = serve(faces: [2: [face(20, 2)], 3: [face(30, 2)]])
        let (model, feed) = await rig(server)
        let removal = try #require(removed(await model.removeFromPhotos(tiles(2, 3), in: feed)))
        server.reply("POST /m/api/people/2/add", #"{"error":"busy"}"#, status: 503)
        #expect(await model.undoRemoval(removal, in: feed) == false)
        #expect(feed.photos.map(\.id) == [1, 4, 5])
        #expect(model.person == afterRemoval)
        #expect(model.message == "Couldn’t save that: busy")
    }
}
