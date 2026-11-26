import Foundation
import Observation

/// State of one person's screen: the header (name, photo count, picture, how many faces to
/// review) and what Danny does to the person: rename, merge into someone else, remove the name,
/// choose the cover. The person's photos are a `FeedModel` over `.person`; this is the rest.
///
/// `GET /m/api/people/<id>` carries only the name and the photos, so the header is read from the
/// `people` list, and each write's answer (the changed Person) replaces it.
@MainActor
@Observable
public final class PersonModel {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        /// There is no person to show: the load failed, or they are gone.
        case failed(String)
    }

    /// How the screen came to an end: the person is someone else's now, or deleted. The view closes.
    public enum Ending: Sendable, Hashable {
        case merged(into: Person)
        case deleted
    }

    /// What "Not Alex" took off one photo, or off several, kept for Undo.
    public struct PhotoRemoval: Sendable, Hashable {
        /// The faces that stopped being theirs: every face of theirs in the photo, or in each frame of the
        /// burst the tile stands for.
        public let faces: [Int]
        /// The photos those faces are in.
        public let photos: [Int]
        /// How many of the tiles asked about had none of their faces, and so stayed in the grid. Always 0
        /// for `removeFromPhoto`, which is one tile.
        public let skippedTiles: Int
        let tiles: FeedModel.RemovedTiles

        init(faces: [Int], photos: [Int], skippedTiles: Int = 0, tiles: FeedModel.RemovedTiles) {
            self.faces = faces
            self.photos = photos
            self.skippedTiles = skippedTiles
            self.tiles = tiles
        }
    }

    /// How `removeFromPhoto` and `removeFromPhotos` ended.
    public enum PhotoRemovalResult: Sendable, Hashable {
        case removed(PhotoRemoval)
        /// None of their faces is in the photo (or in the burst's frames, or in any of the photos asked
        /// about): the answer the grid gave is out of date, or the face was fixed elsewhere. Nothing was
        /// sent or changed.
        case notInPhoto
        /// Nothing changed; `message` says why.
        case failed
    }

    public let id: Int
    public private(set) var phase: Phase
    public private(set) var person: Person?
    /// Changes when their photos changed behind the grid's back (a review added some, the fix screen
    /// took faces away), so the screen reads the grid again. It is `[photos, faces]` as of the last such
    /// change. "Not Alex" on a tile and its Undo change the grid themselves and leave it alone.
    public private(set) var feedKey: [Int]
    /// Why the last write (or a reload with someone on screen) failed; empty when it didn't.
    public private(set) var message = ""
    public private(set) var ending: Ending?
    /// A write is in flight, so the menu should wait.
    public private(set) var isWorking = false

    @ObservationIgnored private let client: CullingBayClient
    @ObservationIgnored private var generation = 0

    /// `person` is what the list already knows, so the header shows at once.
    public init(id: Int, person: Person? = nil, client: CullingBayClient) {
        self.id = id
        self.person = person
        self.feedKey = Self.key(person)
        self.phase = person == nil ? .idle : .loaded
        self.client = client
    }

    private static func key(_ person: Person?) -> [Int] { [person?.photos ?? 0, person?.faces ?? 0] }

    // MARK: Reading

    public var name: String { person?.name ?? "" }
    public var photoCaption: String { person.map { PeopleFormat.personCaption($0) } ?? "" }
    /// A face id for the big circle; nil when they have no faces left.
    public var cover: Int? { person?.cover }

    /// `"Review 12 suggestions"`, nil when there are none.
    public var reviewBanner: String? {
        guard let person, person.suggestions > 0 else { return nil }
        return PeopleFormat.reviewTitle(person.suggestions)
    }

    /// `"Maybe not Alex? Check 250 faces"`, nil when the server has no doubts about their faces.
    public var checkBanner: String? {
        guard let person, person.doubts > 0 else { return nil }
        return PeopleFormat.checkBanner(person.doubts, name: person.name)
    }

    // MARK: Loading

    /// Reads the person again from the `people` list (a 304 makes it cheap). If someone is already
    /// on screen a failure keeps them and says why in `message`.
    public func load() async {
        generation += 1
        let mine = generation
        if person == nil { phase = .loading }
        do {
            let list = try await client.people()
            guard mine == generation else { return }
            if let found = list.people.first(where: { $0.id == id }) {
                person = found
                feedKey = Self.key(found)
                message = ""
                phase = .loaded
            } else {
                person = nil
                feedKey = Self.key(nil)
                phase = .failed("That person isn’t in the library any more.")
            }
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled {
                if person == nil { phase = .idle }
                return
            }
            let text = GalleryMessages.failure(error, loading: "the person")
            if person == nil {
                phase = .failed(text)
            } else {
                message = text
            }
        }
    }

    /// A screen that changed this person (the review, the fix screen) hands back their new state.
    public func update(_ changed: Person) {
        guard changed.id == id else { return }
        person = changed
        feedKey = Self.key(changed)
        phase = .loaded
    }

    // MARK: Writing

    /// Renames them. `.taken` carries the person who has that name, so the screen can offer to merge
    /// with them. A name that is not 1 to 80 characters is `.failed` without asking the server.
    @discardableResult
    public func rename(to text: String) async -> PersonWrite {
        guard let name = PeopleFormat.cleanName(text) else {
            message = PeopleMessages.nameLength
            return .failed
        }
        if let person, person.name == name { return .saved(person) }
        let result: PersonWrite? = await write {
            do {
                let changed = try await self.client.renamePerson(self.id, to: name)
                self.update(changed)
                return .saved(changed)
            } catch let taken as PersonNameTaken {
                return .taken(taken.existing)
            }
        }
        return result ?? .failed
    }

    /// Everything said about this person becomes `other`'s, and this person goes. On success
    /// `ending` is `.merged`.
    @discardableResult
    public func merge(into other: Person) async -> Bool {
        guard let into = await write({ try await self.client.mergePerson(self.id, into: other.id) })
        else { return false }
        ending = .merged(into: into)
        return true
    }

    /// Takes the name off: their faces go back to their groups. On success `ending` is `.deleted`.
    @discardableResult
    public func delete() async -> Bool {
        guard await write({ try await self.client.deletePerson(self.id) }) != nil else { return false }
        ending = .deleted
        return true
    }

    /// Chooses the face for their picture; nil goes back to the best confirmed face.
    @discardableResult
    public func setCover(face: Int?) async -> Bool {
        guard let changed = await write({ try await self.client.setCover(self.id, face: face) })
        else { return false }
        update(changed)
        return true
    }

    // MARK: One photo, or several

    /// The most photos whose faces are read at once (and days read at once) for a removal.
    private static let maxReads = 6

    /// "Not Alex" on one photo of their grid: every face of theirs in it stops being theirs, now and for
    /// any later suggestion (the same write as the fix screen's). The tile goes from `feed` at once and
    /// their photo count drops; nothing is read again. It is `removeFromPhotos` for one tile.
    ///
    /// With "1/burst" on, a tile stands for a whole burst: the grid shows the first frame of each stack
    /// that has them, and a `Photo` doesn't say what its other frames are. So the stack is read from the
    /// day (`GET /m/api/day/<day>`, the Cull tab's route) and every frame that has their face is dealt
    /// with, or the tile would only change to the next frame. With it off, a tile is one photo.
    ///
    /// Any failure sends nothing more, leaves `feed` as it was and says why in `message`.
    @discardableResult
    public func removeFromPhoto(_ photo: Photo, in feed: FeedModel) async -> PhotoRemovalResult {
        await removeFromPhotos([photo], in: feed)
    }

    /// "Not Alex" on many tiles of their grid at once, as `removeFromPhoto` does for one: every face of
    /// theirs in them (or in the frames of the bursts they stand for) stops being theirs, in one write.
    /// The tiles that had one go from `feed` and its `total` drops by the photos they were in; a tile
    /// with none of their faces stays, and `skippedTiles` counts them.
    ///
    /// The selection can be hundreds of tiles, so each day is read once however many tiles it has, and
    /// the faces are read a few at a time. All the reading is done before anything is written: a failure
    /// in it sends nothing, leaves `feed` as it was and says why in `message`.
    @discardableResult
    public func removeFromPhotos(_ photos: [Photo], in feed: FeedModel) async -> PhotoRemovalResult {
        guard !isWorking else {
            message = PeopleMessages.busy
            return .failed
        }
        message = ""
        isWorking = true
        defer { isWorking = false }
        do {
            var seenTiles = Set<Int>()
            let tiles = photos.filter { seenTiles.insert($0.id).inserted }
            let stacks = feed.bursts ? try await framesOfTiles(tiles) : [:]
            func frames(of tile: Photo) -> [Int] { stacks[tile.id] ?? [tile.id] }
            let found = try await theirFaces(in: tiles.flatMap(frames(of:)))

            var faces: [Int] = []
            var hit: [Int] = []
            var seenPhotos = Set<Int>()
            var gone = Set<Int>()
            var skipped = 0
            for tile in tiles {
                let theirs = frames(of: tile).filter { found[$0]?.isEmpty == false }
                guard !theirs.isEmpty else {
                    skipped += 1
                    continue
                }
                gone.insert(tile.id)
                for photo in theirs {
                    gone.insert(photo)
                    if seenPhotos.insert(photo).inserted {
                        hit.append(photo)
                        faces += found[photo] ?? []
                    }
                }
            }
            guard !faces.isEmpty else { return .notInPhoto }
            let changed = try await client.removeFaces(faces, from: id)
            let removed = feed.remove(gone, lowersTotalBy: hit.count)
            person = changed
            return .removed(PhotoRemoval(faces: faces, photos: hit, skippedTiles: skipped, tiles: removed))
        } catch {
            if !(error is CancellationError) { message = PeopleMessages.failure(error) }
            return .failed
        }
    }

    /// Undo of `removeFromPhoto` or `removeFromPhotos`: the faces are theirs again (`add`, which also takes
    /// back the "not", one write for all of them), and the tiles go back in the grid where they were. If the grid has been loaded again since, it is
    /// loaded once more instead, so it is right either way. False when the write failed; nothing changed.
    @discardableResult
    public func undoRemoval(_ removal: PhotoRemoval, in feed: FeedModel) async -> Bool {
        guard !isWorking else {
            message = PeopleMessages.busy
            return false
        }
        message = ""
        isWorking = true
        defer { isWorking = false }
        do {
            let changed = try await client.addFaces(to: id, faces: removal.faces)
            person = changed
        } catch {
            if !(error is CancellationError) { message = PeopleMessages.failure(error) }
            return false
        }
        if !feed.restore(removal.tiles) { await feed.load() }
        return true
    }

    /// The frames each tile stands for, by tile id: its stack's frames, read from its day. A tile the
    /// day doesn't know (a JPEG that rides along with a RAW is not a stack's frame, and shows as a tile
    /// of its own), or a day the server doesn't know (404), has no entry: it is just itself. Each day
    /// is read once.
    private func framesOfTiles(_ tiles: [Photo]) async throws -> [Int: [Int]] {
        var seenDays = Set<String>()
        let days = tiles.map(\.day).filter { seenDays.insert($0).inserted }
        let client = self.client
        let stacks = try await gather(days, limit: Self.maxReads) { day -> [[Int]] in
            do {
                return try await client.cullDay(day).stacks.map { $0.frames.map(\.id) }
            } catch CullingBayError.http(404, _) {
                return []
            }
        }
        let wanted = Set(tiles.map(\.id))
        var frames: [Int: [Int]] = [:]
        for stack in stacks.values.joined() {
            for id in stack where wanted.contains(id) { frames[id] = stack }
        }
        return frames
    }

    /// Their faces in each of these photos (none for a photo they are not in), asked for `maxReads`
    /// at a time.
    private func theirFaces(in photos: [Int]) async throws -> [Int: [Int]] {
        var seen = Set<Int>()
        let distinct = photos.filter { seen.insert($0).inserted }
        let client = self.client
        let person = id
        return try await gather(distinct, limit: Self.maxReads) { photo in
            try await client.photoFaces(photo).filter { $0.person?.id == person }.map(\.id)
        }
    }

    /// Runs one write: clears the old message, holds the menu, and turns a failure into `message`
    /// and a nil.
    private func write<T: Sendable>(_ work: () async throws -> T) async -> T? {
        message = ""
        isWorking = true
        defer { isWorking = false }
        do {
            return try await work()
        } catch {
            if !(error is CancellationError) { message = PeopleMessages.failure(error) }
            return nil
        }
    }
}

/// Runs `work` for each item, at most `limit` at a time, and answers by item. The first failure cancels
/// what is still running and is thrown.
private func gather<Item: Hashable & Sendable, Output: Sendable>(
    _ items: [Item], limit: Int, _ work: @escaping @Sendable (Item) async throws -> Output
) async throws -> [Item: Output] {
    try await withThrowingTaskGroup(of: (Item, Output).self) { group in
        var pending = items.makeIterator()
        for _ in 0..<limit {
            guard let item = pending.next() else { break }
            group.addTask { (item, try await work(item)) }
        }
        var found: [Item: Output] = [:]
        while let (item, output) = try await group.next() {
            found[item] = output
            if let next = pending.next() { group.addTask { (next, try await work(next)) } }
        }
        return found
    }
}
