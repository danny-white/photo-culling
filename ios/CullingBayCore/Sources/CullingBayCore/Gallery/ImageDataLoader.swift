import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads pictures with two savings: callers asking for the same URL at once share one
/// request, and finished pictures stay in a memory cache limited by their total size, dropping
/// the least recently used first.
///
/// Cancelling one caller stops that caller only. The request is cancelled when no caller is
/// left waiting.
public actor ImageDataLoader {
    /// Called once for each picture fetched from the network (not for a cache hit) with its URL,
    /// the milliseconds it took, its size in bytes and the server's `Server-Timing`. Build a
    /// `PerfItem` from it with `PerfMarks.fetch`.
    public typealias Report = @Sendable (URL, Double, Int, ServerTiming?) -> Void

    public static let defaultCacheLimit = 150_000_000

    private struct Fetched: Sendable {
        let data: Data
        let ms: Double
        let timing: ServerTiming?
    }

    private struct Flight {
        let id: Int
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Data, any Error>] = [:]
    }

    private let transport: any HTTPTransport
    private let cacheLimit: Int
    private let report: Report?
    private var cache: [URL: Data] = [:]
    private var cacheOrder: [URL] = []          // least recently used first
    private var cacheBytes = 0
    private var flights: [URL: Flight] = [:]
    private var nextFlight = 0

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        cacheLimit: Int = ImageDataLoader.defaultCacheLimit, report: Report? = nil
    ) {
        self.transport = transport
        self.cacheLimit = cacheLimit
        self.report = report
    }

    /// The picture at `url`. A non-2xx answer throws `CullingBayError.http` with the server's
    /// `error` text when it sent one (415 for a file that will not decode).
    public func data(for url: URL) async throws -> Data {
        if let hit = cache[url] {
            touch(url)
            return hit
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                join(url, waiter, continuation)
            }
        } onCancel: {
            Task { await self.leave(url, waiter) }
        }
    }

    // MARK: Inspection (for tests and the app's diagnostics)

    /// Bytes held in the memory cache.
    public var cachedBytes: Int { cacheBytes }
    /// Cached URLs, least recently used first.
    public var cachedURLs: [URL] { cacheOrder }
    /// Callers waiting on a request for `url`.
    public func waiterCount(for url: URL) -> Int { flights[url]?.waiters.count ?? 0 }
    /// Requests in flight.
    public var flightCount: Int { flights.count }

    // MARK: Sharing a request

    private func join(
        _ url: URL, _ waiter: UUID, _ continuation: CheckedContinuation<Data, any Error>
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if flights[url] == nil {
            nextFlight += 1
            let id = nextFlight
            flights[url] = Flight(id: id)
            flights[url]?.task = Task { [transport] in
                let result: Swift.Result<Fetched, any Error>
                do {
                    result = .success(try await Self.download(url, transport))
                } catch {
                    result = .failure(error)
                }
                self.finish(url, flight: id, result)
            }
        }
        flights[url]?.waiters[waiter] = continuation
    }

    /// A waiter's task was cancelled.
    private func leave(_ url: URL, _ waiter: UUID) {
        guard var flight = flights[url], let continuation = flight.waiters.removeValue(forKey: waiter)
        else { return }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task?.cancel()
            flights[url] = nil
        } else {
            flights[url] = flight
        }
    }

    private func finish(_ url: URL, flight id: Int, _ result: Swift.Result<Fetched, any Error>) {
        guard let flight = flights[url], flight.id == id else { return }   // every waiter left
        flights[url] = nil
        switch result {
        case .success(let fetched):
            store(url, fetched.data)
            report?(url, fetched.ms, fetched.data.count, fetched.timing)
            for continuation in flight.waiters.values { continuation.resume(returning: fetched.data) }
        case .failure(let error):
            for continuation in flight.waiters.values { continuation.resume(throwing: error) }
        }
    }

    private static func download(_ url: URL, _ transport: any HTTPTransport) async throws -> Fetched {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let clock = ContinuousClock()
        let start = clock.now
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as CullingBayError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CullingBayError.transport(error.localizedDescription)
        }
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        guard (200..<300).contains(response.statusCode) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw CullingBayError.http(status: response.statusCode, message: body?.error)
        }
        return Fetched(
            data: data, ms: ms,
            timing: ServerTiming.parse(response.value(forHTTPHeaderField: "Server-Timing")))
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    // MARK: Memory cache

    private func touch(_ url: URL) {
        cacheOrder.removeAll { $0 == url }
        cacheOrder.append(url)
    }

    /// A picture larger than the whole limit is not kept.
    private func store(_ url: URL, _ data: Data) {
        guard data.count <= cacheLimit else { return }
        if let old = cache[url] { cacheBytes -= old.count }
        cache[url] = data
        cacheBytes += data.count
        touch(url)
        while cacheBytes > cacheLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) { cacheBytes -= evicted.count }
        }
    }
}
