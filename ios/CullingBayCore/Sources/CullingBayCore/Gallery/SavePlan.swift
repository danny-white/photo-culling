import Foundation

/// What to save for a RAW photo (decision N8). Choosing `.raw` saves only the RAW.
public enum RawChoice: Sendable, Hashable {
    case jpeg
    case raw
}

/// One file to download and put in Photos.
public struct SaveItem: Sendable, Hashable, Identifiable {
    public let photoID: Int
    public let url: URL
    /// The name to save under (`Photo.saveFilename`).
    public let filename: String
    public let kind: SaveKind
    /// The size to expect, known only for a RAW original; nil otherwise.
    public let expectedBytes: Int?

    public var id: Int { photoID }

    public init(photoID: Int, url: URL, filename: String, kind: SaveKind, expectedBytes: Int? = nil) {
        self.photoID = photoID
        self.url = url
        self.filename = filename
        self.kind = kind
        self.expectedBytes = expectedBytes
    }
}

/// Turns the photos to save into the downloads to make.
public enum SavePlan {
    /// Whether to ask JPEG or RAW first: true when any photo is a RAW.
    public static func needsRawChoice(_ photos: [Photo]) -> Bool {
        photos.contains { $0.raw }
    }

    /// One item per photo, in order. A photo that is not a RAW always gives its picture;
    /// `rawChoice` decides for the RAWs.
    public static func items(
        for photos: [Photo], rawChoice: RawChoice, client: CullingBayClient
    ) -> [SaveItem] {
        photos.map { photo in
            let kind: SaveKind = photo.raw && rawChoice == .raw ? .raw : .picture
            return SaveItem(
                photoID: photo.id, url: client.saveURL(for: photo, kind: kind),
                filename: photo.saveFilename(kind), kind: kind,
                expectedBytes: kind == .raw ? photo.bytes : nil)
        }
    }
}

/// How far a save is, for the save loop to update and a view to show.
public struct SaveProgress: Sendable, Hashable {
    public let total: Int
    /// Photos saved so far.
    public private(set) var done = 0
    /// Photo ids that could not be saved.
    public private(set) var failed: [Int] = []

    public init(total: Int) {
        self.total = total
    }

    public mutating func recordSaved() { done += 1 }

    public mutating func recordFailed(_ photoID: Int) { failed.append(photoID) }

    /// Photos finished, saved or not.
    public var processed: Int { done + failed.count }

    public var isFinished: Bool { processed >= total }

    /// 0...1.
    public var fraction: Double { total == 0 ? 1 : min(Double(processed) / Double(total), 1) }

    /// `"Saving 1 of 3…"` while running, then `"Saved 3 photos"` or `"Saved 2 of 3 — 1 failed"`.
    public var summary: String {
        if !isFinished { return "Saving \(processed + 1) of \(total)…" }
        if failed.isEmpty { return "Saved \(done) photo" + (done == 1 ? "" : "s") }
        return "Saved \(done) of \(total) — \(failed.count) failed"
    }
}
