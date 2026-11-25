import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

/// The sample challenge from `review/API.md`, with the photo the gallery returns.
let practiceSampleJSON = """
{"id":"xmas-cat-2024-12-24","title":"Cat under the tree","mode":"phone","level":"hard","minutes":12,
 "tools":["One Subject mask","Color (Temp, Tint, Mix)"],"aim":"Make the cat the brightest thing.",
 "why":"One subject, mixed light.","hints":["Start with the mask."],"picked_by":"Claude",
 "added":"2026-11-21","photo":\(photoFullJSON),"status":"todo","note":"","updated_at":null,
 "downloaded_at":null,"done_at":null}
"""

private func quoted(_ text: String?) -> String {
    text.map { "\"\($0)\"" } ?? "null"
}

/// A challenge as the server returns it. `hints: nil` leaves the key out, as an old file can; so does
/// each of the Needs Desktop fields (`needsDesktop`, `reason`, `companionOf`, `companions`) when
/// nil, as an older server leaves them out. `lightroom` is the JSON of that object, as written; nil
/// leaves the key out, as when nobody has checked.
func practiceJSON(
    _ id: String, status: String = "todo", level: String = "easy", note: String = "",
    downloadedAt: String? = nil, doneAt: String? = nil, hints: [String]? = ["Start with the light."],
    photo: String = photoFullJSON, needsDesktop: Bool? = nil, reason: String? = nil,
    companionOf: String? = nil, companions: [String]? = nil, lightroom: String? = nil
) -> String {
    let hintsPart = hints.map { "\"hints\":[\($0.map { "\"\($0)\"" }.joined(separator: ","))]," } ?? ""
    let desktopPart = [
        needsDesktop.map { "\"needs_desktop\":\($0)," },
        reason.map { "\"desktop_reason\":\"\($0)\"," },
        companionOf.map { "\"companion_of\":\"\($0)\"," },
        companions.map { "\"companions\":[\($0.map { "\"\($0)\"" }.joined(separator: ","))]," },
        lightroom.map { "\"lightroom\":\($0)," },
    ].compactMap { $0 }.joined()
    return """
    {"id":"\(id)","title":"Title of \(id)","mode":"phone","level":"\(level)","minutes":8,
     "tools":["Color › Mix"],"aim":"An aim.","why":"A reason.",\(hintsPart)\(desktopPart)"picked_by":"Claude",
     "added":"2026-11-21","photo":\(photo),"status":"\(status)","note":"\(note)",
     "updated_at":null,"downloaded_at":\(quoted(downloadedAt)),"done_at":\(quoted(doneAt))}
    """
}

func practiceListJSON(_ items: [String], missing: Int = 0) -> String {
    "{\"challenges\":[\(items.joined(separator: ","))],\"missing\":\(missing)}"
}

/// The server's answer to a write.
func practiceStateJSON(
    _ id: String, status: String, note: String = "", downloadedAt: String? = nil, doneAt: String? = nil
) -> String {
    """
    {"ok":true,"id":"\(id)","status":"\(status)","note":"\(note)","updated_at":"2026-11-21T10:00:00",
     "downloaded_at":\(quoted(downloadedAt)),"done_at":\(quoted(doneAt))}
    """
}

/// The status a write asked for, `nil` when its body has none.
func requestedStatus(_ request: URLRequest) -> String? {
    (try? jsonBody(request))?["status"] as? String
}

/// A server for the Practice tab: GETs get `list`, every write goes to `answer`, which returns a
/// status code and a body.
func practiceTransport(
    list: String, answer: @escaping @Sendable (URLRequest) -> (Int, String) = { _ in (500, "{}") }
) -> FakeTransport {
    FakeTransport { request, _ in
        if request.httpMethod == "GET" {
            return (Data(list.utf8), makeResponse(for: request))
        }
        let (status, body) = answer(request)
        return (Data(body.utf8), makeResponse(for: request, status: status))
    }
}
