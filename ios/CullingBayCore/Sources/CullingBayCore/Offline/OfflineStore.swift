import Foundation
import Synchronization

/// What the store knows about one day it holds, or is in the middle of fetching.
public struct OfflineDayRecord: Codable, Sendable, Hashable, Identifiable {
    /// The day id, e.g. `2026/2026-10-01`.
    public let day: String
    /// `Day.frames` when it was fetched, which is what the plan's size estimate used.
    public var frames: Int
    /// What the day's files take on disk (its JSON and every picture it uses). Pictures shared
    /// with another day count in both. 0 until `complete`.
    public var bytes: Int
    /// Every file is in, so the day can be opened with no connection.
    public var complete: Bool
    public var savedAt: Date
    /// The photo ids whose pictures the day uses; shared with other days by id.
    public var photos: [Int]

    public var id: String { day }
}

/// The pictures kept for a photo.
public enum OfflineImageKind: String, Sendable, Hashable, CaseIterable {
    /// The 320 px thumbnail: `img/<id>-thumb.jpg`.
    case thumb
    /// The 1616 px picture: `img/<id>-view.jpg`.
    case view
    /// The 1:1 crop at the AF point: `af/<id>.jpg`.
    case af
}

/// The days kept on the phone, as files under one folder (the app passes one per server):
///
///     days.json              the last GET /m/api/days
///     day/<key>.json         a day's GET /m/api/day/<day>, `key` being `key(for:)`
///     img/<id>-thumb.jpg     pictures, by photo id, shared by every day that uses the photo
///     img/<id>-view.jpg
///     af/<id>.jpg
///     manifest.json          the `OfflineDayRecord` of each day
///
/// Everything is synchronous, and a lock keeps the manifest whole, because the transport and the
/// downloader reach the store from their own tasks. Writes are atomic: a crash leaves the old
/// file, never half of a new one.
public final class OfflineStore: Sendable {
    public let root: URL

    private struct State {
        var records: [String: OfflineDayRecord]
    }

    private let state: Mutex<State>

    public init(root: URL) {
        self.root = root
        let records = Self.loadManifest(at: root.appendingPathComponent("manifest.json"))
        state = Mutex(State(records: Dictionary(uniqueKeysWithValues: records.map { ($0.day, $0) })))
    }

    // MARK: Names

    /// A day id as a file name: `/` becomes `_`, and anything but letters, digits, `-` and `.`
    /// (a literal `_` included) becomes `%XX`, so two days never share a name.
    /// `2026/2026-09-29` is `2026_2026-09-29`.
    public static func key(for day: String) -> String {
        var key = ""
        for byte in day.utf8 {
            switch byte {
            case UInt8(ascii: "/"):
                key.append("_")
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."):
                key.append(Character(UnicodeScalar(byte)))
            default:
                key += String(format: "%%%02X", Int(byte))
            }
        }
        return key
    }

    private var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    private var daysURL: URL { root.appendingPathComponent("days.json") }
    private var dayDirectory: URL { root.appendingPathComponent("day", isDirectory: true) }

    private func dayURL(_ day: String) -> URL {
        dayDirectory.appendingPathComponent(Self.key(for: day) + ".json")
    }

    /// Where a picture is (or would be) kept.
    public func imageURL(_ kind: OfflineImageKind, id: Int) -> URL {
        switch kind {
        case .thumb: root.appendingPathComponent("img/\(id)-thumb.jpg")
        case .view: root.appendingPathComponent("img/\(id)-view.jpg")
        case .af: root.appendingPathComponent("af/\(id).jpg")
        }
    }

    // MARK: Blobs

    /// The last `GET /m/api/days` body; nil if none was saved.
    public func readDays() -> Data? { try? Data(contentsOf: daysURL) }

    public func writeDays(_ data: Data) throws { try Self.write(data, to: daysURL) }

    /// A day's `GET /m/api/day/<day>` body; nil if none was saved.
    public func readDay(_ day: String) -> Data? { try? Data(contentsOf: dayURL(day)) }

    public func writeDay(_ day: String, _ data: Data) throws { try Self.write(data, to: dayURL(day)) }

    public func readImage(_ kind: OfflineImageKind, id: Int) -> Data? {
        try? Data(contentsOf: imageURL(kind, id: id))
    }

    public func hasImage(_ kind: OfflineImageKind, id: Int) -> Bool {
        FileManager.default.fileExists(atPath: imageURL(kind, id: id).path)
    }

    public func writeImage(_ data: Data, kind: OfflineImageKind, id: Int) throws {
        try Self.write(data, to: imageURL(kind, id: id))
    }

    // MARK: Days

    /// The day is whole: all its files are in.
    public func isSaved(_ day: String) -> Bool {
        state.withLock { $0.records[day]?.complete == true }
    }

    /// The days that are whole, newest saved first.
    public var savedDays: [String] {
        state.withLock { state in
            state.records.values.filter(\.complete)
                .sorted { $0.savedAt == $1.savedAt ? $0.day < $1.day : $0.savedAt > $1.savedAt }
                .map(\.day)
        }
    }

    /// Every day the store has a record of, whole or not.
    public var records: [OfflineDayRecord] {
        state.withLock { Array($0.records.values).sorted { $0.day < $1.day } }
    }

    public func record(for day: String) -> OfflineDayRecord? {
        state.withLock { $0.records[day] }
    }

    /// What a whole day takes; 0 for a day that is not whole.
    public func bytes(of day: String) -> Int {
        state.withLock { state in
            guard let record = state.records[day], record.complete else { return 0 }
            return record.bytes
        }
    }

    /// Everything the store holds on disk, shared pictures counted once.
    public var totalBytes: Int {
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return 0 }
        var total = 0
        for case let url as URL in files where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            total += Self.fileSize(url)
        }
        return total
    }

    /// Starts fetching a day: records it as not whole, with the photos it will use, so what is
    /// fetched is never mistaken for an orphan. Does not touch files already there.
    /// `keepingComplete`: a day already saved that is being topped up (its 1:1 crops, after its
    /// pictures) stays saved meanwhile, so it keeps opening offline.
    public func begin(day: String, frames: Int, photos: [Int], keepingComplete: Bool = false) throws {
        try state.withLock { state in
            let stays = keepingComplete && (state.records[day]?.complete ?? false)
            state.records[day] = OfflineDayRecord(
                day: day, frames: frames, bytes: stays ? state.records[day]?.bytes ?? 0 : 0, complete: stays,
                savedAt: Date(), photos: photos)
            try Self.writeManifest(state.records, to: manifestURL)
        }
    }

    /// Marks a begun day whole and records what it takes. Nil if it was never begun.
    @discardableResult
    public func finish(day: String) throws -> OfflineDayRecord? {
        try state.withLock { state in
            guard var record = state.records[day] else { return nil }
            var bytes = Self.fileSize(dayURL(day))
            for id in record.photos {
                for kind in OfflineImageKind.allCases { bytes += Self.fileSize(imageURL(kind, id: id)) }
            }
            record.bytes = bytes
            record.complete = true
            record.savedAt = Date()
            state.records[day] = record
            try Self.writeManifest(state.records, to: manifestURL)
            return record
        }
    }

    /// Forgets a day: its JSON, and every picture no other day uses.
    public func remove(_ day: String) {
        state.withLock { state in
            let removed = state.records.removeValue(forKey: day)
            try? FileManager.default.removeItem(at: dayURL(day))
            if let removed {
                let stillUsed = Set(state.records.values.flatMap(\.photos))
                for id in removed.photos where !stillUsed.contains(id) {
                    for kind in OfflineImageKind.allCases {
                        try? FileManager.default.removeItem(at: imageURL(kind, id: id))
                    }
                }
            }
            try? Self.writeManifest(state.records, to: manifestURL)
        }
    }

    /// Deletes pictures and day files that no record accounts for, left by a fetch that was
    /// stopped before its day was recorded.
    public func removeOrphans() {
        state.withLock { state in
            let used = Set(state.records.values.flatMap(\.photos))
            let manager = FileManager.default
            for folder in ["img", "af"] {
                let directory = root.appendingPathComponent(folder, isDirectory: true)
                for url in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                    // `<id>-thumb.jpg`, `<id>-view.jpg` or `<id>.jpg`.
                    let digits = url.lastPathComponent.prefix { $0.isASCII && $0.isNumber }
                    if let id = Int(digits), used.contains(id) { continue }
                    try? manager.removeItem(at: url)
                }
            }
            let keep = Set(state.records.keys.map { Self.key(for: $0) + ".json" })
            for url in (try? manager.contentsOfDirectory(at: dayDirectory, includingPropertiesForKeys: nil)) ?? []
            where !keep.contains(url.lastPathComponent) {
                try? manager.removeItem(at: url)
            }
        }
    }

    /// Forgets everything. The folder itself stays.
    public func removeAll() {
        state.withLock { state in
            state.records = [:]
            let manager = FileManager.default
            for url in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                try? manager.removeItem(at: url)
            }
        }
    }

    // MARK: Files

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private struct Manifest: Codable {
        let days: [OfflineDayRecord]
    }

    private static func loadManifest(at url: URL) -> [OfflineDayRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(Manifest.self, from: data))?.days ?? []
    }

    private static func writeManifest(_ records: [String: OfflineDayRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(Manifest(days: records.values.sorted { $0.day < $1.day }))
        try write(data, to: url)
    }
}
