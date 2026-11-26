import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@Suite("Client: People routes")
struct PeopleClientTests {
    private func client(
        status: Int = 200, body: String = "{}", headers: [String: String] = [:]
    ) -> (CullingBayClient, FakeTransport) {
        let transport = fixedTransport(status: status, body: body, headers: headers)
        return (CullingBayClient(baseURL: testBaseURL, transport: transport), transport)
    }

    // MARK: Reads

    @Test func peopleGetsTheListAndRevalidatesWithItsETag() async throws {
        let transport = FakeTransport { request, index in
            index == 0
                ? (Data(peopleListJSON.utf8), makeResponse(for: request, headers: ["ETag": "\"p1\""]))
                : (Data(), makeResponse(for: request, status: 304))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let first = try await client.people()
        let second = try await client.people()
        #expect(first == second)
        let requests = await transport.requests
        #expect(requests[0].url?.absoluteString == "http://100.82.57.4:8000/m/api/people")
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].value(forHTTPHeaderField: "X-Culling-Bay") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"p1\"")
    }

    @Test func personPhotosCarriesTheGalleryFlags() async throws {
        let (client, transport) = client(body: personPhotosJSON)
        let loaded = try await client.personPhotos(2, best: true, bursts: false)
        #expect(loaded.total == 31)
        let url = try #require(await transport.requests.first?.url)
        #expect(url.path == "/m/api/people/2")
        #expect(url.query == "best=1&bursts=0")
    }

    @Test func groupPhotosCarriesTheGalleryFlags() async throws {
        let (client, transport) = client(body: groupPhotosJSON)
        let loaded = try await client.groupPhotos(315)
        #expect(loaded.key == 315 && loaded.total == 441)
        let url = try #require(await transport.requests.first?.url)
        #expect(url.path == "/m/api/people/group/315")
        #expect(url.query == "best=0&bursts=1")
    }

    @Test func personFacesPagesWithOffsetAndLimit() async throws {
        let (client, transport) = client(body: personFacesJSON)
        let page = try await client.personFaces(2, offset: 120, limit: 120)
        #expect(page.faces.count == 3)
        let url = try #require(await transport.requests.first?.url)
        #expect(url.path == "/m/api/people/2/faces")
        #expect(url.query == "offset=120&limit=120")
    }

    @Test func suggestionsAndPhotoFacesUseTheirRoutes() async throws {
        let (suggested, transport) = client(body: suggestionsJSON)
        _ = try await suggested.suggestions(for: 2)
        #expect(await transport.requests.first?.url?.path == "/m/api/people/2/suggestions")

        let (faced, transport2) = client(body: photoFacesJSON)
        let found = try await faced.photoFaces(43203)
        #expect(found.count == 3)
        #expect(await transport2.requests.first?.url?.path == "/m/api/photo/43203/faces")
    }

    @Test func anUnknownPhotoIsA404() async throws {
        let (client, _) = client(status: 404, body: #"{"error":"not found"}"#)
        await #expect(throws: CullingBayError.http(status: 404, message: "not found")) {
            try await client.photoFaces(1)
        }
    }

    @Test func aBadLimitIsA400WithTheServersWords() async throws {
        let (client, _) = client(status: 400, body: #"{"error":"limit must be a whole number of 1 or more"}"#)
        await #expect(throws: CullingBayError.http(status: 400, message: "limit must be a whole number of 1 or more")) {
            try await client.personFaces(2, offset: 0, limit: 0)
        }
    }

    @Test func faceURLsAreBuiltLikeImageURLs() {
        let client = CullingBayClient(baseURL: testBaseURL)
        #expect(client.faceURL(id: 10768).absoluteString == "http://100.82.57.4:8000/m/api/face/10768?s=small")
        #expect(client.faceURL(id: 5, size: .large).absoluteString == "http://100.82.57.4:8000/m/api/face/5?s=large")
    }

    // MARK: Writes

    @Test func createPersonNamesAGroupAndAnswersWithThePerson() async throws {
        let created = makePerson(7, "Alex", photos: 3, faces: 3)
        let (client, transport) = client(status: 201, body: peopleJSON(created))
        let person = try await client.createPerson(name: "Alex", group: 315)
        #expect(person == created)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/m/api/people")
        #expect(request.value(forHTTPHeaderField: "X-Culling-Bay") == "1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try jsonBody(request)
        #expect(body["name"] as? String == "Alex")
        #expect(body["group"] as? Int == 315)
        #expect(body["faces"] == nil)
    }

    @Test func createPersonCanNameFacesToo() async throws {
        let (client, transport) = client(status: 201, body: peopleJSON(makePerson(7)))
        _ = try await client.createPerson(name: "Alex", faces: [4, 5])
        let body = try jsonBody(#require(await transport.requests.first))
        #expect(body["faces"] as? [Int] == [4, 5])
        #expect(body["group"] == nil)
    }

    @Test func aTakenNameIsATypedErrorCarryingThePerson() async throws {
        let existing = makePerson(2, "Alex", photos: 31, faces: 38)
        let (client, _) = client(
            status: 409, body: #"{"error":"that name is taken","person":\#(peopleJSON(existing))}"#)
        await #expect(throws: PersonNameTaken(existing: existing, message: "that name is taken")) {
            try await client.createPerson(name: "alex", group: 1)
        }
        await #expect(throws: PersonNameTaken.self) {
            try await client.renamePerson(9, to: "alex")
        }
    }

    @Test func a409WithNoPersonIsStillAConflict() async throws {
        let (client, _) = client(status: 409, body: #"{"error":"that name is taken"}"#)
        await #expect(throws: CullingBayError.conflict(message: "that name is taken", applied: nil)) {
            try await client.createPerson(name: "Alex", group: 1)
        }
    }

    @Test func renameSendsOnlyTheName() async throws {
        let (client, transport) = client(body: peopleJSON(makePerson(2, "Alexandra")))
        let person = try await client.renamePerson(2, to: "Alexandra")
        #expect(person.name == "Alexandra")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/m/api/people/2")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == #"{"name":"Alexandra"}"#)
    }

    @Test func aCoverIsAFaceIdAndGoingBackToTheBestIsAnExplicitNull() async throws {
        let (client, transport) = client(body: peopleJSON(makePerson(2)))
        _ = try await client.setCover(2, face: 901)
        _ = try await client.setCover(2, face: nil)
        let bodies = await transport.requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        #expect(bodies == [#"{"cover":901}"#, #"{"cover":null}"#])
    }

    @Test func addMergeAndReviewSendTheirBodies() async throws {
        let (client, transport) = client(body: peopleJSON(makePerson(2)))
        _ = try await client.addFaces(to: 2, group: 315)
        _ = try await client.addFaces(to: 2, faces: [8, 9])
        _ = try await client.mergePerson(5, into: 2)
        _ = try await client.reviewSuggestions(2, yes: [1, 2], no: [3])
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == [
            "/m/api/people/2/add", "/m/api/people/2/add", "/m/api/people/5/merge", "/m/api/people/2/review",
        ])
        #expect(try jsonBody(requests[0])["group"] as? Int == 315)
        #expect(try jsonBody(requests[0])["faces"] == nil)
        #expect(try jsonBody(requests[1])["faces"] as? [Int] == [8, 9])
        #expect(try jsonBody(requests[2])["into"] as? Int == 2)
        let review = try jsonBody(requests[3])
        #expect(review["yes"] as? [Int] == [1, 2] && review["no"] as? [Int] == [3])
    }

    @Test func deleteAndHideTakeAnOkAnswer() async throws {
        let (client, transport) = client(body: #"{"ok":true}"#)
        try await client.deletePerson(5)
        try await client.hideGroup(315)
        try await client.ignoreFaces([1, 2])
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == [
            "/m/api/people/5/delete", "/m/api/people/group/315/hide", "/m/api/faces",
        ])
        #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "X-Culling-Bay") == "1" })
        let ignore = try jsonBody(requests[2])
        #expect(ignore["action"] as? String == "ignore")
        #expect(ignore["faces"] as? [Int] == [1, 2])
        #expect(ignore["person"] == nil)
    }

    @Test func notAndMoveSendTheActionAndThePerson() async throws {
        let (client, transport) = client(body: peopleJSON(makePerson(2)))
        let after = try await client.removeFaces([3, 4], from: 2)
        _ = try await client.moveFaces([5], to: 6)
        #expect(after.id == 2)
        let requests = await transport.requests
        let not = try jsonBody(requests[0]), move = try jsonBody(requests[1])
        #expect(not["action"] as? String == "not" && not["person"] as? Int == 2)
        #expect(not["faces"] as? [Int] == [3, 4])
        #expect(move["action"] as? String == "move" && move["person"] as? Int == 6)
        #expect(requests.allSatisfy { $0.url?.path == "/m/api/faces" })
    }

    @Test func aWriteDoesNotDropCachedReads() async throws {
        let transport = FakeTransport { request, index in
            switch (request.httpMethod ?? "GET", index) {
            case ("GET", 0): (Data(peopleListJSON.utf8), makeResponse(for: request, headers: ["ETag": "\"p1\""]))
            case ("POST", _): (Data(peopleJSON(makePerson(2)).utf8), makeResponse(for: request))
            default: (Data(), makeResponse(for: request, status: 304))
            }
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        _ = try await client.people()
        _ = try await client.renamePerson(2, to: "Alexandra")
        _ = try await client.people()
        #expect(await transport.requests[2].value(forHTTPHeaderField: "If-None-Match") == "\"p1\"")
    }

    @Test func writesFailLikeTheOtherWrites() async throws {
        let (gone, _) = client(status: 404, body: #"{"error":"no such person"}"#)
        await #expect(throws: CullingBayError.http(status: 404, message: "no such person")) {
            try await gone.deletePerson(99)
        }
        let (bad, _) = client(status: 400, body: #"{"error":"name must be 1 to 80 characters"}"#)
        await #expect(throws: CullingBayError.http(status: 400, message: "name must be 1 to 80 characters")) {
            try await bad.renamePerson(2, to: " ")
        }
        let (busy, _) = client(status: 503, body: #"{"error":"busy"}"#)
        await #expect(throws: CullingBayError.unavailable(message: "busy")) {
            try await busy.hideGroup(1)
        }
    }

    @Test func aStatusOkWriteWithABodyOfAnotherShapeIsADecodingError() async throws {
        let (client, _) = client(body: "[]")
        await #expect(throws: CullingBayError.self) {
            try await client.renamePerson(2, to: "Sam")
        }
    }
}
