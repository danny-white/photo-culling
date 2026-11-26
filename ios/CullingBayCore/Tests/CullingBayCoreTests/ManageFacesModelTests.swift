import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Manage faces model")
struct ManageFacesModelTests {
    private let alex = makePerson(2, "Alex", photos: 31, faces: 6, cover: 1)

    private nonisolated func page(_ ids: Range<Int>, total: Int, how: FaceHow = .auto) -> String {
        peopleJSON(PersonFaces(total: total, faces: personFaceList(ids, how: how)))
    }

    private func serve(total: Int = 6, ids: Range<Int> = 1..<7) -> PeopleServer {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/faces", page(ids, total: total))
        server.reply("GET /m/api/people", peopleListBody(people: [makePerson(2, "Alex", photos: 20, faces: 4, cover: 1)]))
        return server
    }

    private func makeModel(_ server: PeopleServer) -> ManageFacesModel {
        ManageFacesModel(person: alex, client: server.client())
    }

    /// Loads, starts selecting and selects these faces.
    private func select(_ model: ManageFacesModel, _ ids: [Int]) async {
        await model.load()
        model.beginSelection()
        ids.forEach(model.toggleSelect)
    }

    // MARK: Loading and paging

    @Test func loadingAsksForTheFirstPageOf120() async {
        let server = serve()
        let model = makeModel(server)
        #expect(model.phase == .idle)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.faces.map(\.id) == [1, 2, 3, 4, 5, 6])
        #expect(model.total == 6 && !model.hasMore)
        let call = server.calls("GET /m/api/people/2/faces").first
        #expect(call?.query == "offset=0&limit=120")
    }

    @Test func theNextPageStartsAfterTheFacesTheGridHas() async {
        let server = PeopleServer()
        server.on("GET /m/api/people/2/faces") { call, _ in
            Reply(body: call.query.hasPrefix("offset=0") ? self.page(0..<120, total: 150) : self.page(120..<150, total: 150))
        }
        let model = makeModel(server)
        await model.load()
        #expect(model.hasMore)
        await model.loadMore()
        #expect(model.faces.count == 150 && !model.hasMore)
        let queries = server.calls("GET /m/api/people/2/faces").map(\.query)
        #expect(queries == ["offset=0&limit=120", "offset=120&limit=120"])
        await model.loadMore()
        #expect(server.calls("GET /m/api/people/2/faces").count == 2, "nothing more to ask for")
    }

    @Test func aPageThatRepeatsAFaceAddsItOnce() async {
        let server = PeopleServer()
        server.on("GET /m/api/people/2/faces") { call, _ in
            Reply(body: call.query.hasPrefix("offset=0") ? self.page(1..<4, total: 5) : self.page(3..<6, total: 5))
        }
        let model = makeModel(server)
        await model.load()
        await model.loadMore()
        #expect(model.faces.map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test func aFailedFirstPageIsFailedAndAFailedLaterPageKeepsTheGrid() async {
        let down = ManageFacesModel(person: alex, client: CullingBayClient(
            baseURL: testBaseURL, transport: FakeTransport { _, _ in throw URLError(.timedOut) }))
        await down.load()
        #expect(down.phase == .failed("Can’t reach the photo server. Is the PC on and in Ubuntu?"))

        let server = PeopleServer()
        server.on("GET /m/api/people/2/faces") { call, _ in
            call.query.hasPrefix("offset=0")
                ? Reply(body: self.page(1..<4, total: 5))
                : Reply(status: 503, body: #"{"error":"busy"}"#)
        }
        let model = makeModel(server)
        await model.load()
        await model.loadMore()
        #expect(model.faces.count == 3 && model.phase == .loaded)
        #expect(model.message == "Couldn’t load more faces: busy")
    }

    // MARK: Selecting

    @Test func selectingNeedsSelectMode() async {
        let model = makeModel(serve())
        await model.load()
        model.toggleSelect(2)
        #expect(model.selected.isEmpty)
        model.beginSelection()
        model.toggleSelect(3)
        model.toggleSelect(1)
        model.toggleSelect(2)
        model.toggleSelect(2)
        #expect(model.selected == [1, 3])
        #expect(model.selectedFaces.map(\.id) == [1, 3], "in grid order")
        model.endSelection()
        #expect(!model.isSelecting && model.selected.isEmpty)
    }

    // MARK: Not Alex

    @Test func notAlexSendsTheSelectedFacesAndTheyLeaveTheGrid() async {
        let server = serve()
        server.reply("POST /m/api/faces", peopleJSON(makePerson(2, "Alex", photos: 28, faces: 4, cover: 1)))
        let model = makeModel(server)
        await select(model, [2, 5])
        #expect(model.notTitle == "Not Alex")
        #expect(await model.removeSelected())
        let body = server.calls("POST /m/api/faces").first?.json
        #expect(body?["action"] as? String == "not")
        #expect(body?["person"] as? Int == 2)
        #expect(body?["faces"] as? [Int] == [2, 5])
        #expect(model.faces.map(\.id) == [1, 3, 4, 6])
        #expect(model.total == 4)
        #expect(model.selected.isEmpty && model.isSelecting, "still selecting, nothing picked")
        #expect(model.person.photos == 28 && model.person.faces == 4)
    }

    @Test func aFailedActionKeepsTheFacesAndTheSelection() async {
        let server = serve()
        server.reply("POST /m/api/faces", #"{"error":"busy"}"#, status: 503)
        let model = makeModel(server)
        await select(model, [2])
        #expect(await model.removeSelected() == false)
        #expect(model.faces.count == 6)
        #expect(model.selected == [2])
        #expect(model.message == "Couldn’t save that: busy")
        #expect(!model.isWorking)
    }

    @Test func anActionWithNothingSelectedSendsNothing() async {
        let server = serve()
        let model = makeModel(server)
        await model.load()
        model.beginSelection()
        #expect(await model.removeSelected() == false)
        #expect(await model.ignoreSelected() == false)
        #expect(server.calls("POST /m/api/faces").isEmpty)
    }

    // MARK: Move to…

    @Test func moveToSomeoneSendsMoveAndReadsTheCountsAgain() async {
        let server = serve()
        server.reply("POST /m/api/faces", peopleJSON(makePerson(1, "Sam Lee", photos: 5, faces: 7)))
        let model = makeModel(server)
        await select(model, [3, 4])
        #expect(await model.moveSelected(to: makePerson(1, "Sam Lee")))
        let body = server.calls("POST /m/api/faces").first?.json
        #expect(body?["action"] as? String == "move")
        #expect(body?["person"] as? Int == 1)
        #expect(body?["faces"] as? [Int] == [3, 4])
        #expect(model.faces.map(\.id) == [1, 2, 5, 6])
        #expect(model.person.id == 2, "the answer was about the other person")
        #expect(model.person.photos == 20 && model.person.faces == 4, "this person's counts come from the list")
    }

    @Test func moveToANewPersonCreatesThemFromTheFaces() async {
        let server = serve()
        let created = makePerson(8, "Jo", photos: 1, faces: 2)
        server.on("POST /m/api/people") { _, _ in Reply(status: 201, body: peopleJSON(created)) }
        let model = makeModel(server)
        await select(model, [3, 4])
        #expect(await model.moveSelectedToNew(named: " Jo ") == .saved(created))
        let body = server.calls("POST /m/api/people").first?.json
        #expect(body?["name"] as? String == "Jo")
        #expect(body?["faces"] as? [Int] == [3, 4])
        #expect(body?["group"] == nil)
        #expect(model.faces.map(\.id) == [1, 2, 5, 6])
    }

    @Test func aTakenNewNameOffersTheExistingPersonAndMovesNothing() async {
        let server = serve()
        let sam = makePerson(1, "Sam Lee")
        server.on("POST /m/api/people") { _, _ in nameTakenReply(sam) }
        let model = makeModel(server)
        await select(model, [3])
        #expect(await model.moveSelectedToNew(named: "sam lee") == .taken(sam))
        #expect(model.faces.count == 6 && model.selected == [3])
        #expect(model.message.isEmpty)
    }

    @Test func aBadNewNameIsRefusedWithoutAskingTheServer() async {
        let server = serve()
        let model = makeModel(server)
        await select(model, [3])
        #expect(await model.moveSelectedToNew(named: " ") == .failed)
        #expect(model.message == "A name needs 1 to 80 characters.")
        #expect(server.calls("POST /m/api/people").isEmpty)
    }

    // MARK: Not a face

    @Test func notAFaceIgnoresTheSelectedFaces() async {
        let server = serve()
        server.reply("POST /m/api/faces", #"{"ok":true}"#)
        let model = makeModel(server)
        await select(model, [6])
        #expect(await model.ignoreSelected())
        let body = server.calls("POST /m/api/faces").first?.json
        #expect(body?["action"] as? String == "ignore")
        #expect(body?["person"] == nil)
        #expect(model.faces.map(\.id) == [1, 2, 3, 4, 5])
    }

    // MARK: Cover

    @Test func makeCoverIsForOneFaceAndTheFaceStaysInTheGrid() async {
        let server = serve()
        server.reply("POST /m/api/people/2", peopleJSON(makePerson(2, "Alex", photos: 31, faces: 6, cover: 4)))
        let model = makeModel(server)
        await select(model, [3, 4])
        #expect(!model.canMakeCover)
        #expect(await model.makeCover() == false)
        model.toggleSelect(3)
        #expect(model.canMakeCover)
        #expect(await model.makeCover())
        #expect(server.calls("POST /m/api/people/2").first?.json["cover"] as? Int == 4)
        #expect(model.person.cover == 4)
        #expect(model.faces.count == 6)
    }

    @Test func makeCoverOfOneFaceFromItsMenu() async {
        let server = serve()
        server.reply("POST /m/api/people/2", peopleJSON(makePerson(2, "Alex", cover: 5)))
        let model = makeModel(server)
        await model.load()
        #expect(await model.makeCover(of: 5))
        #expect(model.person.cover == 5)
    }

    @Test func aCoverThatIsNotTheirsSaysSo() async {
        let server = serve()
        server.reply("POST /m/api/people/2", #"{"error":"that face is not theirs"}"#, status: 400)
        let model = makeModel(server)
        await model.load()
        #expect(await model.makeCover(of: 99) == false)
        #expect(model.message == "Couldn’t save that: that face is not theirs")
    }
}
