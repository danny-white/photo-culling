import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Review model")
struct ReviewModelTests {
    private let alex = makePerson(2, "Alex", photos: 31, faces: 38, suggestions: 5)

    private nonisolated func batch(_ ids: [Int], groups: [FaceGroup] = []) -> String {
        peopleJSON(PersonSuggestions(
            faces: ids.map { FaceSuggestion(id: $0, photo: 40_000 + $0, sim: 0.5) }, groups: groups))
    }

    private func makeModel(_ server: PeopleServer) -> ReviewModel {
        ReviewModel(person: alex, client: server.client())
    }

    // MARK: Loading

    @Test func aBatchStartsWithEveryFaceAsYes() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/suggestions", batch([501, 502, 503]))
        let model = makeModel(server)
        #expect(model.phase == .loading)
        await model.load()
        #expect(model.phase == .reviewing)
        #expect(model.title == "Is this Alex?")
        #expect(model.faces.map(\.id) == [501, 502, 503])
        #expect(model.yesCount == 3 && model.noCount == 0)
        #expect(model.moreAfterThis == 2, "five suggestions, three shown")
    }

    @Test func nothingToReviewIsDone() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/suggestions", batch([]))
        let model = makeModel(server)
        await model.load()
        #expect(model.phase == .done)
    }

    @Test func aFailedLoadSaysWhy() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/suggestions", #"{"error":"busy"}"#, status: 503)
        let model = makeModel(server)
        await model.load()
        #expect(model.phase == .failed("Couldn’t load the suggestions: busy"))
    }

    // MARK: Tapping

    @Test func aTapTurnsAFaceIntoNoAndAnotherBackIntoYes() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/suggestions", batch([501, 502, 503]))
        let model = makeModel(server)
        await model.load()
        model.toggle(502)
        #expect(model.isNo(502) && !model.isNo(501))
        #expect(model.yesCount == 2 && model.noCount == 1)
        model.toggle(502)
        #expect(!model.isNo(502) && model.noCount == 0)
        model.toggle(999)
        #expect(model.noCount == 0, "a face that is not in the batch is ignored")
    }

    // MARK: None are Alex

    @Test func markAllNoTurnsEveryFaceOfTheBatchIntoNoAndSendsNothing() async {
        let server = PeopleServer()
        let maybe = PersonRef(id: 2, name: "Alex")
        server.reply("GET /m/api/people/2/suggestions", batch([501, 502, 503], groups: [makeGroup(1, maybe: maybe)]))
        let model = makeModel(server)
        await model.load()
        model.toggle(502)
        model.markAll(no: true)
        #expect(model.faces.map(\.id).allSatisfy(model.isNo))
        #expect(model.yesCount == 0 && model.noCount == 3)
        #expect(model.allNo)
        #expect(model.groups.map(\.key) == [1], "the groups are not part of it")
        #expect(server.calls().allSatisfy { $0.method == "GET" }, "only Confirm sends")
        #expect(server.calls("GET /m/api/people/2/suggestions").count == 1)
        #expect(!model.isWorking && model.message.isEmpty)
    }

    @Test func markAllYesPutsEveryFaceBack() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/suggestions", batch([501, 502, 503]))
        let model = makeModel(server)
        await model.load()
        model.markAll(no: true)
        model.markAll(no: false)
        #expect(model.noCount == 0 && model.yesCount == 3)
        #expect(!model.allNo)
        model.toggle(501)
        model.markAll(no: false)
        #expect(model.noCount == 0, "also from a batch with some taps")
    }

    @Test func allNoIsTrueOnlyWhenTheBatchHasFacesAndEveryOneIsNo() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/suggestions", batch([501, 502, 503]))
        let model = makeModel(server)
        #expect(!model.allNo, "nothing is loaded yet")
        await model.load()
        #expect(!model.allNo)
        model.toggle(501)
        model.toggle(502)
        #expect(!model.allNo, "one face is still yes")
        model.toggle(503)
        #expect(model.allNo, "tapping every face is the same as marking all")
        model.toggle(502)
        #expect(!model.allNo)
    }

    @Test func anEmptyBatchIsNeverAllNo() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/suggestions", batch([], groups: [makeGroup(1, maybe: PersonRef(id: 2, name: "Alex"))]))
        let model = makeModel(server)
        await model.load()
        model.markAll(no: true)
        #expect(!model.allNo)
        #expect(model.noCount == 0)
    }

    @Test func confirmAfterMarkAllNoSendsNoYesAndEveryFaceAsNoInOneReview() async {
        let server = PeopleServer()
        server.on("GET /m/api/people/2/suggestions") { _, count in
            Reply(body: count == 0 ? self.batch([501, 502, 503]) : self.batch([504, 505]))
        }
        server.reply("POST /m/api/people/2/review", peopleJSON(makePerson(2, "Alex", photos: 31, faces: 38, suggestions: 2)))
        let model = makeModel(server)
        await model.load()
        model.markAll(no: true)
        await model.confirm()
        let reviews = server.calls("POST /m/api/people/2/review")
        #expect(reviews.count == 1)
        #expect(reviews.first?.json["yes"] as? [Int] == [])
        #expect(reviews.first?.json["no"] as? [Int] == [501, 502, 503])
        #expect(model.confirmedTotal == 0 && model.removedTotal == 3)
        #expect(model.faces.map(\.id) == [504, 505])
    }

    @Test func theNextBatchAfterAMarkAllStartsAsYes() async {
        let server = PeopleServer()
        server.on("GET /m/api/people/2/suggestions") { _, count in
            Reply(body: count == 0 ? self.batch([501, 502]) : self.batch([503, 504]))
        }
        server.reply("POST /m/api/people/2/review", peopleJSON(makePerson(2, "Alex", suggestions: 2)))
        let model = makeModel(server)
        await model.load()
        model.markAll(no: true)
        await model.confirm()
        #expect(model.noCount == 0 && model.yesCount == 2)
        #expect(!model.allNo)
        #expect(model.faces.map(\.id).contains { model.isNo($0) } == false)
    }

    @Test func aFailedConfirmAfterMarkAllNoKeepsEveryFaceAsNo() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/suggestions", batch([501, 502]))
        server.reply("POST /m/api/people/2/review", #"{"error":"busy"}"#, status: 503)
        let model = makeModel(server)
        await model.load()
        model.markAll(no: true)
        await model.confirm()
        #expect(model.message == "Couldn’t save that: busy")
        #expect(model.allNo && model.faces.map(\.id) == [501, 502])
    }

    // MARK: Confirm

    @Test func confirmSendsOneReviewThenLoadsTheNextBatch() async {
        let server = PeopleServer()
        server.on("GET /m/api/people/2/suggestions") { _, count in
            Reply(body: count == 0 ? self.batch([501, 502, 503]) : self.batch([504, 505]))
        }
        server.reply("POST /m/api/people/2/review", peopleJSON(makePerson(2, "Alex", photos: 33, faces: 40, suggestions: 2)))
        let model = makeModel(server)
        await model.load()
        model.toggle(502)
        await model.confirm()
        let body = server.calls("POST /m/api/people/2/review").first?.json
        #expect(body?["yes"] as? [Int] == [501, 503])
        #expect(body?["no"] as? [Int] == [502])
        #expect(server.calls("POST /m/api/people/2/review").count == 1)
        #expect(model.faces.map(\.id) == [504, 505])
        #expect(model.noCount == 0, "the next batch starts as yes")
        #expect(model.person.suggestions == 2)
        #expect(model.moreAfterThis == 0)
        #expect(model.confirmedTotal == 2 && model.removedTotal == 1)
        #expect(model.phase == .reviewing)
    }

    @Test func confirmingTheLastBatchIsDone() async {
        let server = PeopleServer()
        server.on("GET /m/api/people/2/suggestions") { _, count in
            Reply(body: count == 0 ? self.batch([501]) : self.batch([]))
        }
        server.reply("POST /m/api/people/2/review", peopleJSON(makePerson(2, "Alex", photos: 32, suggestions: 0)))
        let model = makeModel(server)
        await model.load()
        await model.confirm()
        #expect(model.phase == .done)
        #expect(model.confirmedTotal == 1)
    }

    @Test func aFailedConfirmKeepsTheBatchAndTheTaps() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/suggestions", batch([501, 502]))
        server.on("POST /m/api/people/2/review") { _, count in
            count == 0
                ? Reply(status: 503, body: #"{"error":"busy"}"#)
                : Reply(body: peopleJSON(makePerson(2, "Alex", suggestions: 0)))
        }
        let model = makeModel(server)
        await model.load()
        model.toggle(502)
        await model.confirm()
        #expect(model.message == "Couldn’t save that: busy")
        #expect(model.faces.map(\.id) == [501, 502])
        #expect(model.isNo(502))
        #expect(model.confirmedTotal == 0 && !model.isWorking)
        await model.confirm()
        #expect(model.message.isEmpty)
        #expect(model.confirmedTotal == 1 && model.removedTotal == 1)
    }

    @Test func confirmDoesNothingWithNoBatch() async {
        let server = PeopleServer()
        server.reply("GET /m/api/people/2/suggestions", batch([]))
        let model = makeModel(server)
        await model.load()
        await model.confirm()
        #expect(server.calls("POST /m/api/people/2/review").isEmpty)
    }

    // MARK: Groups

    @Test func suggestedGroupsComeWithTheBatch() async {
        let server = PeopleServer()
        let maybe = PersonRef(id: 2, name: "Alex")
        server.reply("GET /m/api/people/2/suggestions", batch([501], groups: [makeGroup(1, maybe: maybe), makeGroup(9, maybe: maybe)]))
        let model = makeModel(server)
        await model.load()
        #expect(model.groups.map(\.key) == [1, 9])
    }

    @Test func yesToAGroupAddsItAndItLeavesTheList() async {
        let server = PeopleServer()
        let maybe = PersonRef(id: 2, name: "Alex")
        server.on("GET /m/api/people/2/suggestions") { _, count in
            Reply(body: self.batch(
                [501], groups: count == 0 ? [makeGroup(1, maybe: maybe), makeGroup(9, maybe: maybe)] : [makeGroup(9, maybe: maybe)]))
        }
        server.reply("POST /m/api/people/2/add", peopleJSON(makePerson(2, "Alex", photos: 80, suggestions: 5)))
        let model = makeModel(server)
        await model.load()
        await model.answer(group: model.groups[0], yes: true)
        #expect(server.calls("POST /m/api/people/2/add").first?.json["group"] as? Int == 1)
        #expect(model.groups.map(\.key) == [9])
        #expect(server.calls("GET /m/api/people/2/suggestions").count == 2, "the groups are read again")
        #expect(model.person.photos == 80)
        #expect(model.phase == .reviewing)
    }

    @Test func noToAGroupSendsTheGroupNotThemAndReadsTheGroupsAgain() async {
        let server = PeopleServer()
        let maybe = PersonRef(id: 2, name: "Alex")
        server.on("GET /m/api/people/2/suggestions") { _, count in
            // After the answer the server no longer says the group may be them.
            Reply(body: self.batch([], groups: count == 0 ? [makeGroup(1, cover: 777, maybe: maybe)] : []))
        }
        server.reply("POST /m/api/faces", peopleJSON(makePerson(2, "Alex", suggestions: 0)))
        let model = makeModel(server)
        await model.load()
        #expect(model.phase == .reviewing, "a group alone is something to review")
        await model.answer(group: model.groups[0], yes: false)
        let body = server.calls("POST /m/api/faces").first?.json
        #expect(body?["group"] as? Int == 1)
        #expect(body?["action"] as? String == "not" && body?["person"] as? Int == 2)
        #expect(body?["faces"] == nil)
        #expect(server.calls("GET /m/api/people/2/suggestions").count == 2, "read again after the answer")
        #expect(model.groups.isEmpty)
        #expect(model.phase == .done, "nothing is left")
    }

    @Test func answeringAGroupKeepsTheTapsOnTheFaces() async {
        let server = PeopleServer()
        let maybe = PersonRef(id: 2, name: "Alex")
        server.reply("GET /m/api/people/2/suggestions", batch([501, 502], groups: [makeGroup(1, maybe: maybe)]))
        server.reply("POST /m/api/faces", peopleJSON(makePerson(2, "Alex", suggestions: 2)))
        let model = makeModel(server)
        await model.load()
        model.toggle(502)
        await model.answer(group: model.groups[0], yes: false)
        #expect(model.isNo(502), "reading the groups again does not start the faces over")
        #expect(model.faces.map(\.id) == [501, 502])
        #expect(model.phase == .reviewing)
    }

    @Test func aFailedGroupAnswerKeepsTheGroup() async {
        let server = PeopleServer()
        let maybe = PersonRef(id: 2, name: "Alex")
        server.reply("GET /m/api/people/2/suggestions", batch([501], groups: [makeGroup(1, maybe: maybe)]))
        server.reply("POST /m/api/people/2/add", #"{"error":"no such group"}"#, status: 404)
        let model = makeModel(server)
        await model.load()
        await model.answer(group: model.groups[0], yes: true)
        #expect(model.groups.count == 1)
        #expect(model.message == "That person or face isn’t there any more.")
    }
}
