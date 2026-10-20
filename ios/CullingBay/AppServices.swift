import CryptoKit
import CullingBayCore
import Foundation
import Observation

/// The app's one client, image loader and perf reporter, plus the Home model that rides on them,
/// and the Cull tab's write queue and days list. Views read it from the environment. Changing the
/// server builds all of them again and bumps `generation`, which the root view uses to start the
/// Gallery and the Cull tab over.
@MainActor
@Observable
final class AppServices {
    let settings: UserDefaultsGallerySettings
    let exporter = PhotoLibraryExportService()
    private(set) var serverURL: URL
    private(set) var client: CullingBayClient
    private(set) var loader: ImageDataLoader
    private(set) var perf: PerfReporter
    private(set) var home: HomeModel
    /// Every tap on a Cull card goes through this one queue, which keeps what is unsent on disk.
    private(set) var cullQueue: CullWriteQueue
    private(set) var cullDays: CullDaysModel
    /// Every full-resolution crop of the focus check goes through this, a couple at a time, so
    /// the writes of a decision always have a connection to the server free.
    let cropGate = CropLoadGate(limit: 2)
    private(set) var generation = 0
    /// The Settings sheet. Any screen can open it.
    var showsSettings = false

    init() {
        let settings = UserDefaultsGallerySettings()
        let connection = Self.connect(to: settings.serverURL, settings: settings)
        self.settings = settings
        self.serverURL = settings.serverURL
        self.client = connection.client
        self.loader = connection.loader
        self.perf = connection.perf
        self.home = connection.home
        self.cullQueue = connection.cullQueue
        self.cullDays = connection.cullDays
    }

    /// Points the app at another server. Does nothing if it is the one already in use.
    func setServer(_ url: URL) {
        guard url != serverURL else { return }
        settings.serverURL = url
        serverURL = url
        let connection = Self.connect(to: url, settings: settings)
        client = connection.client
        loader = connection.loader
        perf = connection.perf
        home = connection.home
        cullQueue = connection.cullQueue
        cullDays = connection.cullDays
        // This server may still have taps waiting from an earlier visit.
        cullQueue.start()
        generation += 1
    }

    /// A session for one day of the Cull tab. `match` is the search hit it was opened from.
    func makeCullSession(day: String, match: CullMatch? = nil) -> CullSessionModel {
        CullSessionModel(day: day, client: client, queue: cullQueue, match: match)
    }

    /// A Save or Share for these photos, to show in an `ExportSheet`.
    func makeExport(_ photos: [Photo], action: ExportModel.Action) -> ExportLaunch {
        ExportLaunch(model: ExportModel(
            photos: photos, action: action, client: client, perf: perf, service: exporter))
    }

    private struct Connection {
        let client: CullingBayClient
        let loader: ImageDataLoader
        let perf: PerfReporter
        let home: HomeModel
        let cullQueue: CullWriteQueue
        let cullDays: CullDaysModel
    }

    private static func connect(to url: URL, settings: any GallerySettings) -> Connection {
        // `-CBReadOnly`: a simulator run that looks at the real server and cannot write to it.
        let transport: any HTTPTransport = LaunchOptions.readOnly ? ReadOnlyTransport() : URLSessionTransport()
        let perf = PerfReporter(client: url, transport: transport)
        // Thumbnails are many and each is small news, and the queue holds only 400 marks, so
        // only the larger pictures are reported as fetches.
        let loader = ImageDataLoader(transport: transport, report: { fetched, ms, bytes, timing in
            guard !fetched.absoluteString.contains("s=thumb") else { return }
            let item = PerfMarks.fetch(url: fetched, ms: ms, bytes: bytes, serverTiming: timing)
            Task { await perf.mark(item) }
        })
        let client = CullingBayClient(baseURL: url, transport: transport)
        let queue = CullWriteQueue(
            client: client, store: FileCullWriteStore(directory: cullStoreDirectory(for: url)))
        return Connection(
            client: client, loader: loader, perf: perf,
            home: HomeModel(client: client, settings: settings),
            cullQueue: queue, cullDays: CullDaysModel(client: client))
    }

    /// Where the Cull queue keeps its unsent taps: one folder per server, so changing the server
    /// can never send a tap meant for one photo library to another. The folder is named by a
    /// hash of the address, which is safe in a path and the same on every launch.
    private static func cullStoreDirectory(for url: URL) -> URL {
        let address = url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data(address.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory.appending(path: "CullWrites/\(name)", directoryHint: .isDirectory)
    }
}

/// The network for a `-CBReadOnly` run: GETs go through, anything else is refused before it
/// leaves the phone. A refused write is an error like a lost connection, so the Cull queue keeps
/// it and never gets it to the server.
struct ReadOnlyTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        guard method == "GET" else {
            throw CullingBayError.transport("Read-only run: \(method) \(request.url?.path ?? "") was not sent.")
        }
        return try await URLSessionTransport().send(request)
    }
}
