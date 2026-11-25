import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@Suite("Practice: models, client and strings")
struct PracticeModelsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Decoding

    @Test func decodesTheSampleChallenge() throws {
        let c = try decode(PracticeChallenge.self, practiceSampleJSON)
        #expect(c.id == "xmas-cat-2024-12-24")
        #expect(c.title == "Cat under the tree")
        #expect(c.mode == "phone")
        #expect(c.level == .hard)
        #expect(c.minutes == 12)
        #expect(c.tools == ["One Subject mask", "Color (Temp, Tint, Mix)"])
        #expect(c.aim == "Make the cat the brightest thing.")
        #expect(c.why == "One subject, mixed light.")
        #expect(c.hints == ["Start with the mask."])
        #expect(c.pickedBy == "Claude")
        #expect(c.added == "2026-11-21")
        #expect(c.photo.id == 43203 && c.photo.raw && c.photo.bytes == 43_100_672)
        #expect(c.status == .todo)
        #expect(c.note == "")
        #expect(c.updatedAt == nil && c.downloadedAt == nil && c.doneAt == nil)
        #expect(!c.wasDownloaded)
    }

    @Test func decodesAChallengeThatHasMovedOn() throws {
        let json = practiceJSON(
            "a", status: "done", note: "Warm", downloadedAt: "2026-11-21T09:00:00",
            doneAt: "2026-11-21T10:00:00")
        let c = try decode(PracticeChallenge.self, json)
        #expect(c.status == .done && c.note == "Warm")
        #expect(c.downloadedAt == "2026-11-21T09:00:00" && c.wasDownloaded)
        #expect(c.doneAt == "2026-11-21T10:00:00")
    }

    @Test func absentHintsDecodeAsEmpty() throws {
        let c = try decode(PracticeChallenge.self, practiceJSON("a", hints: nil))
        #expect(c.hints.isEmpty)
        let none = try decode(PracticeChallenge.self, practiceJSON("a", hints: []))
        #expect(none.hints.isEmpty)
    }

    @Test func anOlderServerLeavesOutTheNeedsDesktopFields() throws {
        let c = try decode(PracticeChallenge.self, practiceSampleJSON)
        #expect(!c.needsDesktop)
        #expect(c.desktopReason == nil && c.companionOf == nil && c.companions.isEmpty)
        let list = try decode(PracticeList.self, practiceListJSON([practiceJSON("a"), practiceJSON("b")]))
        #expect(list.challenges.allSatisfy { !$0.needsDesktop && $0.companions.isEmpty })
    }

    @Test func decodesANeedsDesktopChallengeAndItsCompanion() throws {
        let parent = try decode(
            PracticeChallenge.self,
            practiceJSON(
                "aurora", needsDesktop: true, reason: "Uses Enhance › Denoise.", companions: ["aurora-phone"]))
        #expect(parent.needsDesktop)
        #expect(parent.desktopReason == "Uses Enhance › Denoise.")
        #expect(parent.companionOf == nil)
        #expect(parent.companions == ["aurora-phone"])
        let companion = try decode(
            PracticeChallenge.self,
            practiceJSON("aurora-phone", needsDesktop: false, companionOf: "aurora", companions: []))
        #expect(!companion.needsDesktop && companion.desktopReason == nil)
        #expect(companion.companionOf == "aurora" && companion.companions.isEmpty)
    }

    @Test func nullNeedsDesktopFieldsDecodeAsAbsent() throws {
        // The new server always sends the four fields, null where it has nothing.
        let json = practiceSampleJSON.replacingOccurrences(
            of: "\"picked_by\"",
            with: "\"needs_desktop\":false,\"desktop_reason\":null,\"companion_of\":null,\"companions\":[],\"picked_by\"")
        let c = try decode(PracticeChallenge.self, json)
        #expect(!c.needsDesktop && c.desktopReason == nil && c.companionOf == nil && c.companions.isEmpty)
        #expect(c.id == "xmas-cat-2024-12-24" && c.status == .todo)
    }

    @Test func anUnknownStatusOrLevelDoesNotFailTheList() throws {
        let list = try decode(
            PracticeList.self,
            practiceListJSON([
                practiceJSON("a", status: "archived", level: "brutal"),
                practiceJSON("b", status: "skipped", level: "easy"),
            ]))
        #expect(list.challenges.map(\.status) == [.todo, .skipped])
        #expect(list.challenges.map(\.level) == [.medium, .easy])
    }

    @Test func aListCarriesItsMissingCount() throws {
        let list = try decode(PracticeList.self, practiceListJSON([practiceSampleJSON], missing: 2))
        #expect(list.challenges.count == 1 && list.missing == 2 && list.error == nil)
    }

    @Test func aMalformedFileAnswersAnEmptyListWithAnError() throws {
        let list = try decode(
            PracticeList.self, #"{"challenges": [], "error": "practice.json is malformed"}"#)
        #expect(list.challenges.isEmpty)
        #expect(list.missing == nil)
        #expect(list.error == "practice.json is malformed")
    }

    @Test func decodesTheAnswerToAWrite() throws {
        let state = try decode(
            PracticeState.self,
            practiceStateJSON("a", status: "done", note: "Good", downloadedAt: "d", doneAt: "x"))
        #expect(state.ok && state.id == "a" && state.status == .done && state.note == "Good")
        #expect(state.updatedAt == "2026-11-21T10:00:00")
        #expect(state.downloadedAt == "d" && state.doneAt == "x")
        let bare = try decode(PracticeState.self, practiceStateJSON("a", status: "todo"))
        #expect(bare.downloadedAt == nil && bare.doneAt == nil)
    }

    @Test func aStatusEncodesAsItsName() throws {
        let data = try JSONEncoder().encode([PracticeStatus.downloaded])
        #expect(String(decoding: data, as: UTF8.self) == "[\"downloaded\"]")
    }

    // MARK: Client reads

    @Test func practiceIsAPlainGetOfTheList() async throws {
        let transport = fixedTransport(body: practiceListJSON([practiceSampleJSON], missing: 1))
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let list = try await client.practice()
        #expect(list.challenges.count == 1 && list.missing == 1)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "http://100.82.57.4:8000/m/api/practice")
        #expect(request.httpBody == nil)
    }

    @Test func theListRevalidatesByItsETag() async throws {
        let transport = FakeTransport { request, index in
            index == 0
                ? (Data(practiceListJSON([practiceSampleJSON]).utf8), makeResponse(for: request, headers: ["ETag": "\"p1\""]))
                : (Data(), makeResponse(for: request, status: 304))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let first = try await client.practice()
        let second = try await client.practice()
        #expect(first == second)
        #expect(await transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"p1\"")
    }

    // MARK: Client writes

    @Test func updatingSendsAGuardedPostWithBothFields() async throws {
        let transport = fixedTransport(body: practiceStateJSON("test-light", status: "done", note: "Warm"))
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let state = try await client.updatePractice(id: "test-light", status: .done, note: "Warm")
        #expect(state.status == .done && state.note == "Warm")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://100.82.57.4:8000/m/api/practice/test-light")
        #expect(request.value(forHTTPHeaderField: "X-Culling-Bay") == "1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try jsonBody(request)
        #expect(body.count == 2)
        #expect(body["status"] as? String == "done")
        #expect(body["note"] as? String == "Warm")
    }

    @Test func aNilFieldIsLeftOutOfTheBody() async throws {
        let transport = fixedTransport(body: practiceStateJSON("a", status: "downloaded"))
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        _ = try await client.updatePractice(id: "a", status: .downloaded)
        _ = try await client.updatePractice(id: "a", note: "Only a note")
        let requests = await transport.requests
        let statusOnly = try jsonBody(requests[0])
        #expect(Set(statusOnly.keys) == ["status"] && statusOnly["status"] as? String == "downloaded")
        let noteOnly = try jsonBody(requests[1])
        #expect(Set(noteOnly.keys) == ["note"] && noteOnly["note"] as? String == "Only a note")
    }

    @Test func theIDIsPercentEncodedInThePath() async throws {
        let transport = fixedTransport(body: practiceStateJSON("x", status: "todo"))
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        _ = try await client.updatePractice(id: "cat & tree 100%", status: .todo)
        let url = try #require(await transport.requests.first?.url)
        #expect(url.absoluteString == "http://100.82.57.4:8000/m/api/practice/cat%20%26%20tree%20100%25")
    }

    @Test func aRefusedWriteThrowsTheServersMessage() async {
        let transport = fixedTransport(status: 404, body: #"{"error":"unknown practice challenge"}"#)
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        await #expect(throws: CullingBayError.http(status: 404, message: "unknown practice challenge")) {
            try await client.updatePractice(id: "nope", status: .done)
        }
        let bad = fixedTransport(status: 400, body: #"{"error":"body must contain status or note"}"#)
        let other = CullingBayClient(baseURL: testBaseURL, transport: bad)
        await #expect(throws: CullingBayError.http(status: 400, message: "body must contain status or note")) {
            try await other.updatePractice(id: "a")
        }
    }

    @Test func aWriteKeepsTheCachedList() async throws {
        let transport = FakeTransport { request, index in
            if request.httpMethod == "POST" {
                return (Data(practiceStateJSON("a", status: "skipped").utf8), makeResponse(for: request))
            }
            return index == 0
                ? (Data(practiceListJSON([practiceSampleJSON]).utf8), makeResponse(for: request, headers: ["ETag": "\"p1\""]))
                : (Data(), makeResponse(for: request, status: 304))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        _ = try await client.practice()
        _ = try await client.updatePractice(id: "a", status: .skipped)
        _ = try await client.practice()
        #expect(await transport.requests[2].value(forHTTPHeaderField: "If-None-Match") == "\"p1\"")
    }

    // MARK: Strings

    private func challenge(
        level: PracticeLevel = .easy, minutes: Int = 8, photo: Photo = galleryPhoto(1, raw: true),
        doneAt: String? = nil
    ) -> PracticeChallenge {
        PracticeChallenge(
            id: "a", title: "A", level: level, minutes: minutes, photo: photo, doneAt: doneAt)
    }

    @Test func theTimeAndLevelReadAsTheRowShowsThem() {
        #expect(PracticeFormat.minutesText(challenge()) == "~8 min")
        #expect(PracticeFormat.minutesText(challenge(minutes: 12)) == "~12 min")
        #expect([PracticeLevel.easy, .medium, .hard].map(\.title) == ["Easy", "Medium", "Hard"])
    }

    @Test func thePhotoFrameTakesThePicturesOwnShape() {
        #expect(PracticeFormat.photoShape(width: 1200, height: 1800) == 2.0 / 3.0)    // a portrait
        #expect(PracticeFormat.photoShape(width: 1616, height: 1077) > 1.49)
        #expect(PracticeFormat.photoShape(width: 3000, height: 1000) == 3)
        // Until the size is known, or if it is no use: 4:3, as before.
        #expect(PracticeFormat.photoShape(width: 0, height: 0) == 4.0 / 3.0)
        #expect(PracticeFormat.photoShape(width: 1200, height: 0) == 4.0 / 3.0)
    }

    @Test func theSaveButtonNamesTheRawAndItsSize() {
        let raw = galleryPhoto(1, file: "A.ARW", raw: true, bytes: 43_100_672)
        #expect(PracticeFormat.saveTitle(raw) == "Save RAW to Photos · 43 MB")
        #expect(PracticeFormat.shareTitle(raw) == "Share RAW…")
        let jpeg = galleryPhoto(2, file: "B.JPG", bytes: 3_200_000)
        #expect(PracticeFormat.saveTitle(jpeg) == "Save original · 3.2 MB")
        #expect(PracticeFormat.shareTitle(jpeg) == "Share original…")
        #expect(PracticeFormat.saveTitle(galleryPhoto(3, raw: true)) == "Save RAW to Photos")
    }

    @Test func theWhenAndPlaceLineSkipsWhatIsUnknown() {
        let both = galleryPhoto(1, date: "2026-10-17", place: "greenwood, washington, us")
        #expect(PracticeFormat.whenAndPlace(both) == "Sat, Oct 17 2026 · Greenwood")
        #expect(PracticeFormat.whenAndPlace(galleryPhoto(1, date: "2026-10-17")) == "Sat, Oct 17 2026")
        #expect(PracticeFormat.whenAndPlace(galleryPhoto(1, date: nil, place: "seattle, wa")) == "Seattle")
        #expect(PracticeFormat.whenAndPlace(galleryPhoto(1, date: nil)) == "")
    }

    @Test func theDoneLineShowsTheDay() {
        #expect(PracticeFormat.doneLine(challenge(doneAt: "2026-11-21T10:00:00")) == "Done · Sat, Nov 21 2026")
        #expect(PracticeFormat.doneLine(challenge()) == "Done")
        #expect(PracticeFormat.doneLine(challenge(doneAt: "")) == "Done")
    }

    // MARK: Needs Desktop strings

    @Test func theNeedsDesktopWordsAreTheContractsOwn() {
        #expect(PracticeFormat.needsDesktopTag == "Needs Desktop")
        #expect(PracticeFormat.onTheGoLabel == "On the go")
        #expect(PracticeFormat.onTheGoLink == "On the go version ›")
        #expect(PracticeFormat.desktopLink == "Full desktop version ›")
        #expect(PracticeFormat.companionNote == "On the go version of a Needs Desktop challenge.")
    }

    @Test func theCatalogLineNamesTheDayFolderAndTheFile() {
        let photo = Photo(
            id: 9, day: "2024/2024-05-10", date: "2024-05-10", file: "DSC00576.ARW", stars: 0,
            picked: false, rejected: false, raw: true)
        #expect(PracticeFormat.catalogLine(photo) == "It's already in your catalog: 2024/2024-05-10 › DSC00576.ARW.")
        #expect(PracticeFormat.desktopBox(photo)
            == "Do this one on the Mac in Lightroom Classic. It's already in your catalog: 2024/2024-05-10 › DSC00576.ARW.")
    }

    @Test func aCompanionsRowReadsLevelTimeAndIPhone() {
        #expect(PracticeFormat.companionMinutesText(challenge(minutes: 12)) == "~12 min · iPhone")
    }

    @Test func theStatusTagsNameWhereAChallengeStands() {
        func tags(_ status: PracticeStatus) -> [String?] {
            let c = PracticeChallenge(id: "a", title: "A", photo: galleryPhoto(1), status: status)
            return [PracticeFormat.statusTag(c), PracticeFormat.finishedTag(c)]
        }
        #expect(tags(.todo) == [nil, nil])
        #expect(tags(.downloaded) == ["Downloaded", nil])
        #expect(tags(.done) == ["Done", "Done"])
        #expect(tags(.skipped) == ["Skipped", "Skipped"])
    }
}
