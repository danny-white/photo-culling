import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension CullingBayClient {
    /// A tiny first crop discovers the upright source dimensions without decoding the full file
    /// on the phone. Subsequent visible tiles go through ImageDataLoader.
    public nonisolated func probeCropURL(id: Int, center: Point) -> URL {
        cropURL(id: id, centerX: center.x, centerY: center.y, width: 64, height: 64)
    }
}

/// Kept separate from JSON decoding: crop dimensions are an HTTP response header.
public enum CropProbe {
    /// `timeout`: how long to wait for the PC; shorter when the phone has a saved 1:1 to fall back on.
    public static func load(
        url: URL, timeout: TimeInterval = 60, transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> CropBox {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CullingBayError.http(status: response.statusCode, message: nil)
        }
        guard let box = CropBox(header: response.value(forHTTPHeaderField: "X-Crop-Box")) else {
            throw CullingBayError.decoding("The crop did not include its source dimensions.")
        }
        return box
    }
}
