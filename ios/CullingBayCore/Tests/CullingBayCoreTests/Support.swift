import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CullingBayCore

let testBaseURL = URL(string: "http://100.82.57.4:8000")!

/// A transport that records every request and answers from a closure. The closure gets the
/// zero-based call index, so a test can script "200, then 304".
actor FakeTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        return try handler(request, index)
    }
}

func makeResponse(
    for request: URLRequest, status: Int = 200, headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url ?? testBaseURL, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: headers)!
}

/// A transport that answers every request with the same status, body and headers.
func fixedTransport(
    status: Int = 200, body: String = "{}", headers: [String: String] = [:]
) -> FakeTransport {
    FakeTransport { request, _ in
        (Data(body.utf8), makeResponse(for: request, status: status, headers: headers))
    }
}

struct TestFailure: Error {}

// MARK: JSON fixtures

/// A Day with every optional field present. `last_ts` is a float, as on the real server.
let dayFullJSON = """
{"day":"2026/2026-10-01","folder":"2026-10-01","date":"2026-10-01","frames":120,"stacks":84,
 "thumbs":[43220,43197,43203],"last_ts":1790879999.75,"place":"greenwood, washington, us",
 "places":["greenwood","seattle"],"gps_frames":97,"summary":"Dune walk and sunset",
 "decided":80,"sent":60,"landed":55,"conflicts":2,"lr_done":50,"finished":true,
 "sent_at":"2026-10-02T08:30:00"}
"""

/// A Day with null in every optional field.
let dayNullsJSON = """
{"day":"misc/unsorted","folder":"unsorted","date":null,"frames":3,"stacks":3,"thumbs":[],
 "last_ts":1700000000.0,"place":null,"places":[],"gps_frames":0,"summary":null,
 "decided":0,"sent":0,"landed":0,"conflicts":0,"lr_done":0,"finished":false,"sent_at":null}
"""

let photoFullJSON = """
{"id":43203,"day":"2026/2026-10-01","date":"2026-10-01","ts":1790871550.0,"file":"DSC05040.ARW",
 "bytes":43100672,"camera":"SONY ILCE-7RM3","lens":"24-70mm F2.8 DG DN | Art 019",
 "caption":"silhouettes on a cliff","place":"greenwood, washington, us","stars":3,
 "picked":true,"rejected":false,"raw":true}
"""

/// A Photo with null in every optional field.
let photoNullsJSON = """
{"id":7,"day":"2024/2024-01-01","date":null,"ts":null,"file":"IMG_0001.JPG","bytes":null,
 "camera":null,"lens":null,"caption":null,"place":null,"stars":0,"picked":false,
 "rejected":false,"raw":false}
"""

func makePhoto(
    id: Int = 1, file: String = "DSC00001.ARW", raw: Bool = true, ts: Double? = 1_790_871_364
) -> Photo {
    Photo(
        id: id, day: "2026/2026-10-01", date: "2026-10-01", ts: ts, file: file, stars: 0,
        picked: false, rejected: false, raw: raw)
}

func daysResponseJSON(_ days: [String]) -> String {
    "{\"days\":[\(days.joined(separator: ","))]}"
}

func galleryDayJSON(photos: [String] = [photoFullJSON]) -> String {
    """
    {"day":"2026/2026-10-01","date":"2026-10-01","summary":"A day","photos":[\(photos.joined(separator: ","))]}
    """
}
