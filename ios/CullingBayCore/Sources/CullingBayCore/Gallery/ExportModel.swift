import Foundation
import Observation

/// Platform operations only. The app implements PhotoKit and temporary-file handling.
@MainActor
public protocol PhotoExportService: AnyObject {
    func requestAddPermission() async -> Bool
    func download(_ item: SaveItem) async throws -> URL
    func addPhoto(file: URL, filename: String) async throws
    func remove(file: URL)
}

@MainActor
@Observable
public final class ExportModel {
    public enum Action: Sendable { case save, share }
    public let action: Action
    public let photos: [Photo]
    public private(set) var needsChoice: Bool
    public private(set) var isRunning = false
    public private(set) var hasStarted = false
    public private(set) var permissionDenied = false
    public private(set) var progress: SaveProgress
    public private(set) var message = ""
    public private(set) var shareFile: URL?
    @ObservationIgnored private let service: any PhotoExportService
    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private let perf: PerfReporter

    public init(photos: [Photo], action: Action, client: CullingBayClient,
                perf: PerfReporter, service: any PhotoExportService) {
        self.photos = action == .share ? Array(photos.prefix(1)) : photos
        self.action = action
        self.client = client
        self.perf = perf
        self.service = service
        needsChoice = SavePlan.needsRawChoice(self.photos)
        progress = SaveProgress(total: self.photos.count)
    }

    public func run(choice: RawChoice = .jpeg) async {
        guard !hasStarted else { return }
        hasStarted = true
        needsChoice = false
        isRunning = true
        defer { isRunning = false }
        if action == .save, !(await service.requestAddPermission()) {
            permissionDenied = true
            message = "Allow Culling Bay to add photos in Settings, then try saving again."
            return
        }
        let start = ContinuousClock.now
        let items = SavePlan.items(for: photos, rawChoice: choice, client: client)
        var marked = false
        for item in items {
            if Task.isCancelled { message = "Cancelled."; return }
            do {
                let file = try await service.download(item)
                // The share sheet owns its file until dismissed. Save files are removed after
                // PhotoKit's completion, including a failed add or cancellation.
                defer { if shareFile != file { service.remove(file: file) } }
                try Task.checkCancellation()
                if !marked {
                    marked = true
                    let elapsed = ContinuousClock.now - start
                    await perf.mark(PerfMarks.saveReady(ms: Self.milliseconds(elapsed), url: item.url, count: items.count))
                }
                if action == .share {
                    shareFile = file
                    message = "Ready to share."
                } else {
                    try await service.addPhoto(file: file, filename: item.filename)
                    progress.recordSaved()
                }
            } catch {
                if Task.isCancelled { message = "Cancelled."; return }
                progress.recordFailed(item.photoID)
                message = error.localizedDescription
            }
        }
        if action == .save { message = progress.summary }
    }

    public func finishSharing() {
        if let file = shareFile { service.remove(file: file) }
        shareFile = nil
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
