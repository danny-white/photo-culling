import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import CullingBayCore

// MARK: JSON, as the live server writes it

/// `GET /m/api/people`, trimmed: two people, one group with a "maybe" and one without. The names are
/// invented.
let peopleListJSON = """
{"people":[{"cover":412,"faces":38,"id":2,"name":"Alex","photos":31,"suggestions":12},
           {"cover":97,"faces":5,"id":1,"name":"Sam Lee","photos":4,"suggestions":0}],
 "groups":[{"cover":10768,"days":61,"faces":1039,"key":1,"photos":1039,"maybe":{"id":2,"name":"Alex"}},
           {"cover":14738,"days":36,"faces":443,"key":315,"photos":441}],
 "faces_checked":8609,"photos_ok":43195}
"""

let personPhotosJSON = """
{"id":2,"name":"Alex","total":31,"photos":[\(photoFullJSON)]}
"""

let groupPhotosJSON = """
{"key":315,"total":441,"photos":[\(photoFullJSON)]}
"""

let personFacesJSON = """
{"total":3,"faces":[{"id":901,"photo":43203,"how":"auto"},{"id":902,"photo":43204,"how":"auto"},
                    {"id":77,"photo":43100,"how":"confirmed"}]}
"""

let suggestionsJSON = """
{"faces":[{"id":501,"photo":43210,"sim":0.541},{"id":502,"photo":43211,"sim":0.488}],
 "groups":[{"cover":10768,"days":61,"faces":1039,"key":1,"photos":1039,"maybe":{"id":2,"name":"Alex"}}]}
"""

let photoFacesJSON = """
{"faces":[{"box":[0.30623,0.24415,0.48228,0.60645],"how":"confirmed","id":1,"person":{"id":2,"name":"Alex"}},
          {"box":[0.55,0.2,0.7,0.5],"how":"none","id":2,"suggestion":{"id":1,"name":"Sam Lee"}},
          {"box":[0.8,0.3,0.9,0.4],"how":"none","id":3}]}
"""

// MARK: Fixtures

func makePerson(
    _ id: Int, _ name: String = "Alex", photos: Int = 10, faces: Int = 12, cover: Int? = nil,
    suggestions: Int = 0
) -> Person {
    Person(id: id, name: name, photos: photos, faces: faces, cover: cover ?? id * 100, suggestions: suggestions)
}

func makeGroup(
    _ key: Int, faces: Int = 20, photos: Int = 18, days: Int = 4, cover: Int? = nil, maybe: PersonRef? = nil
) -> FaceGroup {
    FaceGroup(key: key, faces: faces, photos: photos, days: days, cover: cover ?? key + 1, maybe: maybe)
}

func peopleJSON<T: Encodable>(_ value: T) -> String {
    String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
}

func peopleListBody(
    people: [Person] = [], groups: [FaceGroup] = [], checked: Int = 100, ok: Int = 100
) -> String {
    peopleJSON(PeopleList(people: people, groups: groups, facesChecked: checked, photosOK: ok))
}

func personFaceList(_ ids: Range<Int>, how: FaceHow = .auto) -> [PersonFace] {
    ids.map { PersonFace(id: $0, photo: 40_000 + $0, how: how) }
}

// MARK: A fake server for the People routes

/// Answers the People routes and records every request, in order. A route nobody gave a responder
/// answers 404, so a test that asks for something it did not expect fails where it asked.
/// `route` is `"GET /m/api/people"`: the method and the path, no query.
final class PeopleServer: Sendable {
    typealias Responder = @Sendable (RecordedCall, Int) throws -> Reply

    private struct State: Sendable {
        var calls: [RecordedCall] = []
        var responders: [String: Responder] = [:]
        var counts: [String: Int] = [:]
    }

    private let state = Mutex(State())

    /// A route that answers the same every time.
    func reply(_ route: String, _ body: String, status: Int = 200) {
        on(route) { _, _ in Reply(status: status, body: body) }
    }

    func on(_ route: String, _ responder: @escaping Responder) {
        state.withLock { $0.responders[route] = responder }
    }

    /// Every request for this route (or all of them), in order.
    func calls(_ route: String? = nil) -> [RecordedCall] {
        state.withLock { state in
            guard let route else { return state.calls }
            return state.calls.filter { $0.method + " " + $0.path == route }
        }
    }

    func transport() -> FakeTransport {
        FakeTransport { [self] request, _ in try respond(request) }
    }

    func client() -> CullingBayClient {
        CullingBayClient(baseURL: testBaseURL, transport: transport())
    }

    private func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let key = method + " " + path
        let call = RecordedCall(
            method: method, path: path, body: request.httpBody ?? Data(),
            query: request.url?.query ?? "", timeout: request.timeoutInterval)
        let (responder, count) = state.withLock { state in
            state.calls.append(call)
            let count = state.counts[key, default: 0]
            state.counts[key] = count + 1
            return (state.responders[key], count)
        }
        let reply = try responder?(call, count) ?? Reply(status: 404, body: #"{"error":"no route"}"#)
        return (Data(reply.body.utf8), makeResponse(for: request, status: reply.status))
    }
}

/// The 409 a taken name gets: the error and the person who has it.
func nameTakenReply(_ existing: Person) -> Reply {
    Reply(status: 409, body: #"{"error":"that name is taken","person":\#(peopleJSON(existing))}"#)
}
