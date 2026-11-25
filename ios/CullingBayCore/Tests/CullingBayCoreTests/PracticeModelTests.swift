import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Practice: model")
struct PracticeModelTests {
    private let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    private func make(_ transport: FakeTransport) -> PracticeModel {
        PracticeModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: transport), now: { stamp })
    }

    /// A server whose writes all succeed with this answer.
    private func accepting(
        _ items: [String], status: String, note: String = "", downloadedAt: String? = nil,
        doneAt: String? = nil
    ) -> FakeTransport {
        practiceTransport(list: practiceListJSON(items)) { request in
            let id = request.url?.lastPathComponent ?? ""
            return (200, practiceStateJSON(id, status: status, note: note, downloadedAt: downloadedAt, doneAt: doneAt))
        }
    }

    private func refusing(_ items: [String], status: Int = 500, body: String = #"{"error":"disk full"}"#)
        -> FakeTransport
    {
        practiceTransport(list: practiceListJSON(items)) { _ in (status, body) }
    }

    // MARK: Loading

    @Test func loadingFillsTheListAndMissingCount() async {
        let transport = practiceTransport(list: practiceListJSON([practiceSampleJSON, practiceJSON("b")], missing: 3))
        let model = make(transport)
        #expect(!model.hasLoaded && model.challenges.isEmpty)
        await model.load()
        #expect(model.challenges.map(\.id) == ["xmas-cat-2024-12-24", "b"])
        #expect(model.missing == 3)
        #expect(model.message == "")
        #expect(model.hasLoaded && !model.isLoading)
        #expect(model.challenge(id: "b")?.title == "Title of b")
        #expect(model.challenge(id: "zzz") == nil)
    }

    @Test func theServersErrorBecomesTheMessage() async {
        let model = make(practiceTransport(list: #"{"challenges": [], "error": "practice.json is malformed"}"#))
        await model.load()
        #expect(model.challenges.isEmpty && model.missing == 0)
        #expect(model.message == "practice.json is malformed")
        #expect(model.hasLoaded)
    }

    @Test func aFailedFirstLoadSaysWhyAndHasNotLoaded() async {
        let model = make(FakeTransport { _, _ in throw URLError(.notConnectedToInternet) })
        await model.load()
        #expect(model.message == "Can’t reach the photo server. Is the PC on and in Ubuntu?")
        #expect(!model.hasLoaded && model.challenges.isEmpty && !model.isLoading)
    }

    @Test func aFailedReloadKeepsTheOldList() async {
        let transport = FakeTransport { request, index in
            if index == 0 {
                return (Data(practiceListJSON([practiceJSON("a"), practiceJSON("b")]).utf8), makeResponse(for: request))
            }
            return (Data(#"{"error":"boom"}"#.utf8), makeResponse(for: request, status: 500))
        }
        let model = make(transport)
        await model.load()
        await model.load()
        #expect(model.challenges.map(\.id) == ["a", "b"])
        #expect(model.message == "Couldn’t load the challenges: boom")
        #expect(model.hasLoaded)
    }

    @Test func aGoodReloadClearsTheMessage() async {
        let transport = FakeTransport { request, index in
            index == 0
                ? (Data(#"{"error":"boom"}"#.utf8), makeResponse(for: request, status: 500))
                : (Data(practiceListJSON([practiceJSON("a")]).utf8), makeResponse(for: request))
        }
        let model = make(transport)
        await model.load()
        #expect(!model.message.isEmpty)
        await model.load()
        #expect(model.message == "" && model.challenges.count == 1)
    }

    @Test func anOlderAnswerDoesNotReplaceANewerOne() async {
        let transport = GatedTransport { request, index in
            let items = index == 0 ? [practiceJSON("old")] : [practiceJSON("new")]
            return (Data(practiceListJSON(items).utf8), makeResponse(for: request))
        }
        let model = PracticeModel(client: CullingBayClient(baseURL: testBaseURL, transport: transport))
        let first = Task { await model.load() }
        await transport.waitForRequests(1)
        let second = Task { await model.load() }
        await transport.waitForRequests(2)
        await transport.release(1)
        await second.value
        #expect(model.challenges.map(\.id) == ["new"] && !model.isLoading)
        await transport.release(0)
        await first.value
        #expect(model.challenges.map(\.id) == ["new"])
    }

    // MARK: Grouping

    @Test func challengesGroupByStatusInTheFilesOrder() async {
        let items = [
            practiceJSON("a", status: "done", doneAt: "2026-11-21T10:00:00"), practiceJSON("b", status: "downloaded"),
            practiceJSON("c", status: "skipped"), practiceJSON("d"), practiceJSON("e", status: "done"),
        ]
        let model = make(practiceTransport(list: practiceListJSON(items)))
        await model.load()
        #expect(model.waiting.map(\.id) == ["b", "d"])
        #expect(model.done.map(\.id) == ["a", "e"])
        #expect(model.skipped.map(\.id) == ["c"])
    }

    // MARK: Downloaded

    @Test func markingDownloadedShowsAtOnceThenTakesTheServersAnswer() async throws {
        let transport = accepting(
            [practiceJSON("a")], status: "downloaded", downloadedAt: "2026-11-21T09:30:00")
        let model = make(transport)
        await model.load()
        let task = model.markDownloaded("a")
        // Before the server answers: the local mark.
        #expect(model.challenge(id: "a")?.status == .downloaded)
        #expect(model.challenge(id: "a")?.wasDownloaded == true)
        #expect(model.challenge(id: "a")?.downloadedAt?.count == 19)
        await task.value
        #expect(model.challenge(id: "a")?.downloadedAt == "2026-11-21T09:30:00")
        #expect(model.message == "")
        let post = try #require(await transport.requests.last)
        #expect(post.httpMethod == "POST" && post.url?.path == "/m/api/practice/a")
        let body = try jsonBody(post)
        #expect(Set(body.keys) == ["status"] && body["status"] as? String == "downloaded")
        #expect(!model.isSaving("a"))
    }

    @Test func markingADoneChallengeDownloadedDoesNotMoveItBack() async {
        let item = practiceJSON("a", status: "done", note: "Warm", doneAt: "2026-11-21T10:00:00")
        let transport = accepting([item], status: "done", note: "Warm", downloadedAt: "2026-11-21T11:00:00", doneAt: "2026-11-21T10:00:00")
        let model = make(transport)
        await model.load()
        let task = model.markDownloaded("a")
        #expect(model.challenge(id: "a")?.status == .done)
        #expect(model.challenge(id: "a")?.doneAt == "2026-11-21T10:00:00")
        await task.value
        #expect(model.challenge(id: "a")?.status == .done)
        #expect(model.challenge(id: "a")?.downloadedAt == "2026-11-21T11:00:00")
        #expect(await transport.requests.count == 2)         // the list, then the quiet mark
    }

    @Test func anAlreadyDownloadedChallengeKeepsItsFirstTime() async {
        let item = practiceJSON("a", status: "downloaded", downloadedAt: "2026-11-20T08:00:00")
        let model = make(refusing([item]))
        await model.load()
        await model.markDownloaded("a").value
        #expect(model.challenge(id: "a")?.downloadedAt == "2026-11-20T08:00:00")
    }

    @Test func aFailedDownloadMarkKeepsTheLocalMarkQuietly() async {
        let model = make(refusing([practiceJSON("a")]))
        await model.load()
        await model.markDownloaded("a").value
        #expect(model.challenge(id: "a")?.status == .downloaded)
        #expect(model.challenge(id: "a")?.wasDownloaded == true)
        #expect(model.message == "")
        #expect(!model.isSaving("a"))
    }

    @Test func markingAnUnknownChallengeDoesNothing() async {
        let transport = accepting([practiceJSON("a")], status: "downloaded")
        let model = make(transport)
        await model.load()
        await model.markDownloaded("zzz").value
        #expect(await transport.requests.count == 1)
    }

    // MARK: Status and note

    @Test func markingDoneSendsTheNoteAndTakesTheAnswer() async throws {
        let item = practiceJSON("a", status: "downloaded", downloadedAt: "2026-11-21T09:00:00")
        let transport = accepting(
            [item], status: "done", note: "Warmer", downloadedAt: "2026-11-21T09:00:00", doneAt: "2026-11-21T10:00:00")
        let model = make(transport)
        await model.load()
        model.setDraft("Warmer", for: "a")
        let saved = await model.setStatus(.done, for: "a", note: model.draft(for: "a"))
        #expect(saved)
        let c = try #require(model.challenge(id: "a"))
        #expect(c.status == .done && c.note == "Warmer" && c.doneAt == "2026-11-21T10:00:00")
        #expect(c.updatedAt == "2026-11-21T10:00:00")
        #expect(model.message == "")
        #expect(model.drafts["a"] == nil)
        #expect(model.done.map(\.id) == ["a"] && model.waiting.isEmpty)
        let body = try jsonBody(try #require(await transport.requests.last))
        #expect(body["status"] as? String == "done" && body["note"] as? String == "Warmer")
    }

    @Test func aFailedWriteLeavesTheChallengeAndKeepsTheNote() async {
        let item = practiceJSON("a", status: "downloaded", note: "Old", downloadedAt: "2026-11-21T09:00:00")
        let model = make(refusing([item]))
        await model.load()
        let before = model.challenge(id: "a")
        model.setDraft("A long note I typed", for: "a")
        let saved = await model.setStatus(.done, for: "a", note: "A long note I typed")
        #expect(!saved)
        #expect(model.challenge(id: "a") == before)
        #expect(model.message == "Not saved: disk full. Your note is still here.")
        #expect(model.draft(for: "a") == "A long note I typed")
        #expect(!model.isSaving("a"))
    }

    @Test func aLostConnectionIsAFailedWriteToo() async {
        let transport = FakeTransport { request, _ in
            if request.httpMethod == "GET" {
                return (Data(practiceListJSON([practiceJSON("a")]).utf8), makeResponse(for: request))
            }
            throw CullingBayError.transport("The Internet connection appears to be offline.")
        }
        let model = make(transport)
        await model.load()
        let saved = await model.setStatus(.skipped, for: "a")
        #expect(!saved && model.challenge(id: "a")?.status == .todo)
        #expect(model.message == "Not saved: The Internet connection appears to be offline. Your note is still here.")
    }

    @Test func aGoodWriteClearsAnEarlierMessage() async {
        let transport = FakeTransport { request, index in
            if request.httpMethod == "GET" {
                return (Data(practiceListJSON([practiceJSON("a")]).utf8), makeResponse(for: request))
            }
            return index == 1
                ? (Data(#"{"error":"busy"}"#.utf8), makeResponse(for: request, status: 503))
                : (Data(practiceStateJSON("a", status: "skipped").utf8), makeResponse(for: request))
        }
        let model = make(transport)
        await model.load()
        await model.setStatus(.skipped, for: "a")
        #expect(model.message == "Not saved: busy. Your note is still here.")
        await model.setStatus(.skipped, for: "a")
        #expect(model.message == "" && model.challenge(id: "a")?.status == .skipped)
    }

    @Test func skippingMovesItToSkipped() async {
        let model = make(accepting([practiceJSON("a")], status: "skipped"))
        await model.load()
        await model.setStatus(.skipped, for: "a")
        #expect(model.skipped.map(\.id) == ["a"] && model.waiting.isEmpty)
    }

    @Test func undoGoesBackToDownloadedWhenTheRawWasEverFetched() async throws {
        let item = practiceJSON("a", status: "done", downloadedAt: "2026-11-21T09:00:00", doneAt: "2026-11-21T10:00:00")
        let transport = accepting([item], status: "downloaded", downloadedAt: "2026-11-21T09:00:00")
        let model = make(transport)
        await model.load()
        let moved = await model.moveToWaiting("a")
        #expect(moved)
        #expect(requestedStatus(try #require(await transport.requests.last)) == "downloaded")
        #expect(model.challenge(id: "a")?.status == .downloaded && model.challenge(id: "a")?.doneAt == nil)
        #expect(model.waiting.map(\.id) == ["a"])
    }

    @Test func undoGoesBackToTodoWhenItWasNeverFetched() async throws {
        let transport = accepting([practiceJSON("a", status: "skipped")], status: "todo")
        let model = make(transport)
        await model.load()
        await model.moveToWaiting("a")
        #expect(requestedStatus(try #require(await transport.requests.last)) == "todo")
        #expect(model.challenge(id: "a")?.status == .todo)
    }

    @Test func movingAnUnknownChallengeDoesNothing() async {
        let transport = accepting([practiceJSON("a")], status: "todo")
        let model = make(transport)
        await model.load()
        let moved = await model.moveToWaiting("zzz")
        let sent = await transport.requests.count
        #expect(!moved && sent == 1)
    }

    @Test func savingANoteLeavesTheStatusAlone() async throws {
        let item = practiceJSON("a", status: "done", doneAt: "2026-11-21T10:00:00")
        let transport = accepting([item], status: "done", note: "Edited", doneAt: "2026-11-21T10:00:00")
        let model = make(transport)
        await model.load()
        model.setDraft("Edited", for: "a")
        let saved = await model.saveNote("Edited", for: "a")
        #expect(saved)
        let body = try jsonBody(try #require(await transport.requests.last))
        #expect(Set(body.keys) == ["note"])
        #expect(model.challenge(id: "a")?.note == "Edited" && model.challenge(id: "a")?.status == .done)
        #expect(model.drafts["a"] == nil)
    }

    @Test func aDraftTypedMeanwhileSurvivesASave() async {
        let model = make(accepting([practiceJSON("a")], status: "todo", note: "First"))
        await model.load()
        model.setDraft("First and more", for: "a")
        await model.saveNote("First", for: "a")
        #expect(model.draft(for: "a") == "First and more")
    }

    @Test func theNoteBoxShowsTheDraftElseTheSavedNote() async {
        let model = make(practiceTransport(list: practiceListJSON([practiceJSON("a", note: "Saved")])))
        await model.load()
        #expect(model.draft(for: "a") == "Saved")
        model.setDraft("", for: "a")
        #expect(model.draft(for: "a") == "")
        model.setDraft("Saved", for: "a")                       // back to the saved note: no draft
        #expect(model.drafts["a"] == nil && model.draft(for: "a") == "Saved")
        #expect(model.draft(for: "zzz") == "")
    }

    @Test func aButtonCanWaitWhileItsWriteRuns() async {
        let transport = GatedTransport { request, _ in
            request.httpMethod == "GET"
                ? (Data(practiceListJSON([practiceJSON("a")]).utf8), makeResponse(for: request))
                : (Data(practiceStateJSON("a", status: "skipped").utf8), makeResponse(for: request))
        }
        let model = PracticeModel(client: CullingBayClient(baseURL: testBaseURL, transport: transport))
        await transport.release(0)
        await model.load()
        let write = Task { await model.setStatus(.skipped, for: "a") }
        await transport.waitForRequests(2)
        #expect(model.isSaving("a") && !model.isSaving("b"))
        await transport.release(1)
        _ = await write.value
        #expect(!model.isSaving("a"))
    }

    // MARK: Notes kept between launches

    private func storeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("practice-notes-\(UUID().uuidString)")
    }

    @Test func aTypedNoteIsKeptInTheStoreAndComesBackOnARelaunch() async {
        let store = InMemoryPracticeDraftStore()
        let transport = practiceTransport(list: practiceListJSON([practiceJSON("a")]))
        let first = PracticeModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: transport), now: { stamp }, store: store)
        await first.load()
        first.setDraft("Pushed the shadows", for: "a")
        #expect(store.drafts == ["a": "Pushed the shadows"])

        let second = PracticeModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: transport), now: { stamp }, store: store)
        #expect(second.draft(for: "a") == "Pushed the shadows")      // before the list has loaded
        await second.load()
        #expect(second.draft(for: "a") == "Pushed the shadows")
    }

    @Test func aNoteBackToTheSavedTextOrSavedToTheServerLeavesTheStore() async {
        let store = InMemoryPracticeDraftStore()
        let item = practiceJSON("a", status: "done", doneAt: "2026-11-21T10:00:00")
        let model = PracticeModel(
            client: CullingBayClient(
                baseURL: testBaseURL,
                transport: accepting([item], status: "done", note: "Warmer", doneAt: "2026-11-21T10:00:00")),
            now: { stamp }, store: store)
        await model.load()
        model.setDraft("Warm", for: "a")
        #expect(store.drafts == ["a": "Warm"])
        model.setDraft("", for: "a")                                // the saved note again: no draft
        #expect(store.drafts.isEmpty)
        model.setDraft("Warmer", for: "a")
        #expect(await model.saveNote("Warmer", for: "a"))
        #expect(store.drafts.isEmpty)
    }

    @Test func sendingUnsavedNotesSendsTheNotesOfDoneChallengesOnly() async throws {
        let done = practiceJSON("a", status: "done", doneAt: "2026-11-21T10:00:00")
        let waiting = practiceJSON("b")
        let store = InMemoryPracticeDraftStore(drafts: ["a": "Written offline", "b": "Not marked done yet"])
        let transport = accepting([done, waiting], status: "done", note: "Written offline", doneAt: "2026-11-21T10:00:00")
        let model = PracticeModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: transport), now: { stamp }, store: store)
        await model.load()
        await model.sendUnsavedNotes()
        let writes = await transport.requests.filter { $0.httpMethod != "GET" }
        #expect(writes.count == 1)
        #expect(writes.first?.url?.lastPathComponent == "a")
        #expect(try jsonBody(try #require(writes.first))["note"] as? String == "Written offline")
        #expect(model.challenge(id: "a")?.note == "Written offline")
        #expect(store.drafts == ["b": "Not marked done yet"])
    }

    @Test func aNoteThatCannotBeSentStaysQuietlyForNextTime() async {
        let done = practiceJSON("a", status: "done", doneAt: "2026-11-21T10:00:00")
        let store = InMemoryPracticeDraftStore(drafts: ["a": "Written offline"])
        let model = PracticeModel(
            client: CullingBayClient(baseURL: testBaseURL, transport: refusing([done], status: 503, body: "{}")),
            now: { stamp }, store: store)
        await model.load()
        await model.sendUnsavedNotes()
        #expect(model.message == "")
        #expect(store.drafts == ["a": "Written offline"] && model.draft(for: "a") == "Written offline")
        #expect(!model.isSaving("a"))
    }

    @Test func theFileStoreRoundTripsAndToleratesAMissingOrGarbledFile() throws {
        let directory = storeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePracticeDraftStore(directory: directory)
        #expect(store.load().isEmpty)                                // no file yet
        store.save(["a": "One", "b": "Two\nlines"])
        #expect(FilePracticeDraftStore(directory: directory).load() == ["a": "One", "b": "Two\nlines"])
        store.save([:])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(FilePracticeDraftStore(directory: directory).load().isEmpty)
        try Data(#"{"a": 3}"#.utf8).write(to: store.fileURL)         // the wrong shape is no notes either
        #expect(FilePracticeDraftStore(directory: directory).load().isEmpty)
    }
}
