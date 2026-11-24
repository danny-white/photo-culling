import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches one day into an `OfflineStore`: the day's JSON, then for every frame of every stack its
/// thumbnail, its 1616 px picture and, if asked, its 1:1 crop at the AF point. A few files go at a
/// time and files already in the store are skipped, so a day stopped half way carries on where it
/// was. Give it the real transport, not the `OfflineTransport` over it.
///
/// Pictures are asked for with `warm=0`, so the PC does not start decoding ahead for them, and
/// crops with `keep=0`, which decodes the crop aside and keeps nothing.
///
/// A file the server refuses (a 4xx, such as a frame that will not decode) is left out and the
/// day still completes; retrying would only be refused again. A connection that fails (a
/// `.transport` error) or a 5xx stops the day, which stays unfinished for the next try.
public final class OfflineDownloader: Sendable {
    /// Files fetched at once.
    public static let concurrency = 4
    /// A crop's width and height in source pixels.
    public static let cropSize = 1200

    /// Called as files are finished, with how many are in (those already there included) and how
    /// many the day has.
    public typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    private let baseURL: URL
    private let transport: any HTTPTransport
    private let store: OfflineStore
    private let concurrency: Int

    public init(
        baseURL: URL, transport: any HTTPTransport, store: OfflineStore,
        concurrency: Int = OfflineDownloader.concurrency
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.store = store
        self.concurrency = max(1, concurrency)
    }

    /// One picture to fetch.
    private struct File: Sendable {
        let kind: OfflineImageKind
        let id: Int
        /// Where a crop is centred, as fractions of the frame.
        let center: Point?
    }

    /// Fetches `day` (an entry of the days list, which also names the photos on its row).
    /// Throws `CancellationError` if the task is cancelled, `CullingBayError` for the rest.
    public func download(_ day: Day, includeCrops: Bool, progress: Progress = { _, _ in }) async throws {
        let body = try await get(URLBuilding.url(base: baseURL, path: "/m/api/day/\(day.day)"))
        let cull: CullDay
        do {
            cull = try JSONDecoder().decode(CullDay.self, from: body)
        } catch {
            throw CullingBayError.decoding("The day could not be read: \(error.localizedDescription)")
        }

        var files: [File] = []
        var rowOnly: [Int] = []
        var framesSeen = Set<Int>()
        for stack in cull.stacks {
            for frame in stack.frames where framesSeen.insert(frame.id).inserted {
                files.append(File(kind: .thumb, id: frame.id, center: nil))
                files.append(File(kind: .view, id: frame.id, center: nil))
                if includeCrops { files.append(File(kind: .af, id: frame.id, center: frame.focusSpot)) }
            }
        }
        // The pictures on the day's row in the Days list, if they are not frames of the day.
        for id in day.thumbs where !framesSeen.contains(id) && !rowOnly.contains(id) {
            rowOnly.append(id)
            files.append(File(kind: .thumb, id: id, center: nil))
        }

        try store.begin(day: day.day, frames: day.frames, photos: Array(framesSeen.sorted()) + rowOnly)
        try store.writeDay(day.day, body)

        let missing = files.filter { !store.hasImage($0.kind, id: $0.id) }
        let total = files.count
        var done = total - missing.count
        progress(done, total)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var remaining = missing.makeIterator()
            func startNext(_ group: inout ThrowingTaskGroup<Void, any Error>) {
                guard let file = remaining.next() else { return }
                group.addTask { try await self.fetch(file) }
            }
            for _ in 0..<concurrency { startNext(&group) }
            while try await group.next() != nil {
                done += 1
                progress(done, total)
                startNext(&group)
            }
        }
        try Task.checkCancellation()
        try store.finish(day: day.day)
    }

    // MARK: Files

    private func fetch(_ file: File) async throws {
        let url: URL
        switch file.kind {
        case .thumb, .view:
            url = URLBuilding.url(
                base: baseURL, path: "/m/api/img/\(file.id)",
                query: [("s", file.kind.rawValue), ("warm", "0")])
        case .af:
            let center = file.center ?? Point(x: 0.5, y: 0.5)
            url = URLBuilding.url(
                base: baseURL, path: "/m/api/crop/\(file.id)",
                query: [
                    ("x", URLBuilding.fraction(URLBuilding.clamp(center.x, 0...1))),
                    ("y", URLBuilding.fraction(URLBuilding.clamp(center.y, 0...1))),
                    ("w", String(Self.cropSize)), ("h", String(Self.cropSize)), ("keep", "0"),
                ])
        }
        do {
            let data = try await get(url)
            guard !data.isEmpty else { return }
            // A stopped sync must not write after it was told to stop: it may be followed by a wipe.
            try Task.checkCancellation()
            try store.writeImage(data, kind: file.kind, id: file.id)
        } catch CullingBayError.http(let status, _) where (400..<500).contains(status) {
            return
        }
    }

    /// GETs `url`. Throws `.http` for any status outside 2xx, `.transport` if there was no answer.
    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as CullingBayError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw CullingBayError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CullingBayError.http(status: response.statusCode, message: nil)
        }
        return data
    }
}
