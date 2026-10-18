import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

/// A transport that holds every request until the test releases it, so a test can answer
/// requests out of order. The handler runs when a request is released.
actor GatedTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private(set) var requests: [URLRequest] = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        if !released.contains(index) {
            await withCheckedContinuation { waiting[index] = $0 }
        }
        return try handler(request, index)
    }

    /// Lets request `index` (zero-based, in arrival order) finish, now or when it arrives.
    func release(_ index: Int) {
        if let continuation = waiting.removeValue(forKey: index) {
            continuation.resume()
        } else {
            released.insert(index)
        }
    }

    /// Returns once `count` requests have arrived.
    func waitForRequests(_ count: Int) async {
        var spins = 0
        while requests.count < count, spins < 5000 {
            spins += 1
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// Polls until `condition` holds (up to about five seconds), for state that settles on another task.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<5000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// A Photo for gallery tests with the fields the screens show.
func galleryPhoto(
    _ id: Int, date: String? = "2026-10-01", ts: Double? = nil, file: String? = nil, raw: Bool = false,
    place: String? = nil, camera: String? = nil, caption: String? = nil, stars: Int = 0,
    bytes: Int? = nil
) -> Photo {
    Photo(
        id: id, day: "2026/2026-10-01", date: date, ts: ts, file: file ?? "IMG_\(id).JPG",
        bytes: bytes, camera: camera, caption: caption, place: place, stars: stars, picked: false,
        rejected: false, raw: raw)
}

/// A Day for grouping tests; only the fields the library uses are set.
func libraryDay(
    _ date: String?, frames: Int = 10, place: String? = nil, thumbs: [Int] = [1, 2, 3],
    folder: String? = nil, summary: String? = nil
) -> Day {
    let name = folder ?? date ?? "unsorted"
    return Day(
        day: (date.map { String($0.prefix(4)) } ?? "misc") + "/" + name, folder: name, date: date,
        frames: frames, stacks: frames, thumbs: thumbs, lastTs: 0, place: place, places: [],
        gpsFrames: 0, summary: summary, decided: 0, sent: 0, landed: 0, conflicts: 0, lrDone: 0,
        finished: false)
}

private func encode<T: Encodable>(_ value: T) -> String {
    String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
}

func daysJSON(_ days: [Day]) -> String {
    "{\"days\":[\(days.map(encode).joined(separator: ","))]}"
}

func photoListBody(
    _ photos: [Photo], total: Int? = nil, notes: [String] = [], signals: [String] = ["words"]
) -> String {
    encode(PhotoList(
        query: nil, total: total ?? photos.count, signals: signals, notes: notes, photos: photos))
}

func galleryDayBody(_ photos: [Photo], date: String? = "2026-10-01", summary: String? = nil) -> String {
    encode(GalleryDay(day: "2026/2026-10-01", date: date, summary: summary, photos: photos))
}

func jsonResponse(_ body: String, for request: URLRequest, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(body.utf8), makeResponse(for: request, status: status))
}

/// Collects what an `ImageDataLoader.Report` is called with.
final class ReportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(url: URL, ms: Double, bytes: Int, timing: ServerTiming?)] = []

    var reports: [(url: URL, ms: Double, bytes: Int, timing: ServerTiming?)] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func record(_ url: URL, _ ms: Double, _ bytes: Int, _ timing: ServerTiming?) {
        lock.lock(); defer { lock.unlock() }
        stored.append((url, ms, bytes, timing))
    }
}
