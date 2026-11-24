import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

/// A folder for a store, made fresh and removed when the test is done.
final class TempRoot: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-test-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func store() -> OfflineStore { OfflineStore(root: url) }
}

/// A Day for the planner. `day` is `2026/<date>`; `unsent` nil leaves the older server's rule
/// (decided minus sent).
func planDay(
    _ date: String, frames: Int = 100, stacks: Int? = nil, decided: Int = 0, sent: Int = 0,
    lrDone: Int = 0, finished: Bool = false, unsent: Int? = nil, thumbs: [Int] = []
) -> Day {
    Day(
        day: "\(date.prefix(4))/\(date)", folder: date, date: date, frames: frames,
        stacks: stacks ?? frames, thumbs: thumbs, lastTs: 0, places: [], gpsFrames: 0,
        decided: decided, sent: sent, landed: 0, conflicts: 0, lrDone: lrDone, finished: finished,
        unsent: unsent)
}

/// The request's query as a dictionary.
func queryItems(_ request: URLRequest) -> [String: String] {
    guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

func getRequest(_ path: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "http://100.82.57.4:8000" + path)!)
    request.httpMethod = "GET"
    return request
}
