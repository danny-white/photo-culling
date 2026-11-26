import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Group model")
struct GroupModelTests {
    private let alexRef = PersonRef(id: 2, name: "Alex")
    private var listed: FaceGroup { makeGroup(315, faces: 443, photos: 441, days: 36, cover: 14738, maybe: alexRef) }

    private func serve(groups: [FaceGroup]? = nil) -> PeopleServer {
        let server = PeopleServer()
        server.reply(
            "GET /m/api/people",
            peopleListBody(people: [makePerson(2, "Alex", photos: 31)], groups: groups ?? [listed]))
        return server
    }

    private func makeModel(_ server: PeopleServer, group: FaceGroup? = nil) -> GroupModel {
        GroupModel(key: 315, group: group, client: server.client())
    }

    // MARK: Header

    @Test func aListedGroupShowsItsPictureCountsAndQuestion() {
        let model = makeModel(serve(), group: listed)
        #expect(model.phase == .loaded)
        #expect(model.cover == 14738)
        #expect(model.caption == "441 photos · 36 days")
        #expect(model.maybe == alexRef)
        #expect(model.question == "Is this Alex?")
    }

    @Test func aGroupThePCDoesNotListStillHasItsKeyFacePicture() async {
        let model = makeModel(serve(groups: []))
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.cover == 315, "the key is a face id")
        #expect(model.caption == "")
        #expect(model.question == nil)
    }

    @Test func loadingTakesTheGroupFromTheList() async {
        let model = makeModel(serve())
        #expect(model.phase == .idle)
        await model.load()
        #expect(model.group == listed)
        #expect(model.phase == .loaded)
    }

    @Test func aFailedLoadWithNothingOnScreenIsFailedAndWithAGroupKeepsIt() async {
        let down = CullingBayClient(baseURL: testBaseURL, transport: FakeTransport { _, _ in throw URLError(.timedOut) })
        let empty = GroupModel(key: 315, client: down)
        await empty.load()
        #expect(empty.phase == .failed("Can’t reach the photo server. Is the PC on and in Ubuntu?"))
        let shown = GroupModel(key: 315, group: listed, client: down)
        await shown.load()
        #expect(shown.phase == .loaded && shown.group == listed)
        #expect(shown.message == "Can’t reach the photo server. Is the PC on and in Ubuntu?")
    }

    // MARK: Naming

    @Test func namingCreatesAPersonFromTheGroupAndEndsTheScreen() async {
        let server = serve()
        let created = makePerson(7, "Jo", photos: 441, faces: 443)
        server.on("POST /m/api/people") { _, _ in Reply(status: 201, body: peopleJSON(created)) }
        let model = makeModel(server, group: listed)
        let result = await model.name("  Jo ")
        #expect(result == .saved(created))
        #expect(model.ending == .named(created))
        let body = server.calls("POST /m/api/people").first?.json
        #expect(body?["name"] as? String == "Jo")
        #expect(body?["group"] as? Int == 315)
    }

    @Test func aTakenNameOffersTheExistingPersonAndEndsNothing() async {
        let server = serve()
        let alex = makePerson(2, "Alex", photos: 31)
        server.on("POST /m/api/people") { _, _ in nameTakenReply(alex) }
        let model = makeModel(server, group: listed)
        #expect(await model.name("alex") == .taken(alex))
        #expect(model.ending == nil)
        #expect(model.message.isEmpty)
        #expect(!model.isWorking)
    }

    @Test func aBadNameIsRefusedWithoutAskingTheServer() async {
        let server = serve()
        let model = makeModel(server, group: listed)
        #expect(await model.name("  ") == .failed)
        #expect(model.message == "A name needs 1 to 80 characters.")
        #expect(server.calls().isEmpty)
    }

    @Test func addingToAnExistingPersonSendsTheGroupKey() async {
        let server = serve()
        let after = makePerson(2, "Alex", photos: 472, faces: 481)
        server.reply("POST /m/api/people/2/add", peopleJSON(after))
        let model = makeModel(server, group: listed)
        #expect(await model.add(to: alexRef))
        #expect(model.ending == .named(after))
        let body = server.calls("POST /m/api/people/2/add").first?.json
        #expect(body?["group"] as? Int == 315)
        #expect(body?["faces"] == nil)
    }

    // MARK: Is this Alex?

    @Test func yesAddsTheGroupToThePersonItLooksLike() async {
        let server = serve()
        server.reply("POST /m/api/people/2/add", peopleJSON(makePerson(2, "Alex", photos: 472)))
        let model = makeModel(server, group: listed)
        #expect(await model.confirmMaybe())
        #expect(server.calls("POST /m/api/people/2/add").count == 1)
        if case .named(let person)? = model.ending { #expect(person.id == 2) } else { Issue.record("expected .named") }
    }

    @Test func yesWithNoQuestionDoesNothing() async {
        let server = serve()
        let model = makeModel(server, group: makeGroup(315))
        #expect(await model.confirmMaybe() == false)
        #expect(server.calls().isEmpty)
    }

    @Test func noSendsTheGroupNotThemAndTheServerForgetsTheQuestion() async {
        let server = serve()
        let listed = listed
        // The read after the answer is the list as the server now has it: the group, with no maybe.
        server.reply(
            "GET /m/api/people",
            peopleListBody(people: [makePerson(2, "Alex", photos: 31)], groups: [listed.withoutMaybe()]))
        server.reply("POST /m/api/faces", peopleJSON(makePerson(2, "Alex", photos: 31)))
        let model = makeModel(server, group: listed)
        await model.declineMaybe()
        let body = server.calls("POST /m/api/faces").first?.json
        #expect(body?["group"] as? Int == 315)
        #expect(body?["action"] as? String == "not")
        #expect(body?["person"] as? Int == 2)
        #expect(body?["faces"] == nil, "the group says which faces; the app names none")
        #expect(server.calls("GET /m/api/people").count == 1, "the group is read again")
        #expect(model.maybe == nil && model.question == nil)
        #expect(model.group?.faces == 443, "the rest of the header stays")
        #expect(model.ending == nil && model.message.isEmpty)
    }

    @Test func noThatFailsKeepsTheQuestionAndSaysWhy() async {
        let server = serve()
        server.reply("POST /m/api/faces", #"{"error":"busy"}"#, status: 503)
        let model = makeModel(server, group: listed)
        await model.declineMaybe()
        #expect(model.question == "Is this Alex?")
        #expect(model.message == "Couldn’t save that: busy")
        #expect(server.calls("GET /m/api/people").isEmpty, "nothing changed, so nothing is read again")
    }

    @Test func noWithNoQuestionDoesNothing() async {
        let server = serve()
        let model = makeModel(server, group: makeGroup(315))
        await model.declineMaybe()
        #expect(server.calls().isEmpty)
    }

    // MARK: Hide

    @Test func hidingEndsTheScreen() async {
        let server = serve()
        server.reply("POST /m/api/people/group/315/hide", #"{"ok":true}"#)
        let model = makeModel(server, group: listed)
        #expect(await model.hide())
        #expect(model.ending == .hidden)
    }

    @Test func aFailedHideLeavesTheGroup() async {
        let server = serve()
        server.reply("POST /m/api/people/group/315/hide", #"{"error":"no such group"}"#, status: 404)
        let model = makeModel(server, group: listed)
        #expect(await model.hide() == false)
        #expect(model.ending == nil)
        #expect(model.message == "That person or face isn’t there any more.")
    }
}
