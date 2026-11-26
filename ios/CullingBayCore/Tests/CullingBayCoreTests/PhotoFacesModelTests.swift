import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Photo faces model")
struct PhotoFacesModelTests {
    private let named = PhotoFace(id: 1, box: [0.1, 0.1, 0.3, 0.4], how: .confirmed, person: PersonRef(id: 2, name: "Alex"))
    private let suspected = PhotoFace(id: 2, box: [0.5, 0.1, 0.7, 0.4], how: .unnamed, suggestion: PersonRef(id: 1, name: "Sam Lee"))
    private let stranger = PhotoFace(id: 3, box: [0.8, 0.1, 0.9, 0.3], how: .unnamed)

    private func faces(_ list: [PhotoFace]) -> String { peopleJSON(["faces": list]) }

    private func serve(_ list: [PhotoFace]? = nil) -> PeopleServer {
        let server = PeopleServer()
        server.reply("GET /m/api/photo/43203/faces", faces(list ?? [named, suspected, stranger]))
        return server
    }

    private func makeModel(_ server: PeopleServer) -> PhotoFacesModel {
        PhotoFacesModel(photoID: 43203, client: server.client())
    }

    // MARK: Reading

    @Test func loadingListsTheFacesLeftToRight() async {
        let model = makeModel(serve())
        #expect(model.phase == .idle)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.faces.map(\.id) == [1, 2, 3])
    }

    @Test func eachFaceIsLabelledWithItsPersonItsSuspicionOrUnnamed() {
        #expect(PhotoFacesModel.label(for: named) == "Alex")
        #expect(PhotoFacesModel.label(for: suspected) == "Sam Lee?")
        #expect(PhotoFacesModel.label(for: stranger) == "Unnamed")
    }

    @Test func aPhotoWithNoFacesIsLoadedAndEmpty() async {
        let model = makeModel(serve([]))
        await model.load()
        #expect(model.phase == .loaded && model.faces.isEmpty)
    }

    @Test func anUnknownPhotoIsFailed() async {
        let server = PeopleServer()
        server.reply("GET /m/api/photo/43203/faces", #"{"error":"not found"}"#, status: 404)
        let model = makeModel(server)
        await model.load()
        #expect(model.phase == .failed("That isn’t in the library any more."))
    }

    @Test func aFailedReloadKeepsTheFacesAndSaysWhy() async {
        let server = serve()
        let model = makeModel(server)
        await model.load()
        server.reply("GET /m/api/photo/43203/faces", #"{"error":"busy"}"#, status: 503)
        await model.load()
        #expect(model.faces.count == 3 && model.phase == .loaded)
        #expect(model.message == "Couldn’t load the faces: busy")
    }

    // MARK: Fixing faces

    @Test func notAlexRemovesTheFaceFromThemAndReloads() async {
        let server = serve()
        server.reply("POST /m/api/faces", peopleJSON(makePerson(2, "Alex")))
        let model = makeModel(server)
        await model.load()
        server.reply("GET /m/api/photo/43203/faces", faces([PhotoFace(id: 1, box: named.box, how: .unnamed), suspected, stranger]))
        #expect(await model.notThem(named))
        let body = server.calls("POST /m/api/faces").first?.json
        #expect(body?["action"] as? String == "not")
        #expect(body?["person"] as? Int == 2)
        #expect(body?["faces"] as? [Int] == [1])
        #expect(server.calls("GET /m/api/photo/43203/faces").count == 2)
        #expect(model.faces[0].person == nil, "the sheet shows what the server now says")
    }

    @Test func notAlexOnAnUnnamedFaceDoesNothing() async {
        let server = serve()
        let model = makeModel(server)
        await model.load()
        #expect(await model.notThem(stranger) == false)
        #expect(server.calls("POST /m/api/faces").isEmpty)
    }

    @Test func thisIsMovesTheFaceToThePerson() async {
        let server = serve()
        server.reply("POST /m/api/faces", peopleJSON(makePerson(1, "Sam Lee")))
        let model = makeModel(server)
        await model.load()
        #expect(await model.isThis(stranger, person: makePerson(1, "Sam Lee")))
        let body = server.calls("POST /m/api/faces").first?.json
        #expect(body?["action"] as? String == "move")
        #expect(body?["person"] as? Int == 1)
        #expect(body?["faces"] as? [Int] == [3])
    }

    @Test func thisIsANewPersonCreatesThemFromTheFace() async {
        let server = serve()
        let created = makePerson(9, "Jo", photos: 1, faces: 1)
        server.on("POST /m/api/people") { _, _ in Reply(status: 201, body: peopleJSON(created)) }
        let model = makeModel(server)
        await model.load()
        #expect(await model.isThisNew(stranger, named: " Jo ") == .saved(created))
        let body = server.calls("POST /m/api/people").first?.json
        #expect(body?["name"] as? String == "Jo")
        #expect(body?["faces"] as? [Int] == [3])
        #expect(server.calls("GET /m/api/photo/43203/faces").count == 2)
    }

    @Test func aTakenNameOffersThePersonAndChangesNothing() async {
        let server = serve()
        let alex = makePerson(2, "Alex")
        server.on("POST /m/api/people") { _, _ in nameTakenReply(alex) }
        let model = makeModel(server)
        await model.load()
        #expect(await model.isThisNew(stranger, named: "alex") == .taken(alex))
        #expect(server.calls("GET /m/api/photo/43203/faces").count == 1, "no reload: nothing changed")
        #expect(model.message.isEmpty && !model.isWorking)
    }

    @Test func aBadNameIsRefusedWithoutAskingTheServer() async {
        let server = serve()
        let model = makeModel(server)
        await model.load()
        #expect(await model.isThisNew(stranger, named: "") == .failed)
        #expect(model.message == "A name needs 1 to 80 characters.")
        #expect(server.calls("POST /m/api/people").isEmpty)
    }

    @Test func yesItsSamAnswersTheSuggestionThroughReview() async {
        let server = serve()
        server.reply("POST /m/api/people/1/review", peopleJSON(makePerson(1, "Sam Lee")))
        let model = makeModel(server)
        await model.load()
        #expect(await model.confirmSuggestion(suspected))
        let body = server.calls("POST /m/api/people/1/review").first?.json
        #expect(body?["yes"] as? [Int] == [2])
        #expect(body?["no"] as? [Int] == [])
        #expect(await model.confirmSuggestion(stranger) == false, "no suggestion, nothing to confirm")
    }

    @Test func notAFaceHidesItAndReloads() async {
        let server = serve()
        server.reply("POST /m/api/faces", #"{"ok":true}"#)
        let model = makeModel(server)
        await model.load()
        server.reply("GET /m/api/photo/43203/faces", faces([named, suspected]))
        #expect(await model.notAFace(stranger))
        let body = server.calls("POST /m/api/faces").first?.json
        #expect(body?["action"] as? String == "ignore")
        #expect(body?["faces"] as? [Int] == [3])
        #expect(model.faces.map(\.id) == [1, 2])
    }

    @Test func aFailedWriteSaysWhyAndDoesNotReload() async {
        let server = serve()
        server.reply("POST /m/api/faces", #"{"error":"no such face"}"#, status: 404)
        let model = makeModel(server)
        await model.load()
        #expect(await model.notAFace(stranger) == false)
        #expect(model.message == "That person or face isn’t there any more.")
        #expect(server.calls("GET /m/api/photo/43203/faces").count == 1)
        #expect(!model.isWorking)
    }

    @Test func offlineTheWriteSaysTheServerCannotBeReached() async {
        let stranger = stranger
        let model = PhotoFacesModel(photoID: 43203, client: CullingBayClient(
            baseURL: testBaseURL, transport: FakeTransport { request, _ in
                if request.httpMethod == "POST" { throw CullingBayError.transport(ServerLink.unreachableMessage) }
                return jsonResponse(peopleJSON(["faces": [stranger]]), for: request)
            }))
        await model.load()
        #expect(await model.notAFace(stranger) == false)
        #expect(model.message == "Can’t reach the photo server. Is the PC on and in Ubuntu?")
    }
}
