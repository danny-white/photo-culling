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

    private func makeModel(_ server: PeopleServer, onDecline: (@MainActor (Int) -> Void)? = nil) -> ReviewModel {
        ReviewModel(person: alex, client: server.client(), onDecline: onDecline)
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
        server.reply("GET /m/api/people/2/suggestions", batch([501], groups: [makeGroup(1, maybe: maybe), makeGroup(9, maybe: maybe)]))
        server.reply("POST /m/api/people/2/add", peopleJSON(makePerson(2, "Alex", photos: 80, suggestions: 5)))
        let model = makeModel(server)
        await model.load()
        await model.answer(group: model.groups[0], yes: true)
        #expect(server.calls("POST /m/api/people/2/add").first?.json["group"] as? Int == 1)
        #expect(model.groups.map(\.key) == [9])
        #expect(model.person.photos == 80)
        #expect(model.phase == .reviewing)
    }

    @Test func noToAGroupMarksItsCoverNotThemAndTellsTheList() async {
        let server = PeopleServer()
        let maybe = PersonRef(id: 2, name: "Alex")
        server.reply("GET /m/api/people/2/suggestions", batch([], groups: [makeGroup(1, cover: 777, maybe: maybe)]))
        server.reply("POST /m/api/faces", peopleJSON(makePerson(2, "Alex", suggestions: 0)))
        let declined = Recorder()
        let model = makeModel(server, onDecline: { declined.keys.append($0) })
        await model.load()
        #expect(model.phase == .reviewing, "a group alone is something to review")
        await model.answer(group: model.groups[0], yes: false)
        let body = server.calls("POST /m/api/faces").first?.json
        #expect(body?["action"] as? String == "not" && body?["person"] as? Int == 2)
        #expect(body?["faces"] as? [Int] == [777])
        #expect(declined.keys == [1])
        #expect(model.groups.isEmpty)
        #expect(model.phase == .done, "nothing is left")
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
