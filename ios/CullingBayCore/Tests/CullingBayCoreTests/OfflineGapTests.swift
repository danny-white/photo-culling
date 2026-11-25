import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

/// Gaps in the offline days that the 2026-11-24 review found (`review-2026-11-24/ios.md`). Each
/// test says what should happen, inside `withKnownIssue` because today it does not; the comment
/// names the finding. When a fix lands the known issue is no longer recorded and the test fails:
/// then drop the `withKnownIssue` wrapper, and the test guards the fix. Behaviour around them that
/// is right today is pinned with plain expectations.
@MainActor
@Suite("Offline: gaps the review found")
struct OfflineGapTests {
    private let dayID = "2026/2026-10-01"

    /// A PC that answers a day with `body` and every picture or crop with a few bytes.
    private func pc(_ body: SendableBox<String>) -> FakeTransport {
        FakeTransport { request, _ in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/m/api/day/") { return jsonResponse(body.value, for: request) }
            return (Data("jpeg \(path)".utf8), makeResponse(for: request))
        }
    }

    private func dayBody(_ ids: [Int]) -> String {
        cullJSON(cullDay(ids.map { cullStack($0, .single, [cullFrame($0, af: [0.5, 0.5])]) }))
    }

    private func pictureRequests(_ transport: FakeTransport) async -> Int {
        await transport.requests.filter { $0.url?.path.hasPrefix("/m/api/img/") == true }.count
    }

    // MARK: The manifest (card B5)

    @Test func aManifestThisBuildCannotReadDoesNotCostTheSavedPictures() async throws {
        // ios.md: "Unreadable or schema-changed queue file is treated as empty, then overwritten
        // (all unsent taps lost); the offline manifest does the same and then deletes the cache"
        // (card B5). Today the store starts with no records, and the next sync's removeOrphans
        // deletes every saved picture, which the downloader then fetches all over again.
        let root = TempRoot()
        let earlier = root.store()
        try earlier.begin(day: dayID, frames: 2, photos: [1, 2])
        try earlier.writeDay(dayID, Data(dayBody([1, 2]).utf8))
        for id in [1, 2] {
            for kind in [OfflineImageKind.thumb, .view] { try earlier.writeImage(Data("saved".utf8), kind: kind, id: id) }
        }
        try earlier.finish(day: dayID)
        // The manifest names a field the way another build would (`frames` renamed).
        let manifest = root.url.appendingPathComponent("manifest.json")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        try text.replacingOccurrences(of: "\"frames\"", with: "\"frameCount\"")
            .write(to: manifest, atomically: true, encoding: .utf8)

        let server = pc(SendableBox(dayBody([1, 2])))
        let rig = SyncRig(
            .fresh([planDay("2026-10-01", frames: 2, decided: 1)]), settings: FakeOfflineSettings(crops: false),
            root: root, network: server)
        await rig.syncNow()
        #expect(rig.store.isSaved(dayID))                                      // the day is whole again
        let fetched = await pictureRequests(server)
        withKnownIssue("B5: an unreadable manifest makes the sync delete the saved pictures") {
            #expect(fetched == 0)                                              // they were all on the phone
        }
    }

    // MARK: Saved copies going stale (card B6)

    @Test func aSavedDayThatGrewGetsItsNewPhotosWithCropsOff() async throws {
        // ios.md: "Frames added to a saved day never get their pictures when "Include 1:1 focus
        // crops" is off" (card B6). The first pass skips a saved day, and the top-up, the only
        // pass that would fetch the new photos, runs only with crops on.
        let body = SendableBox(dayBody([1, 2]))
        let rig = SyncRig(
            .fresh([planDay("2026-10-01", frames: 2, decided: 1)]), settings: FakeOfflineSettings(crops: false),
            network: pc(body))
        await rig.syncNow()
        #expect(rig.store.isSaved(dayID))

        // Photo 3 is ingested into the day later.
        body.value = dayBody([1, 2, 3])
        rig.list.answer(.fresh([planDay("2026-10-01", frames: 3, decided: 1)]))
        await rig.syncNow()
        withKnownIssue("B6: a saved day that grows is not filled in while 1:1 crops are off") {
            #expect(rig.store.hasImage(.thumb, id: 3))
            #expect(rig.store.hasImage(.view, id: 3))
            #expect(rig.store.record(for: dayID)?.photos.contains(3) == true)
        }
    }

    @Test func aSavedDayThatGrewGetsItsNewPhotosFromTheTopUpWithCropsOn() async throws {
        // Right today: with crops on, the top-up fetches what the day lacks, pictures included.
        let body = SendableBox(dayBody([1, 2]))
        let rig = SyncRig(.fresh([planDay("2026-10-01", frames: 2, decided: 1)]), network: pc(body))
        await rig.syncNow()
        body.value = dayBody([1, 2, 3])
        rig.list.answer(.fresh([planDay("2026-10-01", frames: 3, decided: 1)]))
        await rig.syncNow()
        for kind in OfflineImageKind.allCases { #expect(rig.store.hasImage(kind, id: 3)) }
        #expect(rig.store.record(for: dayID)?.photos == [1, 2, 3])
        #expect(rig.store.record(for: dayID)?.frames == 3)
        #expect(rig.store.isSaved(dayID))
    }

    /// A saved day over a fake PC, and a way to open it, with the client going through the
    /// phone's saved days as the app's does.
    private struct SavedDay {
        let server: CullServer
        let store: OfflineStore
        let root = TempRoot()
        let sleeper = ManualSleeper()
        let queue: CullWriteQueue
        let client: CullingBayClient
        let ids = ActionIDs()

        @MainActor
        init(_ day: CullDay) throws {
            server = CullServer(day: day)
            store = root.store()
            let photos = day.stacks.flatMap(\.frames).map(\.id)
            try store.begin(day: day.day, frames: photos.count, photos: photos)
            try store.writeDay(day.day, Data(cullJSON(day).utf8))
            try store.finish(day: day.day)
            let phone = store
            client = CullingBayClient(
                baseURL: testBaseURL,
                transport: OfflineTransport(base: server.transport(), store: phone, isEnabled: { true }))
            queue = CullWriteQueue(client: client, store: InMemoryCullWriteStore(), sleep: sleeper.sleep)
        }

        @MainActor
        func open() -> CullSessionModel {
            let ids = ids
            return CullSessionModel(
                day: "2026/2026-10-01", client: client, queue: queue, sleep: sleeper.sleep,
                keepsDaysOffline: { true }, newActionID: { ids.next() })
        }

        func goOffline() {
            for route in ["GET /m/api/day", "POST /m/api/decide", "POST /m/api/undo", "PUT progress"] {
                server.on(route) { _ in throw CullingBayError.transport("offline") }
            }
        }
    }

    private func fourStacks(decided: Int? = nil) -> CullDay {
        cullDay((0..<4).map { index in
            let id = 100 + index
            return cullStack(index, .single, [cullFrame(
                id, file: "S\(id).ARW", decision: id == decided ? draft(.pick) : nil)])
        })
    }

    @Test func aSavedDayReopenedOfflineShowsTheTapsThatWereSentOnline() async throws {
        // ios.md: "A saved day opens offline with the decisions and position it had when it was
        // last fetched, not what Danny did since" (card B6). Only a GET of the day rewrites the
        // copy; a decide or a position save that reached the PC leaves it as it was.
        let saved = try SavedDay(fourStacks())
        let first = saved.open()
        await first.load()                                                     // online
        first.keep()                                                           // 100 kept, on to 101
        first.reject()                                                         // 101 rejected, on to 102
        #expect(await saved.sleeper.waitFor(CullSessionModel.progressDelay))
        await saved.sleeper.release(CullSessionModel.progressDelay)
        let queue = saved.queue
        #expect(await eventually { await queue.pending == 0 })                 // every tap reached the PC
        #expect(saved.server.calls("/m/api/decide").count == 2)
        #expect(saved.server.calls("/progress").count == 1)
        first.close()

        saved.goOffline()
        let again = saved.open()
        await again.load()
        #expect(again.phase == .loaded)                                        // right today: the copy opens
        withKnownIssue("B6: the phone's copy of a day is not updated after a tap is saved") {
            #expect(again.decisions[100]?.flag == .pick)
            #expect(again.decisions[101]?.flag == .reject)
            #expect(again.cursor == 2)
        }
    }

    @Test func anUndoQueuedOfflineTakesBackADecideThatWasAlreadySent() async throws {
        // ios.md, the same finding: "if the decide was already sent and only its undo is queued,
        // layQueued ignores the .undo (no matching queued decide), so the undone decision shows
        // as still decided."
        let saved = try SavedDay(fourStacks())
        let first = saved.open()
        await first.load()
        first.keep()                                                           // sent at once
        let queue = saved.queue
        #expect(await eventually { await queue.pending == 0 })
        // The PC has the decision now, and opening the day again saves it into the phone's copy.
        saved.server.setDay(fourStacks(decided: 100))
        let look = saved.open()
        await look.load()
        look.close()
        let copy = try JSONDecoder().decode(CullDay.self, from: try #require(saved.store.readDay(dayID)))
        #expect(copy.stacks[0].frames[0].decision?.flag == .pick)

        saved.goOffline()
        first.undo()                                                           // waits in the queue
        #expect(await eventually { await queue.pending == 1 })
        let again = saved.open()
        await again.load()
        withKnownIssue("B6: a queued undo of a decide the PC already has is not laid over the copy") {
            #expect(again.decisions[100] == nil)
        }
    }

    // MARK: Housekeeping

    @Test func aFullPhoneIsNotReportedAsThePCBeingOutOfReach() async {
        // ios.md: "Offline store housekeeping gaps", (a): "isOutOfReach returns true for any
        // non-CullingBayError, so a full disk or file error while writing is reported as "Can't
        // reach the PC", ends the sync and retries from scratch." Settings shows `.offline` as
        // "Can't reach the PC · showing saved days".
        let rig = SyncRig(.fresh([planDay("2026-10-01", frames: 2, decided: 1)]))
        rig.fake.fail(dayID, with: CocoaError(.fileWriteOutOfSpace))
        await rig.syncNow()
        withKnownIssue("Housekeeping (a): a file error on the phone reads as the PC being out of reach") {
            #expect(rig.sync.state != .offline)
            #expect(!OfflineSync.isOutOfReach(CocoaError(.fileWriteOutOfSpace)))
        }
    }

    @Test func aForegroundSyncLeavesADayThatHasEverythingAlone() async throws {
        // ios.md: "Offline store housekeeping gaps", (c): "Each foreground runs the top-up pass,
        // which GETs the day JSON of every kept day again and rewrites it plus the manifest twice
        // (begin also resets savedAt) even when nothing is missing".
        let server = pc(SendableBox(dayBody([1, 2])))
        let rig = SyncRig(.fresh([planDay("2026-10-01", frames: 2, decided: 1)]), network: server)
        await rig.syncNow()
        for kind in OfflineImageKind.allCases { #expect(rig.store.hasImage(kind, id: 2)) }
        let before = await server.requests.count
        let savedAt = rig.store.record(for: dayID)?.savedAt

        await rig.syncNow()                                                    // the app comes back
        let after = await server.requests.count
        #expect(await pictureRequests(server) == 4)                            // right today: no picture again
        withKnownIssue("Housekeeping (c): the top-up fetches and rewrites a day that lacks nothing") {
            #expect(after == before)
            #expect(rig.store.record(for: dayID)?.savedAt == savedAt)
        }
    }
}
