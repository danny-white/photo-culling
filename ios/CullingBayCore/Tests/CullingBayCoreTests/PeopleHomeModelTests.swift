import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("People home model")
struct PeopleHomeModelTests {
    private let alex = makePerson(2, "Alex", photos: 31, faces: 38, suggestions: 12)
    private let sam = makePerson(1, "Sam Lee", photos: 4, faces: 5)

    private func makeModel(_ server: PeopleServer) -> PeopleHomeModel {
        PeopleHomeModel(client: server.client())
    }

    private func serve(
        people: [Person]? = nil, groups: [FaceGroup]? = nil, checked: Int = 8609, ok: Int = 43195
    ) -> PeopleServer {
        let server = PeopleServer()
        server.reply(
            "GET /m/api/people",
            peopleListBody(
                people: people ?? [alex, sam],
                groups: groups ?? [
                    makeGroup(1, faces: 1039, photos: 1039, days: 61, maybe: PersonRef(id: 2, name: "Alex")),
                    makeGroup(315, faces: 443, photos: 441, days: 36),
                ], checked: checked, ok: ok))
        return server
    }

    // MARK: Loading

    @Test func loadingReadsThePeopleGroupsAndCoverage() async {
        let model = makeModel(serve())
        #expect(model.phase == .idle)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.people.map(\.name) == ["Alex", "Sam Lee"])
        #expect(model.groups.map(\.key) == [1, 315])
        #expect(model.facesChecked == 8609 && model.photosOK == 43195)
        #expect(model.person(id: 2) == alex)
        #expect(model.person(id: 99) == nil)
        #expect(model.group(key: 315)?.faces == 443)
    }

    @Test func theFirstLoadShowsLoadingAndALaterOneDoesNot() async {
        let gate = GatedTransport { request, _ in jsonResponse(peopleListBody(people: [self.alex]), for: request) }
        let model = PeopleHomeModel(client: CullingBayClient(baseURL: testBaseURL, transport: gate))
        let first = Task { await model.load() }
        await gate.waitForRequests(1)
        #expect(model.phase == .loading)
        await gate.release(0)
        await first.value
        #expect(model.phase == .loaded)
        let second = Task { await model.load() }
        await gate.waitForRequests(2)
        #expect(model.phase == .loaded, "the list stays on screen while it is read again")
        await gate.release(1)
        await second.value
    }

    @Test func aFailureBeforeAnyResultIsFailedWithTheSentence() async {
        let model = PeopleHomeModel(client: CullingBayClient(
            baseURL: testBaseURL, transport: FakeTransport { _, _ in throw URLError(.cannotConnectToHost) }))
        await model.load()
        #expect(model.phase == .failed("Can’t reach the photo server. Is the PC on and in Ubuntu?"))
        #expect(model.emptyMessage == nil)
    }

    @Test func workOfflineSaysSoWhenLoadingFails() async {
        let model = PeopleHomeModel(client: CullingBayClient(
            baseURL: testBaseURL,
            transport: FakeTransport { _, _ in throw CullingBayError.transport(ServerLink.forcedMessage) }))
        await model.load()
        #expect(model.phase == .failed("Work offline is on. Turn it off to load the people."))
    }

    @Test func aFailedRefreshKeepsTheResultAndSaysWhy() async {
        let server = serve()
        let model = makeModel(server)
        await model.load()
        server.reply("GET /m/api/people", #"{"error":"busy"}"#, status: 503)
        await model.refresh()
        #expect(model.phase == .loaded)
        #expect(model.people.count == 2)
        #expect(model.refreshError == "Couldn’t load the people: busy")
        server.reply("GET /m/api/people", peopleListBody(people: [alex]))
        await model.refresh()
        #expect(model.refreshError == nil)
        #expect(model.people.count == 1)
    }

    @Test func aStaleLoadNeverOverwritesANewerOne() async {
        let gate = GatedTransport { request, index in
            jsonResponse(peopleListBody(people: index == 0 ? [self.sam] : [self.alex]), for: request)
        }
        let model = PeopleHomeModel(client: CullingBayClient(baseURL: testBaseURL, transport: gate))
        let first = Task { await model.load() }
        await gate.waitForRequests(1)
        let second = Task { await model.refresh() }
        await gate.waitForRequests(2)
        await gate.release(1)
        await second.value
        await gate.release(0)
        await first.value
        #expect(model.people.map(\.name) == ["Alex"])
    }

    // MARK: Progress and empty states

    @Test func theProgressLineShowsWhileFacesAreStillBeingFound() async {
        let model = makeModel(serve(checked: 8609, ok: 43195))
        #expect(model.progress == nil, "nothing is known before the first load")
        await model.load()
        #expect(model.progress == "Finding faces… 8,609 of 43,195 photos")
        let done = makeModel(serve(checked: 43195, ok: 43195))
        await done.load()
        #expect(done.progress == nil)
    }

    @Test func nobodyNamedYetHintsAtTheGroups() async {
        let model = makeModel(serve(people: []))
        #expect(model.noPeopleHint == nil, "not before the first load")
        await model.load()
        #expect(model.noPeopleHint == "Nobody is named yet. Open a group below and give it a name.")
        #expect(model.emptyMessage == nil)
        let named = makeModel(serve())
        await named.load()
        #expect(named.noPeopleHint == nil)
    }

    @Test func nothingAtAllSaysWhy() async {
        let early = makeModel(serve(people: [], groups: [], checked: 0, ok: 43195))
        await early.load()
        #expect(early.emptyMessage == "No faces yet. They appear here once the PC has looked through the photos.")
        let later = makeModel(serve(people: [], groups: [], checked: 43195, ok: 43195))
        await later.load()
        #expect(later.emptyMessage == "No faces to name right now.")
    }

    // MARK: The name filter

    @Test func theFilterKeepsPeopleWhoseNameHoldsItCaseAside() async {
        let model = makeModel(serve())
        await model.load()
        #expect(!model.isFiltering && model.visiblePeople.count == 2)
        model.filter = "sam"
        #expect(model.isFiltering)
        #expect(model.visiblePeople.map(\.name) == ["Sam Lee"])
        model.filter = " LEE "
        #expect(model.visiblePeople.map(\.name) == ["Sam Lee"])
        model.filter = "   "
        #expect(!model.isFiltering && model.visiblePeople.count == 2)
    }

    @Test func theFilterKeepsGroupsThatLookLikeThatPersonAndHidesTheRest() async {
        let model = makeModel(serve())
        await model.load()
        #expect(model.visibleGroups.count == 2)
        model.filter = "alex"
        #expect(model.visibleGroups.map(\.key) == [1])
        model.filter = "zed"
        #expect(model.visibleGroups.isEmpty && model.visiblePeople.isEmpty)
        #expect(model.emptyMessage == "No one matches “zed”.")
    }
}
