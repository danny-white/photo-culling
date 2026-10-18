import CullingBayCore
import Foundation
import Photos

/// Downloads to temp files and adds them to the photo library (add-only access). All PhotoKit
/// calls are here.
@MainActor
final class PhotoLibraryExportService: PhotoExportService {
    /// A failure with a sentence for the save sheet.
    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    func requestAddPermission() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    func download(_ item: SaveItem) async throws -> URL {
        var request = URLRequest(url: item.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        let fileManager = FileManager.default
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? fileManager.removeItem(at: downloaded)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Failure(errorDescription: status == 404
                ? "That photo isn’t on the server any more."
                : "The server couldn’t send that photo (HTTP \(status)).")
        }
        // A folder of its own, so the file keeps its real name and is easy to clean up.
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: item.filename).lastPathComponent
        let file = folder.appendingPathComponent(name.isEmpty ? "photo" : name)
        try fileManager.moveItem(at: downloaded, to: file)
        return file
    }

    func addPhoto(file: URL, filename: String) async throws {
        try await Self.add(file: file, filename: filename)
    }

    func remove(file: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if UUID(uuidString: folder.lastPathComponent) != nil {
            try? fileManager.removeItem(at: folder)
        }
    }

    /// Not main-actor isolated: PhotoKit runs the change block on its own queue.
    private nonisolated static func add(file: URL, filename: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: file, options: options)
        }
    }
}
