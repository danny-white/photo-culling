import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Puts the days kept on the phone between the app and the real transport, when offline is on.
///
/// - Pictures (`GET /m/api/img/<id>?s=thumb|view`) are **local first**: a picture the store has
///   comes from the phone without touching the network.
/// - The days list and a day (`GET /m/api/days`, `GET /m/api/day/<day>`) are **network first**,
///   with a short timeout. A good answer refreshes the saved copy (the days list always, a day
///   only if it is saved). If the network fails, as opposed to answering with an error, the saved
///   copy is served as a 200 with `X-Culling-Bay-Offline: 1`; with no copy the error is thrown.
/// - Everything else goes straight through: writes, crops, search, the gallery.
///
/// With offline off, every request goes straight through.
public struct OfflineTransport: HTTPTransport {
    /// Set to `1` on an answer that came from the phone because the network failed.
    public static let offlineHeader = "X-Culling-Bay-Offline"
    /// How long the network gets before the saved copy is used, in seconds.
    public static let networkTimeout: TimeInterval = 6

    private let base: any HTTPTransport
    private let store: OfflineStore
    private let isEnabled: @Sendable () -> Bool

    public init(
        base: any HTTPTransport, store: OfflineStore, isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.base = base
        self.store = store
        self.isEnabled = isEnabled
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard isEnabled(), (request.httpMethod ?? "GET") == "GET",
              let url = request.url, let route = Route(url)
        else { return try await base.send(request) }
        switch route {
        case .image(let kind, let id):
            if let data = store.readImage(kind, id: id) {
                return (data, try Self.response(for: request, headers: [
                    "Content-Type": "image/jpeg", "Content-Length": String(data.count),
                ]))
            }
            return try await base.send(request)
        case .days:
            return try await networkFirst(
                request, saved: store.readDays(), keepsCopy: true,
                save: { try? store.writeDays($0) })
        case .day(let day):
            let isSaved = store.isSaved(day)
            return try await networkFirst(
                request, saved: isSaved ? store.readDay(day) : nil, keepsCopy: isSaved,
                save: { data in if store.isSaved(day) { try? store.writeDay(day, data) } })
        }
    }

    // MARK: Network first

    /// `keepsCopy`: this answer is one the store saves. A 304 only keeps the old copy, so with
    /// none to keep the request goes without its `If-None-Match` and gets a body to save.
    private func networkFirst(
        _ request: URLRequest, saved: Data?, keepsCopy: Bool, save: (Data) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = request
        attempt.timeoutInterval = Self.networkTimeout
        if keepsCopy && saved == nil { attempt.setValue(nil, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await base.send(attempt)
            if response.statusCode == 200 && keepsCopy { save(data) }
            return (data, response)
        } catch {
            // A cancelled request is not a lost connection.
            if Task.isCancelled || error is CancellationError { throw error }
            guard let saved else { throw error }
            return (saved, try Self.response(for: request, headers: [
                "Content-Type": "application/json", Self.offlineHeader: "1",
            ]))
        }
    }

    private static func response(for request: URLRequest, headers: [String: String]) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: headers)
        else { throw CullingBayError.transport("Could not read the saved copy.") }
        return response
    }

    // MARK: Routes

    /// The requests the store has a say in. Anything else is not here.
    private enum Route {
        case days
        case day(String)
        case image(OfflineImageKind, Int)

        init?(_ url: URL) {
            let path = url.path
            guard let marker = path.range(of: "/m/api/") else { return nil }
            let rest = path[marker.upperBound...]
            if rest == "days" {
                self = .days
            } else if rest.hasPrefix("img/") {
                guard let id = Int(rest.dropFirst("img/".count)),
                      let size = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                          .queryItems?.first(where: { $0.name == "s" })?.value,
                      let kind = OfflineImageKind(rawValue: size), kind != .af
                else { return nil }
                self = .image(kind, id)
            } else if rest.hasPrefix("day/"), rest.count > "day/".count {
                self = .day(String(rest.dropFirst("day/".count)))
            } else {
                return nil
            }
        }
    }
}
