import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One timing measurement for `POST /m/api/perf`. `type` and `ms` are required by the server.
public struct PerfItem: Codable, Sendable, Hashable {
    public var type: String
    public var ms: Double
    public var name: String?
    public var screen: String?
    public var detail: String?
    public var bytes: Int?
    public var n: Int?
    public var serverMs: Double?
    public var waitMs: Double?
    public var ttfbMs: Double?
    public var dlMs: Double?

    public init(
        type: String, ms: Double, name: String? = nil, screen: String? = nil,
        detail: String? = nil, bytes: Int? = nil, n: Int? = nil, serverMs: Double? = nil,
        waitMs: Double? = nil, ttfbMs: Double? = nil, dlMs: Double? = nil
    ) {
        self.type = type
        self.ms = ms
        self.name = name
        self.screen = screen
        self.detail = detail
        self.bytes = bytes
        self.n = n
        self.serverMs = serverMs
        self.waitMs = waitMs
        self.ttfbMs = ttfbMs
        self.dlMs = dlMs
    }

    enum CodingKeys: String, CodingKey {
        case type, ms, name, screen, detail, bytes, n
        case serverMs = "server_ms"
        case waitMs = "wait_ms"
        case ttfbMs = "ttfb_ms"
        case dlMs = "dl_ms"
    }
}

/// Queues timing items and posts them to the server when asked. No timers: the app calls `flush`.
/// Reporting is best effort and never throws; a batch that fails to send is dropped.
public actor PerfReporter {
    /// Marks beyond this many queued items are dropped.
    public static let queueLimit = 400
    /// Items sent by one `flush`.
    public static let batchLimit = 300

    private let endpoint: URL
    private let transport: any HTTPTransport
    private var queue: [PerfItem] = []

    private struct Body: Encodable {
        let items: [PerfItem]
    }

    public init(client baseURL: URL, transport: any HTTPTransport = URLSessionTransport()) {
        self.endpoint = URLBuilding.url(base: baseURL, path: "/m/api/perf")
        self.transport = transport
    }

    /// Items waiting to be flushed.
    public var pendingCount: Int { queue.count }

    public func mark(_ item: PerfItem) {
        guard queue.count < Self.queueLimit else { return }
        queue.append(item)
    }

    /// Posts up to `batchLimit` queued items. The batch leaves the queue before the request is
    /// made, so a failed request drops it rather than retrying.
    public func flush() async {
        guard !queue.isEmpty else { return }
        let batch = Array(queue.prefix(Self.batchLimit))
        queue.removeFirst(batch.count)

        guard let body = try? JSONEncoder().encode(Body(items: batch)) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Culling-Bay")
        _ = try? await transport.send(request)
    }
}
