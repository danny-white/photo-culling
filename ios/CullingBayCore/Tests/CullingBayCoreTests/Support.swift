import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
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

// MARK: Cull fixtures

/// `GET /m/api/day/2026/2026-10-01` trimmed to three stacks (a single, a burst, a bracket) from
/// the real server's response. The decision and Lightroom values on the burst and bracket frames
/// are invented to cover a draft reject with a note, a conflict, a landed outcome, and a pair.
let cullDayJSON = """
{"day":"2026/2026-10-01","folder":"2026-10-01","date":"2026-10-01",
 "summary":"Coastal rock formations and cliffs at dusk.",
 "budget":{"hours":0.19,"per_hour":10,"stacks":5},
 "stacks":[
  {"id":0,"kind":"single","lead":43220,"frames":[
   {"af":[0.5,0.454],"badges":[],"blown_pct":0.0,"caption":"A dark-feathered bird chick rests inside",
    "decision":{"flag":"pick","note":"","outcome":null,"stars":null,"state":"landed"},
    "file":"DSC05036.ARW","id":43220,"lens":"24-70mm F2.8 DG DN | Art 019",
    "lr":{"by":"phone","pick":1,"rating":0,"stars_by":""},"mean_lum":94.4,
    "partner_ids":[],"partners":[],"place":null,"sharpness":383.2}]},
  {"id":1,"kind":"burst","lead":43224,"frames":[
   {"af":[0.5,0.454],"badges":["Softer"],"blown_pct":0.0,"caption":"A dark-feathered bird chick rests inside",
    "decision":{"flag":"reject","stars":null,"note":"Burst reject \\u00b7 kept DSC05038","state":"draft","outcome":null},
    "file":"DSC05037.ARW","id":43207,"lens":"24-70mm F2.8 DG DN | Art 019","lr":null,"mean_lum":95.2,
    "partner_ids":[],"partners":[],"place":null,"sharpness":441.5},
   {"af":[0.5,0.454],"badges":[],"blown_pct":0.0,"caption":"A dark-colored bird sits inside a burrow",
    "decision":{"flag":"pick","stars":4,"note":"","state":"conflict","outcome":"rejected"},
    "file":"DSC05038.ARW","id":43224,"lens":"24-70mm F2.8 DG DN | Art 019",
    "lr":{"pick":-1,"rating":2,"by":"you","stars_by":"phone"},"mean_lum":92.9,
    "partner_ids":[],"partners":[],"place":null,"sharpness":410.1}]},
  {"id":2,"kind":"bracket","lead":43203,"frames":[
   {"af":[0.6875,0.454],"badges":[],"blown_pct":0.0,"caption":"silhouettes of people standing on a clif",
    "decision":null,"file":"DSC05040.ARW","id":43203,"lens":"24-70mm F2.8 DG DN | Art 019","lr":null,
    "mean_lum":102.4,"partner_ids":[],"partners":[],"place":null,"sharpness":241.5},
   {"af":null,"badges":[],"blown_pct":0.0,"caption":"silhouettes of people standing on a clif",
    "decision":{"flag":"pick","stars":null,"note":"","state":"landed","outcome":"your 3 kept"},
    "file":"DSC05041.ARW","id":43214,"lens":"24-70mm F2.8 DG DN | Art 019",
    "lr":{"by":"phone","pick":1,"rating":0,"stars_by":""},"mean_lum":32.0,
    "partner_ids":[99041],"partners":["DSC05041.JPG"],"place":"greenwood, washington, us","sharpness":16.4}]}],
 "progress":{"pass":2,"cursor":1}}
"""

let daySearchJSON = """
{"query":"DSC05040","days":[
 {"day":"2026/2026-10-01","n":2,"ids":[43203,43214],"match_ids":[43203,43214],"why":"2 photos \\u00b7 \\u201csilhouettes\\u201d"},
 {"day":"2025/2025-06-02","n":0,"ids":[],"match_ids":[],"why":"Near Greenwood"}],
 "photos":2,"signals":["words"],"notes":[]}
"""

let dayLikeJSON = """
{"days":[{"day":"2025/2025-06-02","n":5,"ids":[1,2,3,4],"match_ids":[1,2,3,4,5],"why":"5 similar photos"}],
 "photos":5,"signals":["pictures"],"notes":[]}
"""

/// A `Stack` with `kind` and one frame, for tests that vary one value.
func stackJSON(kind: String) -> String {
    """
    {"id":0,"kind":"\(kind)","lead":1,"frames":[{"id":1,"file":"A.ARW","partners":[],"partner_ids":[],
     "sharpness":null,"af":null,"badges":[],"lr":null,"decision":null,"lens":null,"caption":null,
     "blown_pct":null,"mean_lum":null,"place":null}]}
    """
}

/// The JSON object a request carries.
func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}
