import Foundation
import Observation

@MainActor
@Observable
public final class ServerSettingsModel {
    public var text: String {
        didSet { status = ""; generation += 1; isChecking = false }
    }
    public private(set) var status = ""
    public private(set) var isChecking = false
    @ObservationIgnored private var generation = 0

    public init(url: URL) { text = url.absoluteString }

    /// HTTP(S) base URL, optionally with a path prefix. Credentials, queries and fragments
    /// are not server addresses. Do not silently turn a mistyped address into a search URL.
    public static func validatedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }),
              var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        parts.scheme = scheme
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }

    public var validURL: URL? { Self.validatedURL(text) }

    public func check(transport: any HTTPTransport = URLSessionTransport()) async {
        guard let url = validURL else {
            status = "Enter an http:// or https:// server address."
            return
        }
        generation += 1
        let mine = generation
        isChecking = true
        status = "Checking…"
        do {
            let days = try await CullingBayClient(baseURL: url, transport: transport).days()
            guard mine == generation else { return }
            status = "Connected · \(GalleryFormat.dayCount(days.count))"
        } catch {
            guard mine == generation else { return }
            status = GalleryMessages.failure(error, loading: "the library")
        }
        isChecking = false
    }
}
