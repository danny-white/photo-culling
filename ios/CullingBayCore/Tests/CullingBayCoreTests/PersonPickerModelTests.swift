import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Person picker model")
struct PersonPickerModelTests {
    private let alex = makePerson(2, "Alex", photos: 31)
    private let alexis = makePerson(4, "Alexis Hart", photos: 9)
    private let sam = makePerson(1, "Sam Lee", photos: 4)
    private let max = makePerson(5, "Max Alexander", photos: 2)

    private func makeModel(excluding: Set<Int> = []) -> PersonPickerModel {
        let server = PeopleServer()
        server.reply("GET /m/api/people", peopleListBody(people: [alex, alexis, sam, max]))
        return PersonPickerModel(client: server.client(), excluding: excluding)
    }

    @Test func loadingListsEveryoneMostPhotosFirst() async {
        let model = makeModel()
        #expect(model.phase == .idle)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.everyone.map(\.name) == ["Alex", "Alexis Hart", "Sam Lee", "Max Alexander"])
        #expect(model.matches == model.everyone)
    }

    @Test func peopleLeftOutAreNotAChoice() async {
        let model = makeModel(excluding: [2])
        await model.load()
        #expect(model.everyone.map(\.name) == ["Alexis Hart", "Sam Lee", "Max Alexander"])
    }

    @Test func typingFiltersCaseAsideWithNamesThatStartWithItFirst() async {
        let model = makeModel()
        await model.load()
        model.text = "ALEX"
        #expect(model.matches.map(\.name) == ["Alex", "Alexis Hart", "Max Alexander"])
        model.text = "lee"
        #expect(model.matches.map(\.name) == ["Sam Lee"])
        model.text = "zzz"
        #expect(model.matches.isEmpty)
        model.text = "  "
        #expect(model.matches.count == 4)
    }

    @Test func aNewPersonIsOfferedForANameNobodyHas() async {
        let model = makeModel()
        await model.load()
        #expect(model.newName == nil, "nothing typed")
        model.text = "  Jo "
        #expect(model.newName == "Jo")
        #expect(model.sameName == nil)
        model.text = "Alex"
        #expect(model.newName == nil)
        #expect(model.sameName == alex)
        model.text = "alex"
        #expect(model.sameName == alex, "case does not matter")
        model.text = String(repeating: "x", count: 81)
        #expect(model.newName == nil, "too long to be a name")
    }

    @Test func aLeftOutPersonStillOwnsTheirName() async {
        let model = makeModel(excluding: [2])
        await model.load()
        model.text = "Alex"
        #expect(model.sameName == alex)
        #expect(model.newName == nil)
        #expect(model.matches.map(\.name) == ["Alexis Hart", "Max Alexander"])
    }

    @Test func aFailedLoadSaysWhy() async {
        let model = PersonPickerModel(client: CullingBayClient(
            baseURL: testBaseURL, transport: FakeTransport { _, _ in throw URLError(.cannotFindHost) }))
        await model.load()
        #expect(model.phase == .failed("Can’t reach the photo server. Is the PC on and in Ubuntu?"))
        #expect(model.matches.isEmpty && model.newName == nil)
    }
}
