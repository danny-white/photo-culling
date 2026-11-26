import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ImageSize: String, Sendable, Hashable, CaseIterable {
    /// 320 px JPEG.
    case thumb
    /// 1616 px JPEG (a RAW's embedded preview).
    case view
    /// 3000 px JPEG decoded from the original; slow for a cold RAW.
    case large
}

/// What to save for a photo. A RAW photo offers both; any other photo only `.picture`.
public enum SaveKind: Sendable, Hashable, CaseIterable {
    /// A full-size JPEG of a RAW, or the original JPEG/HEIC as is.
    case picture
    /// The untouched original RAW file.
    case raw
}

/// A decoded value plus what came with it on the wire.
public struct Fetched<Value: Sendable>: Sendable {
    public let value: Value
    public let serverTiming: ServerTiming?
    /// The server answered 304 and `value` was decoded from the cached body.
    public let notModified: Bool
    /// The PC could not be reached and `value` is the copy saved on the phone
    /// (`OfflineTransport` marks it with `X-Culling-Bay-Offline: 1`).
    public let servedOffline: Bool

    public init(
        value: Value, serverTiming: ServerTiming? = nil, notModified: Bool = false,
        servedOffline: Bool = false
    ) {
        self.value = value
        self.serverTiming = serverTiming
        self.notModified = notModified
        self.servedOffline = servedOffline
    }
}

/// Talks to the Culling Bay Flask server's `/m/api` JSON routes and builds its picture URLs.
public actor CullingBayClient {
    public nonisolated let baseURL: URL
    private let transport: any HTTPTransport
    private var cache: [String: CachedResponse] = [:]
    private var cacheOrder: [String] = []          // oldest first, for the size limit
    /// JSON responses kept for ETag revalidation; the oldest is dropped beyond this.
    public static let maxCachedResponses = 100
    /// Photos' camera details already fetched, so opening the (i) sheet again is instant. In memory
    /// only, and gone with the client when the server changes.
    private var infoCache = PhotoInfoCache()

    private struct CachedResponse {
        let etag: String
        let body: Data
    }

    public init(baseURL: URL, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    // MARK: JSON routes

    public func days() async throws -> [Day] {
        try await fetchDays().value
    }

    /// `days()` with what came on the wire, which says whether the list is the copy saved on the
    /// phone because the PC could not be reached.
    public func fetchDays() async throws -> Fetched<[Day]> {
        let fetched: Fetched<DaysResponse> = try await fetch(path: "/m/api/days")
        return Fetched(
            value: fetched.value.days, serverTiming: fetched.serverTiming,
            notModified: fetched.notModified, servedOffline: fetched.servedOffline)
    }

    public func search(_ q: String, best: Bool = false, bursts: Bool = true) async throws -> PhotoList {
        let fetched: Fetched<PhotoList> = try await fetch(
            path: "/m/api/gallery/search",
            query: [("q", q), ("best", URLBuilding.flag(best)), ("bursts", URLBuilding.flag(bursts))])
        return fetched.value
    }

    public func like(_ id: Int, best: Bool = false, bursts: Bool = true) async throws -> PhotoList {
        let fetched: Fetched<PhotoList> = try await fetch(
            path: "/m/api/gallery/like/\(id)",
            query: [("best", URLBuilding.flag(best)), ("bursts", URLBuilding.flag(bursts))])
        return fetched.value
    }

    /// `day` is the day id such as `2026/2026-10-01`; the slash stays a path separator.
    public func galleryDay(_ day: String, best: Bool = false, bursts: Bool = true) async throws -> GalleryDay {
        let fetched: Fetched<GalleryDay> = try await fetch(
            path: "/m/api/gallery/day/\(day)",
            query: [("best", URLBuilding.flag(best)), ("bursts", URLBuilding.flag(bursts))])
        return fetched.value
    }

    /// GETs a JSON route and decodes it. `path` is raw (unencoded): `/` separates segments and
    /// each segment is percent-encoded. Query values are encoded so that `+`, `&`, `=`, `#`,
    /// spaces and non-ASCII all survive Flask's decoding.
    ///
    /// Responses with an `ETag` are cached in memory by full URL; the next request for the same
    /// URL sends `If-None-Match`, and a 304 is answered from the cached body with
    /// `notModified` set.
    public func fetch<T: Decodable & Sendable>(
        path: String,
        query: [(name: String, value: String)] = []
    ) async throws -> Fetched<T> {
        let url = URLBuilding.url(base: baseURL, path: path, query: query)
        let key = url.absoluteString
        let cached = cache[key]

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cached {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

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

        let timing = ServerTiming.parse(response.value(forHTTPHeaderField: "Server-Timing"))
        let offline = response.value(forHTTPHeaderField: "X-Culling-Bay-Offline") == "1"

        switch response.statusCode {
        case 304:
            guard let cached else {
                throw CullingBayError.http(status: 304, message: "Not modified, but nothing is cached")
            }
            let value: T = try Self.decode(cached.body)
            return Fetched(value: value, serverTiming: timing, notModified: true)
        case 200..<300:
            let value: T = try Self.decode(data)
            if let etag = response.value(forHTTPHeaderField: "ETag") {
                remember(key, CachedResponse(etag: etag, body: data))
            } else {
                cache[key] = nil
                cacheOrder.removeAll { $0 == key }
            }
            return Fetched(value: value, serverTiming: timing, notModified: false, servedOffline: offline)
        default:
            throw CullingBayError.http(status: response.statusCode, message: Self.errorMessage(in: data))
        }
    }

    // MARK: Decode-ahead

    /// Photos one `warm` request may name; the PC takes no more.
    public static let maxWarmIDs = 4
    /// How long the PC gets to answer `warm`, in seconds. It is only a hint, so it fails fast.
    public static let warmTimeout: TimeInterval = 3

    /// Asks the PC to decode these RAWs in the background (`GET /m/api/warm?ids=a,b`, most urgent
    /// first), so a 1:1 check of them does not wait for a cold decode. A card the phone shows from
    /// its own saved copy never asks the PC for its picture, which is what normally starts that
    /// decode. The PC answers 204 with no body; any 2xx counts.
    ///
    /// One try with a 3 s timeout, no retry, no cache and no queue: a failure throws and the caller
    /// forgets it. It goes straight to the PC even with days kept on the phone.
    public func warm(ids: [Int]) async throws {
        let ids = Array(ids.prefix(Self.maxWarmIDs))
        guard !ids.isEmpty else { return }
        var request = URLRequest(url: URLBuilding.url(
            base: baseURL, path: "/m/api/warm",
            query: [("ids", ids.map(String.init).joined(separator: ","))]))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.warmTimeout
        let response: HTTPURLResponse
        do {
            (_, response) = try await transport.send(request)
        } catch let error as CullingBayError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CullingBayError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CullingBayError.http(status: response.statusCode, message: nil)
        }
    }

    // MARK: Camera details

    /// How long the PC gets to answer `info`, in seconds. Reading a RAW's tags can mean waking the NAS.
    public static let infoTimeout: TimeInterval = 10

    /// One photo's camera details (`GET /m/api/info/<id>`), for the (i) sheet. They are read from the
    /// file on the PC, so this always goes there, even with days kept on the phone, and nothing it
    /// answers is saved on the phone. The last 64 answers are kept in memory, so asking again for a
    /// photo is instant; a failure is not kept.
    ///
    /// One try with a 10 s timeout, no URL cache, no retry and nothing in the write queue. A 503
    /// (the photo storage cannot be reached) throws `.unavailable`; a 404 (not in the index) and a
    /// 415 (the file's tags cannot be read) throw `.http` with that status, each with the server's
    /// `error` text.
    public func info(id: Int) async throws -> PhotoInfo {
        if let known = infoCache.value(for: id) { return known }
        var request = URLRequest(url: URLBuilding.url(base: baseURL, path: "/m/api/info/\(id)"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.infoTimeout
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
        switch response.statusCode {
        case 200..<300:
            let info: PhotoInfo = try Self.decode(data)
            infoCache.remember(info, for: id)
            return info
        case 503:
            throw CullingBayError.unavailable(message: Self.errorMessage(in: data))
        default:
            throw CullingBayError.http(status: response.statusCode, message: Self.errorMessage(in: data))
        }
    }

    /// How many photos' details are kept (for tests).
    public var cachedInfoCount: Int { infoCache.count }

    // MARK: Writes

    /// Which cached GETs a successful write makes stale.
    enum Stale: Sendable {
        /// `GET /m/api/day/<day>` for this day.
        case day(String)
        /// `GET /m/api/day/<day>` for every day (a write that doesn't say which day it touched).
        case allDays
        /// No cached read (a write whose reader revalidates by the ETag of its body).
        case nothing
    }

    /// Sends a JSON write (`POST` or `PUT`) with the `X-Culling-Bay` header the server requires.
    /// Writes never use the ETag cache. After a 2xx the cached cull day(s) in `stale` are
    /// dropped, so the next read doesn't offer a tag for a day that has just changed. A 409
    /// becomes `.conflict`, a 503 `.unavailable`, any other non-2xx `.http`, each with the
    /// server's `error` text.
    func writeJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        method: String, path: String, body: Body, staling stale: Stale
    ) async throws -> T {
        var request = URLRequest(url: URLBuilding.url(base: baseURL, path: path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Culling-Bay")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys      // a retry sends the same bytes
            request.httpBody = try encoder.encode(body)
        } catch {
            throw CullingBayError.transport("Could not encode the request: \(error.localizedDescription)")
        }

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

        switch response.statusCode {
        case 200..<300:
            let value: T = try Self.decode(data)
            forget(stale)
            return value
        case 409:
            let details = try? JSONDecoder().decode(WriteErrorBody.self, from: data)
            throw CullingBayError.conflict(message: details?.error, applied: details?.applied)
        case 503:
            throw CullingBayError.unavailable(message: Self.errorMessage(in: data))
        default:
            throw CullingBayError.http(status: response.statusCode, message: Self.errorMessage(in: data))
        }
    }

    private func forget(_ stale: Stale) {
        let keys: [String]
        switch stale {
        case .day(let day):
            keys = [URLBuilding.url(base: baseURL, path: "/m/api/day/\(day)").absoluteString]
        case .allDays:
            let prefix = URLBuilding.url(base: baseURL, path: "/m/api/day").absoluteString + "/"
            keys = cache.keys.filter { $0.hasPrefix(prefix) }
        case .nothing:
            keys = []
        }
        for key in keys {
            cache[key] = nil
            cacheOrder.removeAll { $0 == key }
        }
    }

    private func remember(_ key: String, _ response: CachedResponse) {
        cache[key] = response
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > Self.maxCachedResponses {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    /// How many JSON responses are cached for revalidation (for tests).
    public var cachedResponseCount: Int { cache.count }

    // MARK: URL builders

    public nonisolated func imageURL(id: Int, size: ImageSize) -> URL {
        switch size {
        case .thumb, .view:
            return URLBuilding.url(
                base: baseURL, path: "/m/api/img/\(id)", query: [("s", size.rawValue)])
        case .large:
            return URLBuilding.url(
                base: baseURL, path: "/m/api/export/\(id)", query: [("s", "large")])
        }
    }

    /// A full-resolution crop. `centerX`/`centerY` are fractions of the upright frame (clamped to
    /// 0...1); `width`/`height` are source pixels (clamped to 64...2400 and rounded).
    public nonisolated func cropURL(
        id: Int, centerX: Double, centerY: Double, width: Double, height: Double
    ) -> URL {
        let x = URLBuilding.clamp(centerX, 0...1)
        let y = URLBuilding.clamp(centerY, 0...1)
        let w = Int(URLBuilding.clamp(width, 64...2400).rounded())
        let h = Int(URLBuilding.clamp(height, 64...2400).rounded())
        return URLBuilding.url(
            base: baseURL, path: "/m/api/crop/\(id)",
            query: [
                ("x", URLBuilding.fraction(x)), ("y", URLBuilding.fraction(y)),
                ("w", String(w)), ("h", String(h)),
            ])
    }

    public nonisolated func saveURL(for photo: Photo, kind: SaveKind) -> URL {
        switch kind {
        case .picture:
            return URLBuilding.url(base: baseURL, path: "/m/api/export/\(photo.id)")
        case .raw:
            return URLBuilding.url(
                base: baseURL, path: "/m/api/export/\(photo.id)", query: [("s", "original")])
        }
    }

    // MARK: Decoding

    private struct DaysResponse: Decodable, Sendable {
        let days: [Day]
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    /// A 409 from a write also says how many decisions are already in Lightroom.
    private struct WriteErrorBody: Decodable {
        let error: String?
        let applied: Int?
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw CullingBayError.decoding(describe(error))
        } catch {
            throw CullingBayError.decoding(error.localizedDescription)
        }
    }

    private static func errorMessage(in data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing key \(key.stringValue) at \(path(context))"
        case .valueNotFound(_, let context), .typeMismatch(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default:
            return String(describing: error)
        }
    }
}

extension Photo {
    /// What the user can choose to save: both a picture and the RAW for a RAW photo, else only
    /// the picture.
    public var saveKinds: [SaveKind] { raw ? [.picture, .raw] : [.picture] }

    /// File name to save under. A RAW's picture is a JPEG so it gets `.jpg`; a non-RAW's picture
    /// and the RAW itself keep `file`.
    public func saveFilename(_ kind: SaveKind) -> String {
        guard kind == .picture, raw else { return file }
        if let dot = file.lastIndex(of: "."), dot != file.startIndex {
            return String(file[..<dot]) + ".jpg"
        }
        return file + ".jpg"
    }
}
