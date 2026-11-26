import CryptoKit
import CullingBayCore
import Foundation
import Observation

/// The app's one client, image loader and perf reporter, plus the Home model that rides on them,
/// the Cull tab's write queue and days list, and the Practice tab's challenges, and the link that
/// says whether the PC can be reached. Views read it from the environment. Changing the server
/// builds all of them again and bumps `generation`, which the root view uses to start the
/// Gallery, the Cull tab and the Practice tab over.
@MainActor
@Observable
final class AppServices {
    let settings: UserDefaultsGallerySettings
    let exporter = PhotoLibraryExportService()
    /// The phone's network, for the link.
    let path = NetworkPathWatcher()
    private(set) var serverURL: URL
    /// Whether the PC can be reached; every request goes through it (`ServerLinkTransport`).
    private(set) var link: ServerLink
    /// The real network behind the link, for requests that skip the saved days: the 1:1 probes.
    private(set) var network: any HTTPTransport
    private(set) var client: CullingBayClient
    private(set) var loader: ImageDataLoader
    private(set) var perf: PerfReporter
    private(set) var home: HomeModel
    /// Every tap on a Cull card goes through this one queue, which keeps what is unsent on disk.
    private(set) var cullQueue: CullWriteQueue
    private(set) var cullDays: CullDaysModel
    private(set) var practice: PracticeModel
    /// Days kept on the phone, so they open with no connection (Settings > Offline).
    private(set) var offline: OfflineManager
    /// Every full-resolution crop of the focus check goes through this, a couple at a time, so
    /// the writes of a decision always have a connection to the server free.
    let cropGate = CropLoadGate(limit: 2)
    private(set) var generation = 0
    @ObservationIgnored private var launched = false
    /// The Settings sheet. Any screen can open it.
    var showsSettings = false

    init() {
        let settings = UserDefaultsGallerySettings()
        let connection = Self.connect(to: settings.serverURL, settings: settings)
        self.settings = settings
        self.serverURL = settings.serverURL
        self.link = connection.link
        self.network = connection.network
        self.client = connection.client
        self.loader = connection.loader
        self.perf = connection.perf
        self.home = connection.home
        self.cullQueue = connection.cullQueue
        self.cullDays = connection.cullDays
        self.practice = connection.practice
        self.offline = connection.offline
        wireLink()
    }

    /// At launch: watch the network, send the taps left from an earlier run, and probe the PC; once
    /// it answers, bring the days kept on the phone up to date. Once per run.
    func launch() {
        guard !launched else { return }
        launched = true
        path.start { [weak self] hasPath in self?.link.pathChanged(hasPath: hasPath) }
        startLink()
    }

    private func startLink() {
        if !path.hasPath { link.pathChanged(hasPath: false) }
        cullQueue.start()
        let link = link, offline = offline
        Task {
            await link.start()
            offline.sync()
        }
    }

    /// Reaching the PC again sends the taps waiting, syncs the saved days, refreshes the days
    /// list quietly and loads again a Gallery or Practice screen that failed for want of it. An
    /// open Cull day is left as it is. Work offline stops the downloads.
    private func wireLink() {
        link.onReachable = { [weak self] in self?.reachedPC() }
        link.onWorkOffline = { [weak self] in self?.offline.cancel() }
    }

    private func reachedPC() {
        cullQueue.resume()
        offline.sync()
        let days = cullDays, home = home, practice = practice
        Task { await days.refresh() }
        if case .failed = home.phase {
            Task { await home.load() }
        } else if home.refreshError != nil {
            Task { await home.refresh() }
        }
        if !practice.hasLoaded || !practice.message.isEmpty {
            Task { await practice.load() }
        }
    }

    /// Points the app at another server. Does nothing if it is the one already in use.
    func setServer(_ url: URL) {
        guard url != serverURL else { return }
        settings.serverURL = url
        serverURL = url
        offline.cancel()
        link.stop()
        let connection = Self.connect(to: url, settings: settings)
        link = connection.link
        network = connection.network
        client = connection.client
        loader = connection.loader
        perf = connection.perf
        home = connection.home
        cullQueue = connection.cullQueue
        cullDays = connection.cullDays
        practice = connection.practice
        offline = connection.offline
        wireLink()
        // This server may still have taps waiting from an earlier visit.
        startLink()
        generation += 1
    }

    /// A session for one day of the Cull tab. `match` is the search hit it was opened from.
    func makeCullSession(day: String, match: CullMatch? = nil) -> CullSessionModel {
        let link = link
        return CullSessionModel(
            day: day, client: client, queue: cullQueue, match: match,
            keepsDaysOffline: { OfflinePreferences.isEnabled },
            workingOffline: { link.isWorkingOffline },
            warmer: CullWarmer(client: client, queue: cullQueue))
    }

    /// A Save or Share for these photos, to show in an `ExportSheet`. `rawChoice` settles JPEG or
    /// RAW in advance, so the sheet does not ask.
    func makeExport(
        _ photos: [Photo], action: ExportModel.Action, rawChoice: RawChoice? = nil,
        onSuccess: (@MainActor () -> Void)? = nil
    ) -> ExportLaunch {
        ExportLaunch(model: ExportModel(
            photos: photos, action: action, client: client, perf: perf, service: exporter,
            rawChoice: rawChoice, onSuccess: onSuccess))
    }

    private struct Connection {
        let link: ServerLink
        let network: any HTTPTransport
        let client: CullingBayClient
        let loader: ImageDataLoader
        let perf: PerfReporter
        let home: HomeModel
        let cullQueue: CullWriteQueue
        let cullDays: CullDaysModel
        let practice: PracticeModel
        let offline: OfflineManager
    }

    private static func connect(to url: URL, settings: any GallerySettings) -> Connection {
        // `-CBReadOnly`: a simulator run that looks at the real server and cannot write to it.
        let real: any HTTPTransport = LaunchOptions.readOnly ? ReadOnlyTransport() : URLSessionTransport()
        // The probe goes out on the real network; everything else through the link, which fails
        // at once while the PC cannot be reached (or Work offline is on).
        let link = ServerLink(baseURL: url, network: real, setting: UserDefaultsWorkOffline())
        let network: any HTTPTransport = ServerLinkTransport(base: real, gate: link.gate)
        // Days kept on the phone answer for the PC when it cannot be reached; the client and the
        // image loader both go through this, so pictures come from the phone automatically.
        let offlineStore = OfflineStore(root: offlineStoreDirectory(for: url))
        let transport: any HTTPTransport = OfflineTransport(
            base: network, store: offlineStore, isEnabled: { OfflinePreferences.isEnabled })
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
        // The downloader fetches through the link, not through the saved days, and only while the
        // link is online.
        let offline = OfflineManager(
            client: client, store: offlineStore,
            downloader: OfflineDownloader(baseURL: url, transport: network, store: offlineStore),
            canReachPC: { link.isOnline })
        return Connection(
            link: link, network: network, client: client, loader: loader, perf: perf,
            home: HomeModel(client: client, settings: settings),
            cullQueue: queue, cullDays: CullDaysModel(client: client),
            practice: PracticeModel(
                client: client, store: FilePracticeDraftStore(directory: practiceStoreDirectory(for: url))),
            offline: offline)
    }

    /// Where the Cull queue keeps its unsent taps: one folder per server, so changing the server
    /// can never send a tap meant for one photo library to another. The folder is named by a
    /// hash of the address, which is safe in a path and the same on every launch.
    private static func cullStoreDirectory(for url: URL) -> URL {
        URL.applicationSupportDirectory.appending(
            path: "CullWrites/\(serverFolderName(for: url))", directoryHint: .isDirectory)
    }

    /// Where the Practice notes that did not reach the server are kept: one folder per server, named the same way.
    private static func practiceStoreDirectory(for url: URL) -> URL {
        URL.applicationSupportDirectory.appending(
            path: "PracticeNotes/\(serverFolderName(for: url))", directoryHint: .isDirectory)
    }

    /// Where the days kept on the phone live: one folder per server, named the same way.
    private static func offlineStoreDirectory(for url: URL) -> URL {
        URL.applicationSupportDirectory.appending(
            path: "Offline/\(serverFolderName(for: url))", directoryHint: .isDirectory)
    }

    private static func serverFolderName(for url: URL) -> String {
        let address = url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data(address.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
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
