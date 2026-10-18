import Foundation
import Observation

/// State of the photo viewer over a feed's photos, as `show()` and `step()` in `gallery.js`
/// keep it. The photos are fixed when the viewer opens.
@MainActor
@Observable
public final class ViewerModel {
    public let photos: [Photo]
    /// The photo on screen. Always in range when there are photos.
    public private(set) var index: Int

    @ObservationIgnored private let source: FeedModel.Source
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var direction = 1
    @ObservationIgnored private var sourceSizes: [Int: Size] = [:]

    /// `index` is clamped into range. `timeZone` and `locale` decide how `whenText` shows the time.
    public init(
        photos: [Photo], index: Int, source: FeedModel.Source,
        timeZone: TimeZone = .current, locale: Locale = .current
    ) {
        self.photos = photos
        self.index = min(max(index, 0), max(photos.count - 1, 0))
        self.source = source
        self.timeZone = timeZone
        self.locale = locale
    }

    public var current: Photo? { photos.indices.contains(index) ? photos[index] : nil }

    /// `"3 / 120"`.
    public var counter: String { photos.isEmpty ? "" : "\(index + 1) / \(photos.count)" }

    /// `"Sat, Oct 17 2026 · 3:41 PM"`.
    public var whenText: String {
        guard let photo = current else { return "" }
        return [
            GalleryFormat.longDate(photo.date),
            GalleryFormat.time(photo.ts, timeZone: timeZone, locale: locale),
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `"Seattle · SONY ILCE-7RM3 · ★★★"`.
    public var whereText: String {
        guard let photo = current else { return "" }
        return [town(photo.place), photo.camera, GalleryFormat.stars(photo.stars)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var caption: String { current?.caption ?? "" }

    /// The "Day" button leads to the photo's day, so it is hidden when the feed already is one.
    public var showsDayButton: Bool {
        if case .day = source { false } else { true }
    }

    /// Moves `delta` photos. Returns false, and stays put, when that would leave the list. A move
    /// sets the direction `prefetchIDs` looks ahead in.
    @discardableResult
    public func step(_ delta: Int) -> Bool {
        let target = index + delta
        guard delta != 0, photos.indices.contains(target) else { return false }
        direction = delta > 0 ? 1 : -1
        index = target
        return true
    }

    /// Photos worth loading now: two ahead in the direction of travel and one behind, in range.
    public var prefetchIDs: [Int] {
        [index + direction, index + 2 * direction, index - direction]
            .filter { photos.indices.contains($0) }
            .map { photos[$0].id }
    }

    // MARK: Full-resolution sizes

    /// The full-resolution size of a photo, once a crop of it has said (`CropBox.sourceSize`).
    public func sourceSize(for id: Int) -> Size? { sourceSizes[id] }

    public func setSourceSize(_ size: Size, for id: Int) { sourceSizes[id] = size }
}
