import Foundation
import Testing
@testable import CullingBayCore

@MainActor
private final class FakeExportService: PhotoExportService {
    var allowed = true
    var failDownloadFor: Set<Int> = []
    var failAddFor: Set<String> = []
    private(set) var downloads: [SaveItem] = []
    private(set) var added: [String] = []
    private(set) var removed: [URL] = []
    private(set) var permissionRequests = 0

    func requestAddPermission() async -> Bool {
        permissionRequests += 1
        return allowed
    }

    func download(_ item: SaveItem) async throws -> URL {
        downloads.append(item)
        if failDownloadFor.contains(item.photoID) { throw CullingBayError.http(status: 500, message: "boom") }
        return URL(fileURLWithPath: "/tmp/cb-\(item.photoID)-\(item.filename)")
    }

    func addPhoto(file: URL, filename: String) async throws {
        if failAddFor.contains(filename) { throw TestFailure() }
        added.append(filename)
    }

    func remove(file: URL) { removed.append(file) }
}

@MainActor
@Suite("Export model")
struct ExportModelTests {
    private let client = CullingBayClient(baseURL: testBaseURL, transport: fixedTransport())
    private let perfTransport = fixedTransport()

    private let photos = [
        galleryPhoto(1, file: "DSC00001.ARW", raw: true, bytes: 43_100_672),
        galleryPhoto(2, file: "IMG_0002.JPG"),
    ]

    private func make(
        _ photos: [Photo], _ action: ExportModel.Action, service: FakeExportService,
        rawChoice: RawChoice? = nil, onSuccess: (@MainActor () -> Void)? = nil
    ) -> (ExportModel, PerfReporter) {
        let perf = PerfReporter(client: testBaseURL, transport: perfTransport)
        return (ExportModel(
            photos: photos, action: action, client: client, perf: perf, service: service,
            rawChoice: rawChoice, onSuccess: onSuccess), perf)
    }

    @Test func aRawAsksForAChoiceFirst() {
        let (model, _) = make(photos, .save, service: FakeExportService())
        #expect(model.needsChoice && !model.hasStarted)
        let (plain, _) = make([photos[1]], .save, service: FakeExportService())
        #expect(!plain.needsChoice)
    }

    @Test func savingAsJpegAddsEveryPhotoAndRemovesItsFiles() async {
        let service = FakeExportService()
        let (model, perf) = make(photos, .save, service: service)
        await model.run(choice: .jpeg)
        #expect(service.added == ["DSC00001.jpg", "IMG_0002.JPG"])
        #expect(service.removed.count == 2)
        #expect(model.progress.done == 2 && model.progress.isFinished)
        #expect(model.message == "Saved 2 photos")
        #expect(!model.isRunning && !model.needsChoice)
        let marks = await perf.pendingCount
        #expect(marks == 1)
    }

    @Test func savingTheRawDownloadsOnlyTheRaw() async {
        let service = FakeExportService()
        let (model, _) = make(photos, .save, service: service)
        await model.run(choice: .raw)
        #expect(service.downloads.map(\.kind) == [.raw, .picture])
        #expect(service.added == ["DSC00001.ARW", "IMG_0002.JPG"])
    }

    @Test func aDeniedPermissionSavesNothingAndSaysWhy() async {
        let service = FakeExportService()
        service.allowed = false
        let (model, _) = make(photos, .save, service: service)
        await model.run()
        #expect(model.permissionDenied)
        #expect(model.message.contains("Settings"))
        #expect(service.downloads.isEmpty)
        #expect(!model.isRunning)
    }

    @Test func oneFailureDoesNotStopTheRestAndIsCounted() async {
        let service = FakeExportService()
        service.failDownloadFor = [1]
        let (model, _) = make(photos, .save, service: service)
        await model.run()
        #expect(service.added == ["IMG_0002.JPG"])
        #expect(model.progress.failed == [1])
        #expect(model.message == "Saved 1 of 2 — 1 failed")
    }

    @Test func aFailedAddStillRemovesTheTempFile() async {
        let service = FakeExportService()
        service.failAddFor = ["IMG_0002.JPG"]
        let (model, _) = make([photos[1]], .save, service: service)
        await model.run()
        #expect(service.removed.count == 1)
        #expect(model.progress.failed == [2])
    }

    @Test func runningTwiceDoesNothingTheSecondTime() async {
        let service = FakeExportService()
        let (model, _) = make(photos, .save, service: service)
        await model.run()
        await model.run()
        #expect(service.permissionRequests == 1)
        #expect(service.added.count == 2)
    }

    @Test func sharingKeepsTheFileUntilTheSheetIsDone() async {
        let service = FakeExportService()
        let (model, _) = make(photos, .share, service: service)
        #expect(model.photos.map(\.id) == [1])
        await model.run(choice: .jpeg)
        #expect(service.permissionRequests == 0)
        #expect(model.shareFile?.lastPathComponent == "cb-1-DSC00001.jpg")
        #expect(service.removed.isEmpty)
        model.finishSharing()
        #expect(model.shareFile == nil)
        #expect(service.removed.count == 1)
    }

    @Test func sharingTheRawSharesTheOriginal() async {
        let service = FakeExportService()
        let (model, _) = make(photos, .share, service: service)
        await model.run(choice: .raw)
        #expect(model.shareFile?.lastPathComponent == "cb-1-DSC00001.ARW")
    }

    // MARK: Preset choice

    @Test func aPresetRawChoiceSkipsTheQuestion() {
        let (model, _) = make([photos[0]], .save, service: FakeExportService(), rawChoice: .raw)
        #expect(!model.needsChoice && !model.hasStarted)
        let (jpeg, _) = make([photos[0]], .save, service: FakeExportService(), rawChoice: .jpeg)
        #expect(!jpeg.needsChoice)
    }

    @Test func aPresetRawChoicePlansTheRaw() async {
        let service = FakeExportService()
        let (model, _) = make([photos[0]], .save, service: service, rawChoice: .raw)
        await model.run()                                       // the sheet runs it without a choice
        #expect(service.downloads.map(\.kind) == [.raw])
        #expect(service.added == ["DSC00001.ARW"])
        #expect(model.progress.done == 1 && model.message == "Saved 1 photo")
    }

    @Test func aPresetBeatsTheChoiceGivenToRun() async {
        let service = FakeExportService()
        let (model, _) = make([photos[0]], .save, service: service, rawChoice: .raw)
        await model.run(choice: .jpeg)
        #expect(service.downloads.map(\.kind) == [.raw])
    }

    @Test func aPresetRawSharesTheOriginalAndLeavesAJpegAlone() async {
        let service = FakeExportService()
        let (share, _) = make(photos, .share, service: service, rawChoice: .raw)
        #expect(!share.needsChoice)
        await share.run()
        #expect(share.shareFile?.lastPathComponent == "cb-1-DSC00001.ARW")
        let (save, _) = make([photos[1]], .save, service: FakeExportService(), rawChoice: .raw)
        await save.run()
        #expect(save.progress.done == 1)
    }

    @Test func withoutAPresetTheChoiceStillRules() async {
        let service = FakeExportService()
        let (model, _) = make([photos[0]], .save, service: service, rawChoice: nil)
        #expect(model.needsChoice)
        await model.run(choice: .jpeg)
        #expect(service.downloads.map(\.kind) == [.picture])
    }

    // MARK: Success hook

    @Test func aFinishedSaveCallsOnSuccessOnce() async {
        var calls = 0
        let (model, _) = make(photos, .save, service: FakeExportService(), onSuccess: { calls += 1 })
        await model.run(choice: .raw)
        #expect(calls == 1)
        await model.run(choice: .raw)                          // a second run does nothing
        #expect(calls == 1)
    }

    @Test func aSharedFileCallsOnSuccessWhenItIsReady() async {
        var calls = 0
        let (model, _) = make([photos[0]], .share, service: FakeExportService(), rawChoice: .raw, onSuccess: { calls += 1 })
        await model.run()
        #expect(model.shareFile != nil)
        #expect(calls == 1)
    }

    @Test func aDeniedPermissionDoesNotCallOnSuccess() async {
        var calls = 0
        let service = FakeExportService()
        service.allowed = false
        let (model, _) = make([photos[0]], .save, service: service, rawChoice: .raw, onSuccess: { calls += 1 })
        await model.run()
        #expect(model.permissionDenied && calls == 0)
    }

    @Test func aFailedDownloadDoesNotCallOnSuccess() async {
        var calls = 0
        let service = FakeExportService()
        service.failDownloadFor = [1]
        let (save, _) = make([photos[0]], .save, service: service, rawChoice: .raw, onSuccess: { calls += 1 })
        await save.run()
        let (share, _) = make([photos[0]], .share, service: service, rawChoice: .raw, onSuccess: { calls += 1 })
        await share.run()
        #expect(save.progress.failed == [1] && share.shareFile == nil)
        #expect(calls == 0)
    }

    @Test func aFailedAddDoesNotCallOnSuccess() async {
        var calls = 0
        let service = FakeExportService()
        service.failAddFor = ["IMG_0002.JPG"]
        let (model, _) = make([photos[1]], .save, service: service, onSuccess: { calls += 1 })
        await model.run()
        #expect(calls == 0)
    }

    @Test func aCancelledSaveDoesNotCallOnSuccess() async {
        var calls = 0
        let (model, _) = make(photos, .save, service: FakeExportService(), rawChoice: .raw, onSuccess: { calls += 1 })
        let task = Task { await model.run() }
        task.cancel()
        await task.value
        #expect(model.message == "Cancelled." && calls == 0)
    }
}
