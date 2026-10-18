import CullingBayCore
import Foundation
import Observation

/// The app's one client, image loader and perf reporter, plus the Home model that rides on them.
/// Views read it from the environment. Changing the server builds all of them again and bumps
/// `generation`, which the root view uses to start the Gallery over.
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
        generation += 1
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
    }

    private static func connect(to url: URL, settings: any GallerySettings) -> Connection {
        let perf = PerfReporter(client: url)
        // Thumbnails are many and each is small news, and the queue holds only 400 marks, so
        // only the larger pictures are reported as fetches.
        let loader = ImageDataLoader(report: { fetched, ms, bytes, timing in
            guard !fetched.absoluteString.contains("s=thumb") else { return }
            let item = PerfMarks.fetch(url: fetched, ms: ms, bytes: bytes, serverTiming: timing)
            Task { await perf.mark(item) }
        })
        let client = CullingBayClient(baseURL: url)
        return Connection(
            client: client, loader: loader, perf: perf,
            home: HomeModel(client: client, settings: settings))
    }
}
