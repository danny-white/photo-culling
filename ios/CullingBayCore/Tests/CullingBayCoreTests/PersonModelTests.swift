import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Person model")
struct PersonModelTests {
    private let alex = makePerson(2, "Alex", photos: 31, faces: 38, cover: 412, suggestions: 12)
    private let sam = makePerson(1, "Sam Lee", photos: 4, faces: 5)

    private func serve() -> PeopleServer {
        let server = PeopleServer()
        server.reply("GET /m/api/people", peopleListBody(people: [alex, sam]))
        return server
    }

    private func makeModel(_ server: PeopleServer, person: Person? = nil) -> PersonModel {
        PersonModel(id: 2, person: person, client: server.client())
    }

    // MARK: Header

    @Test func aPersonFromTheListShowsAtOnce() {
        let model = makeModel(serve(), person: alex)
        #expect(model.phase == .loaded)
        #expect(model.name == "Alex")
        #expect(model.photoCaption == "31 photos")
        #expect(model.cover == 412)
    }

    @Test func withNoPersonTheHeaderIsEmptyUntilTheLoadAnswers() async {
        let model = makeModel(serve())
        #expect(model.phase == .idle && model.person == nil && model.name == "")
        #expect(model.reviewBanner == nil)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.person == alex)
    }

    @Test func theReviewBannerCountsSuggestionsAndIsGoneAtZero() {
        #expect(makeModel(serve(), person: alex).reviewBanner == "Review 12 suggestions")
        #expect(makeModel(serve(), person: makePerson(2, suggestions: 1)).reviewBanner == "Review 1 suggestion")
        #expect(makeModel(serve(), person: makePerson(2, suggestions: 0)).reviewBanner == nil)
    }

    @Test func theCheckBannerCountsDoubtsAndIsGoneAtZero() async {
        let server = serve()
        #expect(makeModel(server).checkBanner == nil, "no one on screen yet")
        #expect(makeModel(server, person: alex).checkBanner == nil, "a server with no doubts")
        #expect(makeModel(server, person: makePerson(2, "Alex", doubts: 250)).checkBanner
            == "Maybe not Alex? Check 250 faces")
        #expect(makeModel(server, person: makePerson(2, "Alex", doubts: 1)).checkBanner
            == "Maybe not Alex? Check 1 face")
        let model = makeModel(server, person: makePerson(2, "Alex", doubts: 4))
        model.update(makePerson(2, "Alex", doubts: 0))
        #expect(model.checkBanner == nil, "after the last one is checked")
    }

    // MARK: Loading

    @Test func aPersonWhoIsNotInTheListIsGone() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people", peopleListBody(people: [sam]))
        let model = makeModel(server, person: alex)
        await model.load()
        #expect(model.phase == .failed("That person isn’t in the library any more."))
        #expect(model.person == nil)
    }

    @Test func aFailedLoadWithNoPersonIsFailed() async {
        let model = PersonModel(id: 2, client: CullingBayClient(
            baseURL: testBaseURL, transport: FakeTransport { _, _ in throw URLError(.notConnectedToInternet) }))
        await model.load()
        #expect(model.phase == .failed("Can’t reach the photo server. Is the PC on and in Ubuntu?"))
    }

    @Test func aFailedLoadWithAPersonOnScreenKeepsThemAndSaysWhy() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people", #"{"error":"busy"}"#, status: 503)
        let model = makeModel(server, person: alex)
        await model.load()
        #expect(model.phase == .loaded && model.person == alex)
        #expect(model.message == "Couldn’t load the person: busy")
    }

    @Test func aLoadTakesTheNewCountsFromTheList() async {
        let server = serve()
        let model = makeModel(server, person: makePerson(2, "Alex", photos: 5, suggestions: 0))
        await model.load()
        #expect(model.person?.photos == 31)
        #expect(model.reviewBanner == "Review 12 suggestions")
    }

    @Test func updateTakesTheirNewStateAndIgnoresAnyoneElse() {
        let model = makeModel(serve(), person: alex)
        model.update(makePerson(2, "Alex", photos: 40, faces: 50, suggestions: 0))
        #expect(model.person?.photos == 40 && model.reviewBanner == nil)
        model.update(makePerson(9, "Jo"))
        #expect(model.name == "Alex")
    }

    // MARK: Rename

    @Test func renamingSendsTheTrimmedNameAndShowsTheAnswer() async {
        let server = serve()
        server.on("POST /m/api/people/2") { _, _ in Reply(body: peopleJSON(makePerson(2, "Alexandra", photos: 31))) }
        let model = makeModel(server, person: alex)
        let result = await model.rename(to: "  Alexandra ")
        #expect(result == .saved(makePerson(2, "Alexandra", photos: 31)))
        #expect(model.name == "Alexandra")
        #expect(model.message.isEmpty)
        let body = server.calls("POST /m/api/people/2").first?.json
        #expect(body?["name"] as? String == "Alexandra")
        #expect(body?["cover"] == nil)
    }

    @Test func aTakenNameComesBackWithThePersonWhoHasIt() async {
        let server = serve()
        server.on("POST /m/api/people/2") { _, _ in nameTakenReply(self.sam) }
        let model = makeModel(server, person: alex)
        let result = await model.rename(to: "sam lee")
        #expect(result == .taken(sam))
        #expect(model.name == "Alex", "nothing changed")
        #expect(model.message.isEmpty, "the screen offers a merge instead of an error")
    }

    @Test func aBadNameIsRefusedWithoutAskingTheServer() async {
        let server = serve()
        let model = makeModel(server, person: alex)
        #expect(await model.rename(to: "   ") == .failed)
        #expect(model.message == "A name needs 1 to 80 characters.")
        #expect(await model.rename(to: String(repeating: "x", count: 81)) == .failed)
        #expect(server.calls().isEmpty)
    }

    @Test func renamingToTheSameNameSendsNothing() async {
        let server = serve()
        let model = makeModel(server, person: alex)
        #expect(await model.rename(to: " Alex ") == .saved(alex))
        #expect(server.calls().isEmpty)
    }

    @Test func aFailedRenameSaysWhyAndKeepsTheName() async {
        let server = serve()
        server.reply("POST /m/api/people/2", #"{"error":"no such person"}"#, status: 404)
        let model = makeModel(server, person: alex)
        #expect(await model.rename(to: "Alexandra") == .failed)
        #expect(model.message == "That person or face isn’t there any more.")
        #expect(model.name == "Alex")
        #expect(!model.isWorking)
    }

    // MARK: Merge, delete, cover

    @Test func mergingIntoSomeoneEndsTheScreenWithThem() async {
        let server = serve()
        server.reply("POST /m/api/people/2/merge", peopleJSON(makePerson(1, "Sam Lee", photos: 35, faces: 43)))
        let model = makeModel(server, person: alex)
        #expect(model.ending == nil)
        #expect(await model.merge(into: sam))
        #expect(model.ending == .merged(into: makePerson(1, "Sam Lee", photos: 35, faces: 43)))
        #expect(server.calls("POST /m/api/people/2/merge").first?.json["into"] as? Int == 1)
    }

    @Test func aFailedMergeEndsNothing() async {
        let server = serve()
        server.reply("POST /m/api/people/2/merge", #"{"error":"can't merge a person into themself"}"#, status: 400)
        let model = makeModel(server, person: alex)
        #expect(await model.merge(into: sam) == false)
        #expect(model.ending == nil)
        #expect(model.message == "Couldn’t save that: can't merge a person into themself")
    }

    @Test func removingTheNameDeletesThemAndEndsTheScreen() async {
        let server = serve()
        server.reply("POST /m/api/people/2/delete", #"{"ok":true}"#)
        let model = makeModel(server, person: alex)
        #expect(await model.delete())
        #expect(model.ending == .deleted)
        #expect(server.calls("POST /m/api/people/2/delete").count == 1)
    }

    @Test func aFailedDeleteLeavesThePersonThere() async {
        let server = serve()
        server.reply("POST /m/api/people/2/delete", #"{"error":"busy"}"#, status: 503)
        let model = makeModel(server, person: alex)
        #expect(await model.delete() == false)
        #expect(model.ending == nil && model.person == alex)
        #expect(model.message == "Couldn’t save that: busy")
    }

    @Test func choosingACoverUpdatesThePictureAndNilGoesBack() async {
        let server = serve()
        server.on("POST /m/api/people/2") { call, _ in
            let cover = call.json["cover"] as? Int
            return Reply(body: peopleJSON(makePerson(2, "Alex", photos: 31, cover: cover ?? 412)))
        }
        let model = makeModel(server, person: alex)
        #expect(await model.setCover(face: 901))
        #expect(model.cover == 901)
        #expect(await model.setCover(face: nil))
        #expect(model.cover == 412)
        let bodies = server.calls("POST /m/api/people/2").map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies == [#"{"cover":901}"#, #"{"cover":null}"#])
    }

    @Test func aWriteSayingNothingTooOldClearsTheLastMessage() async {
        let server = serve()
        server.reply("POST /m/api/people/2/delete", #"{"error":"busy"}"#, status: 503)
        let model = makeModel(server, person: alex)
        _ = await model.delete()
        #expect(!model.message.isEmpty)
        server.reply("POST /m/api/people/2/delete", #"{"ok":true}"#)
        _ = await model.delete()
        #expect(model.message.isEmpty)
    }
}
