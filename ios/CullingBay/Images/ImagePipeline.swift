import CullingBayCore
import Foundation
import ImageIO
import Synchronization
import UIKit

/// Longest sides, in pixels, that pictures are decoded to. One value per kind, so a decoded
/// picture is found again whoever asks for it.
enum ImagePixels {
    static let thumb = 320
    static let view = 1616
    static let large = 3000
    static let tile = 2400
}

/// A decoded picture that can cross from a background task to the main actor. The image is
/// never changed after it is made.
struct LoadedImage: Sendable {
    let image: UIImage
}

/// Decoded pictures, kept while memory allows. A picture is found by its URL and decode size.
final class DecodedImageCache: Sendable {
    static let shared = DecodedImageCache()

    // NSCache is not Sendable in the SDK, so it sits behind a lock.
    private let cache: Mutex<NSCache<NSString, UIImage>>

    private init() {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 200 * 1024 * 1024
        self.cache = Mutex(cache)
    }

    func image(for url: URL, maxPixel: Int) -> UIImage? {
        let key = Self.key(url, maxPixel)
        return cache.withLock { $0.object(forKey: key as NSString) }
    }

    func store(_ image: UIImage, for url: URL, maxPixel: Int) {
        let cost = Int(image.size.width * image.size.height) * 4
        let key = Self.key(url, maxPixel)
        cache.withLock { $0.setObject(image, forKey: key as NSString, cost: cost) }
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> String {
        "\(url.absoluteString)@\(maxPixel)"
    }
}

/// Fetches through the shared `ImageDataLoader` and decodes off the main thread with ImageIO.
enum ImagePipeline {
    /// The decoded picture, or nil if it could not be fetched or decoded, or the caller was
    /// cancelled. `cacheDecoded: false` keeps the decoded picture out of the shared cache, for
    /// full-resolution crops, which are large and are not looked at twice; the loader's cache of
    /// the compressed data still serves a second look.
    static func load(
        _ url: URL, maxPixel: Int, loader: ImageDataLoader, cacheDecoded: Bool = true
    ) async -> LoadedImage? {
        if let cached = DecodedImageCache.shared.image(for: url, maxPixel: maxPixel) {
            return LoadedImage(image: cached)
        }
        guard let data = try? await loader.data(for: url), !Task.isCancelled else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decode(data, maxPixel: maxPixel)
        }.value
        guard let decoded else { return nil }
        if cacheDecoded { DecodedImageCache.shared.store(decoded.image, for: url, maxPixel: maxPixel) }
        return decoded
    }

    /// Downsamples to at most `maxPixel` on the longest side (never enlarges), applying the
    /// file's orientation, and decodes now rather than when first drawn.
    static func decode(_ data: Data, maxPixel: Int) -> LoadedImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)
        let target = longest > 0 ? min(maxPixel, longest) : maxPixel
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary)
        else { return nil }
        return LoadedImage(image: UIImage(cgImage: cgImage))
    }
}
