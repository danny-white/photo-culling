import Foundation

/// Tells the PC which RAWs a 1:1 check is likely to want next, so each is decoded before the
/// check asks for it (`CullingBayClient.warm`).
///
/// The PC starts a RAW's decode when a card's `view` picture is asked for. A day saved on the
/// phone shows its cards from the phone's own copy, so that request never reaches the PC and the
/// first 1:1 check of every card waited for a cold decode (about 1.4 s). The Cull session and
/// the burst picker name the frames on screen and the next one here instead.
///
/// - Fire and forget: a failure is ignored. It shows nothing, and the frames are tried again the
///   next time they come up.
/// - A frame already named is not sent again. The last `remembered` are kept, which is as many
///   as the PC keeps decoded.
/// - Not while the write queue is offline, and not for a file that is not a RAW.
/// - A request goes out `delay` after the last change, so swiping fast through a day asks for
///   the card it stops on, not every card on the way (each decode reads a whole RAW from the NAS).
@MainActor
public final class CullWarmer {
    /// How long a change waits for the next one before the PC is asked.
    public static let delay: Duration = .milliseconds(150)
    /// How many frames are remembered as asked for. The PC keeps 16 full decodes.
    public static let remembered = 16

    private static let rawExtensions: Set<String> = [
        "arw", "nef", "cr2", "cr3", "dng", "raf", "orf", "rw2", "pef", "srw",
    ]

    private let client: CullingBayClient
    private let isOffline: @MainActor () -> Bool
    private let sleep: CullSleep
    /// Frame ids asked for, oldest first (read by the tests).
    private(set) var asked: [Int] = []
    private var pending: Task<Void, Never>?

    public init(
        client: CullingBayClient, queue: CullWriteQueue, sleep: @escaping CullSleep = CullClock.system
    ) {
        self.client = client
        self.isOffline = { queue.isOffline }
        self.sleep = sleep
    }

    /// Asks for these frames, most urgent first: the one a 1:1 check would open, then the next
    /// one. Replaces a request still waiting for its `delay`, as the user has moved on.
    public func warm(_ frames: [Frame]) {
        pending?.cancel()
        pending = nil
        var wanted: [Int] = []
        for frame in frames where Self.isRAW(frame.file) && !wanted.contains(frame.id) {
            wanted.append(frame.id)
        }
        guard wanted.contains(where: { !asked.contains($0) }) else { return }
        let sleep = sleep
        pending = Task { [weak self] in
            do { try await sleep(Self.delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.send(wanted)
        }
    }

    /// Drops a request still waiting. The Cull session calls it when its day goes away.
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Whether a file is one the PC decodes ahead (its RAW extensions).
    static func isRAW(_ file: String) -> Bool {
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return false }
        return rawExtensions.contains(file[file.index(after: dot)...].lowercased())
    }

    private func send(_ ids: [Int]) {
        pending = nil
        guard !isOffline() else { return }
        let fresh = ids.filter { !asked.contains($0) }
        guard !fresh.isEmpty else { return }
        asked += fresh
        if asked.count > Self.remembered { asked.removeFirst(asked.count - Self.remembered) }
        let client = client
        Task { [weak self] in
            do { try await client.warm(ids: fresh) } catch { self?.forget(fresh) }
        }
    }

    /// The PC did not get them, so they are asked for again when they next come up.
    private func forget(_ ids: [Int]) {
        asked.removeAll { ids.contains($0) }
    }
}
