import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import CullingBayCore

/// The sync loop that keeps days on the phone, as it decides today: what it plans and fetches and
/// in which order, what it deletes, how it ends, and how it is started and stopped.
@MainActor
@Suite("Offline: the sync loop")
struct OfflineSyncTests {
    // Newest first, as the server sends them. With crops a frame is planned at 570 kB, so with a
    // 0.5 GB limit the three planned days (114 + 171 + 171 MB) fit and `huge` (1.14 GB) cannot.
    private let newest = planDay("2026-10-06", frames: 300)                                   // untouched
    private let started = planDay("2026-10-05", frames: 300, decided: 20)                     // partly culled
    private let huge = planDay("2026-10-04", frames: 2000)                                    // untouched, too big
    private let pinned = planDay("2026-10-03", frames: 200, decided: 200, sent: 200, finished: true)
    private let done = planDay("2026-10-02", frames: 50, decided: 50, sent: 50, finished: true)
    private let skipped = planDay("2026-10-01", frames: 10, decided: 5)                       // pinned never

    private var library: [Day] { [newest, started, huge, pinned, done, skipped] }

    private func ids(_ days: [Day]) -> [String] { days.map(\.day) }

    // MARK: What is fetched, in which order

    @Test func pinnedThenPartlyCulledThenNewestWithinTheLimitPicturesFirstThenTheCrops() async {
        let settings = FakeOfflineSettings(limitGB: 0.5, pins: [pinned.day: .always, skipped.day: .never])
        let rig = SyncRig(.fresh(library), settings: settings)
        await rig.syncNow()

        let calls = rig.fake.calls
        #expect(calls.map(\.day) == ids([pinned, started, newest, pinned, started, newest]))
        // Pass one: the pictures of every planned day, none of them saved yet.
        #expect(calls.prefix(3).allSatisfy { !$0.includeCrops && !$0.topUp && !$0.wasSaved })
        // Pass two: the 1:1 crops, a top-up of days that are saved and stay saved.
        #expect(calls.suffix(3).allSatisfy { $0.includeCrops && $0.topUp && $0.wasSaved })

        #expect(rig.sync.plan.kept.map(\.reason) == [.always, .inProgress, .newest])
        #expect(rig.sync.plan.entry(for: huge.day)?.fits == false)
        #expect(rig.sync.plan.entry(for: done.day) == nil)                // finished, nothing to send
        #expect(rig.sync.plan.entry(for: skipped.day) == nil)             // pinned never
        #expect(rig.sync.savedDays == Set(ids([pinned, started, newest])))
        #expect(rig.sync.days.map(\.day) == ids(library))
        #expect(rig.sync.state == .idle)
        #expect(rig.sync.syncingDay == nil)
        #expect(rig.list.calls == 1)
    }

    @Test func thePlanIsMadeAgainAfterEachDaySoASavedDayCountsAtItsRealSize() async {
        // 3 × 171 MB is over 0.5 GB, so the third day does not fit at first. Once the first is
        // saved it counts at what it takes on disk (nothing, here), and the third fits.
        let a = planDay("2026-10-03", frames: 300, decided: 1)
        let b = planDay("2026-10-02", frames: 300, decided: 1)
        let c = planDay("2026-10-01", frames: 300, decided: 1)
        let rig = SyncRig(.fresh([a, b, c]), settings: FakeOfflineSettings(limitGB: 0.5, crops: true))
        await rig.sync.reload()
        #expect(rig.sync.plan.kept.map(\.id) == ids([a, b]))

        await rig.syncNow()
        #expect(rig.fake.calls.filter { !$0.topUp }.map(\.day) == ids([a, b, c]))
        #expect(rig.sync.savedDays == Set(ids([a, b, c])))
    }

    @Test func withCropsOffThereIsNoTopUpAndThePlanCountsNoCrops() async {
        let settings = FakeOfflineSettings(crops: false)
        let rig = SyncRig(.fresh([newest, started]), settings: settings)
        await rig.sync.reload()
        #expect(rig.sync.plan.entry(for: started.day)?.estimatedBytes == 300 * 350_000)

        await rig.syncNow()
        #expect(rig.fake.calls.map(\.day) == ids([started, newest]))
        #expect(rig.fake.calls.allSatisfy { !$0.includeCrops && !$0.topUp })
        #expect(rig.sync.state == .idle)

        // With crops on, the estimate has them in.
        let withCrops = SyncRig(.fresh([newest, started]), settings: FakeOfflineSettings(crops: true))
        await withCrops.sync.reload()
        #expect(withCrops.sync.plan.entry(for: started.day)?.estimatedBytes == 300 * 570_000)
    }

    @Test func withTheRealDownloaderEveryDaysPicturesComeBeforeAnyCropAndTheDayStaysSaved() async throws {
        let first = planDay("2026-10-02", frames: 2, decided: 1)
        let second = planDay("2026-10-01", frames: 2)
        let bodies = [
            first.day: cullJSON(cullDay([cullStack(0, .single, [cullFrame(1)]), cullStack(1, .single, [cullFrame(2)])])),
            second.day: cullJSON(cullDay([cullStack(0, .burst, [cullFrame(3), cullFrame(4, af: [0.5, 0.5])])])),
        ]
        let root = TempRoot()
        let savedAtCrop = SendableLog<Bool>()
        let pc = FakeTransport { request, _ in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/m/api/day/") {
                return jsonResponse(bodies[String(path.dropFirst("/m/api/day/".count))] ?? "", for: request)
            }
            if path.hasPrefix("/m/api/crop/") {
                let id = Int(path.split(separator: "/").last ?? "") ?? 0
                let day = id <= 2 ? first.day : second.day
                savedAtCrop.append(root.store().isSaved(day))                 // the manifest on disk now
            }
            return (Data("jpeg".utf8), makeResponse(for: request))
        }
        let rig = SyncRig(.fresh([first, second]), root: root, network: pc)
        await rig.syncNow()

        // Each request in order, as "day <id>", "img" or "crop".
        let steps = await pc.requests.map { request -> String in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/m/api/day/") { return "day " + path.dropFirst("/m/api/day/".count) }
            return path.hasPrefix("/m/api/crop/") ? "crop" : "img"
        }
        let img = Array(repeating: "img", count: 4)
        let crop = Array(repeating: "crop", count: 2)
        #expect(steps == ["day \(first.day)"] + img + ["day \(second.day)"] + img
            + ["day \(first.day)"] + crop + ["day \(second.day)"] + crop)
        #expect(savedAtCrop.all == [true, true, true, true])                  // keepingComplete
        #expect(rig.store.isSaved(first.day) && rig.store.isSaved(second.day))
        for id in 1...4 { #expect(rig.store.hasImage(.af, id: id)) }
        #expect(rig.sync.totalBytes == rig.store.totalBytes)
        #expect(rig.sync.state == .idle)
    }

    // MARK: What is deleted

    @Test func aDayThatLeavesThePlanIsDeletedWhenThePinSyncsAgain() async {
        let rig = SyncRig(.fresh([newest, started]))
        await rig.syncNow()
        #expect(rig.sync.savedDays == Set(ids([newest, started])))

        rig.sync.pin(newest.day, .never)
        await rig.sync.settled()
        #expect(rig.store.record(for: newest.day) == nil)
        #expect(rig.sync.savedDays == [started.day])
        #expect(rig.sync.pins == [newest.day: .never])
        #expect(rig.settings.saves == [[newest.day: .never]])
        #expect(rig.list.calls == 2)
    }

    @Test func aHalfFetchedDayThatIsNotPlannedIsDeletedWithItsPictures() async throws {
        let rig = SyncRig(.fresh([started]))
        let gone = "2026/2026-09-01"
        try rig.store.begin(day: gone, frames: 1, photos: [7])
        try rig.store.writeImage(Data("p".utf8), kind: .thumb, id: 7)
        await rig.syncNow()
        #expect(rig.store.record(for: gone) == nil)
        #expect(!rig.store.hasImage(.thumb, id: 7))
        #expect(rig.store.isSaved(started.day))
    }

    @Test func anEmptyDaysListDeletesNothing() async throws {
        let first = SyncRig(.fresh([started]))
        await first.syncNow()
        let rig = SyncRig(.fresh([]), root: first.root)
        await rig.syncNow()
        #expect(rig.store.isSaved(started.day))
        #expect(rig.fake.calls.isEmpty)
        #expect(rig.sync.state == .idle)
    }

    @Test func picturesNoRecordAccountsForAreDeletedBeforeAnythingIsFetched() async throws {
        let gate = CallGate()
        let rig = SyncRig(.fresh([started]), gate: gate)
        try rig.store.writeImage(Data("p".utf8), kind: .view, id: 9)
        try rig.store.writeDay("2026/2026-01-01", Data("{}".utf8))
        rig.sync.sync()
        #expect(await gate.waitForArrivals(1))
        #expect(!rig.store.hasImage(.view, id: 9))
        #expect(rig.store.readDay("2026/2026-01-01") == nil)
        for index in 0..<2 { await gate.open(index) }
        await rig.sync.settled()
        #expect(rig.store.isSaved(started.day))
    }

    @Test func aDaysListFromThePhonesCopyFetchesAndDeletesNothing() async throws {
        let first = SyncRig(.fresh([newest, started]))
        await first.syncNow()
        try first.store.writeImage(Data("p".utf8), kind: .view, id: 9)        // an orphan, kept too
        // The copy has only one of the two saved days, and a day the phone does not have.
        let rig = SyncRig(.savedCopy([started, huge]), root: first.root)
        await rig.syncNow()
        #expect(rig.sync.state == .offline)
        #expect(rig.fake.calls.isEmpty)
        #expect(rig.store.isSaved(newest.day) && rig.store.isSaved(started.day))
        #expect(rig.store.hasImage(.view, id: 9))
        #expect(rig.sync.days.map(\.day) == ids([started, huge]))
        #expect(rig.sync.plan.entry(for: started.day) != nil)                  // the plan is still made
    }

    // MARK: Switching off

    @Test func switchingOffDeletesEveryCopy() async throws {
        let rig = SyncRig(.fresh([newest, started]))
        await rig.syncNow()
        try rig.store.writeDays(Data("{}".utf8))
        #expect(rig.sync.totalBytes > 0)

        rig.settings.set(enabled: false)
        rig.sync.settingsChanged()
        #expect(rig.sync.state == .off)                                       // at once
        await rig.sync.settled()
        #expect(rig.store.records.isEmpty)
        #expect(rig.store.readDays() == nil)
        #expect(rig.store.totalBytes == 0)
        #expect(rig.sync.savedDays.isEmpty)
        #expect(rig.sync.totalBytes == 0)
        #expect(rig.sync.plan == .empty)
        #expect(rig.sync.state == .off)
        #expect(rig.list.calls == 1)                                           // and no sync followed
    }

    @Test func switchingOffMidFetchWaitsForTheFetchThenWipesAndStaysOff() async throws {
        let gate = CallGate()
        let rig = SyncRig(.fresh([newest, started]), gate: gate)
        try rig.store.writeImage(Data("p".utf8), kind: .view, id: 1)
        try rig.store.begin(day: started.day, frames: 1, photos: [1])          // the fetch's files so far
        rig.sync.sync()
        #expect(await gate.waitForArrivals(1))
        #expect(rig.sync.syncingDay == started.day)
        #expect(rig.sync.state == .syncing(dayTitle: "Mon, 5 Oct 2026", done: 0, total: 0))

        rig.settings.set(enabled: false)
        rig.sync.settingsChanged()
        #expect(rig.sync.state == .off)
        #expect(rig.sync.syncingDay == nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.store.hasImage(.view, id: 1))                              // not while the fetch holds it

        await gate.open(0)                                                     // the fetch sees it was stopped
        await rig.sync.settled()
        #expect(rig.store.records.isEmpty)
        #expect(!rig.store.hasImage(.view, id: 1))
        #expect(rig.fake.calls.map(\.day) == [started.day])                    // and nothing after it
        #expect(rig.sync.state == .off)
    }

    @Test func withOfflineOffNothingRuns() async {
        let rig = SyncRig(.fresh([started]), settings: FakeOfflineSettings(enabled: false))
        #expect(rig.sync.state == .off)
        await rig.syncNow()
        await rig.sync.reload()
        #expect(rig.list.calls == 0)
        #expect(rig.fake.calls.isEmpty)
        #expect(rig.sync.days.isEmpty)
        #expect(rig.backups.count == 0)
        #expect(rig.sync.state == .off)
    }

    // MARK: How a sync ends

    @Test func aLostConnectionEndsTheSyncAsOffline() async {
        let rig = SyncRig(.fresh([newest, started]))
        rig.fake.fail(started.day, with: CullingBayError.transport("The Internet connection appears to be offline."))
        await rig.syncNow()
        #expect(rig.fake.calls.map(\.day) == [started.day])                    // no other day, no crops
        #expect(rig.sync.state == .offline)
        #expect(rig.sync.syncingDay == nil)
        #expect(!rig.store.isSaved(started.day))
    }

    @Test func aRefusedDayIsLeftForNextTimeTheOthersStillComeAndTheCropsWait() async {
        let rig = SyncRig(.fresh([newest, started]))
        rig.fake.fail(started.day, with: CullingBayError.http(status: 404, message: nil))
        await rig.syncNow()
        #expect(rig.fake.calls.map(\.day) == ids([started, newest]))           // each tried once, no top-up
        #expect(rig.sync.state == .failed("The PC answered: HTTP 404"))
        #expect(rig.store.isSaved(newest.day))
        #expect(!rig.store.isSaved(started.day))

        // The next sync tries it again.
        rig.fake.succeed(started.day)
        await rig.syncNow()
        #expect(rig.fake.calls.dropFirst(2).map(\.day) == ids([started, started, newest]))
        #expect(rig.fake.calls.dropFirst(3).allSatisfy { $0.topUp })
        #expect(rig.sync.state == .idle)
    }

    @Test func aServerErrorEndsTheSyncLikeARefusal() async {
        let rig = SyncRig(.fresh([newest, started]))
        rig.fake.fail(started.day, with: CullingBayError.http(status: 500, message: "boom"))
        await rig.syncNow()
        #expect(rig.fake.calls.map(\.day) == ids([started, newest]))
        #expect(rig.sync.state == .failed("The PC answered: boom"))
        #expect(rig.store.isSaved(newest.day))
    }

    @Test func aFileErrorStopsTheSync() async {
        // How it is reported is a known issue: see OfflineGapTests.
        let rig = SyncRig(.fresh([newest, started]))
        rig.fake.fail(started.day, with: CocoaError(.fileWriteOutOfSpace))
        await rig.syncNow()
        #expect(rig.fake.calls.map(\.day) == [started.day])                    // no other day, no crops
        #expect(!rig.store.isSaved(started.day))
        #expect(rig.sync.syncingDay == nil)
    }

    @Test func aTopUpTheServerRefusesLeavesTheOtherTopUpsToRun() async {
        let rig = SyncRig(.fresh([newest, started]))
        rig.fake.fail(started.day, topUp: true, with: CullingBayError.http(status: 404, message: nil))
        await rig.syncNow()
        #expect(rig.fake.calls.map(\.day) == ids([started, newest, started, newest]))
        #expect(rig.sync.state == .failed("The PC answered: HTTP 404"))
        #expect(rig.store.isSaved(started.day))                                // still saved, crops or not
    }

    @Test func aTopUpThatLosesTheConnectionEndsTheSyncAsOffline() async {
        let rig = SyncRig(.fresh([newest, started]))
        rig.fake.fail(started.day, topUp: true, with: CullingBayError.transport("offline"))
        await rig.syncNow()
        #expect(rig.fake.calls.map(\.day) == ids([started, newest, started]))
        #expect(rig.sync.state == .offline)
        #expect(rig.store.isSaved(started.day))
    }

    @Test func aDaysListThatFailsEndsTheSyncBeforeAnythingIsFetchedOrDeleted() async throws {
        let first = SyncRig(.fresh([started]))
        await first.syncNow()
        try first.store.writeImage(Data("p".utf8), kind: .view, id: 9)        // an orphan, kept

        let lost = SyncRig(.failure(CullingBayError.transport("offline")), root: first.root)
        await lost.syncNow()
        #expect(lost.sync.state == .offline)

        let refused = SyncRig(.failure(CullingBayError.http(status: 500, message: nil)), root: first.root)
        await refused.syncNow()
        #expect(refused.sync.state == .failed("The PC answered: HTTP 500"))

        for rig in [lost, refused] {
            #expect(rig.fake.calls.isEmpty)
            #expect(rig.sync.days.isEmpty)
        }
        #expect(first.store.hasImage(.view, id: 9))
        #expect(first.root.store().isSaved(started.day))
    }

    @Test func theWordsForEachKindOfError() {
        #expect(OfflineSync.message(for: CullingBayError.http(status: 500, message: nil)) == "The PC answered: HTTP 500")
        #expect(OfflineSync.message(for: CullingBayError.http(status: 404, message: "no such day")) == "The PC answered: no such day")
        #expect(OfflineSync.message(for: CullingBayError.unavailable(message: nil)) == "The PC refused.")
        #expect(OfflineSync.message(for: CullingBayError.unavailable(message: "No inbox")) == "No inbox")
        #expect(OfflineSync.message(for: CullingBayError.conflict(message: nil, applied: 3)) == "The PC refused.")
        #expect(OfflineSync.message(for: CullingBayError.decoding("The day could not be read: x")) == "The day could not be read: x")
        #expect(OfflineSync.message(for: CullingBayError.transport("timed out")) == "timed out")

        #expect(OfflineSync.isOutOfReach(CullingBayError.transport("timed out")))
        #expect(!OfflineSync.isOutOfReach(CullingBayError.http(status: 404, message: nil)))
        #expect(!OfflineSync.isOutOfReach(CullingBayError.http(status: 503, message: nil)))
        #expect(!OfflineSync.isOutOfReach(CullingBayError.unavailable(message: nil)))
        #expect(!OfflineSync.isOutOfReach(CullingBayError.conflict(message: nil, applied: nil)))
        #expect(!OfflineSync.isOutOfReach(CullingBayError.decoding("x")))
    }

    // MARK: Starting and stopping

    @Test func aForegroundSyncOnlyTopsUpTheSavedDays() async {
        let rig = SyncRig(.fresh([newest, started]))
        await rig.syncNow()
        #expect(rig.fake.calls.count == 4)
        await rig.syncNow()                                                    // the app comes back
        let again = rig.fake.calls.dropFirst(4)
        #expect(again.map(\.day) == ids([started, newest]))
        #expect(again.allSatisfy { $0.topUp && $0.includeCrops && $0.wasSaved })
        #expect(rig.list.calls == 2)
        #expect(rig.sync.state == .idle)
    }

    @Test func withCropsOffAForegroundSyncFetchesNothing() async {
        let rig = SyncRig(.fresh([newest, started]), settings: FakeOfflineSettings(crops: false))
        await rig.syncNow()
        await rig.syncNow()
        #expect(rig.fake.calls.count == 2)
        #expect(rig.list.calls == 2)
        #expect(rig.sync.state == .idle)
    }

    @Test func aSyncAskedForWhileOneRunsFollowsItOnce() async {
        let gate = CallGate()
        let rig = SyncRig(.fresh([started]), gate: gate)
        rig.sync.sync()
        #expect(await gate.waitForArrivals(1))
        rig.sync.sync()
        rig.sync.sync()
        rig.sync.sync()
        for index in 0..<8 { await gate.open(index) }
        await rig.sync.settled()
        #expect(rig.list.calls == 2)                                           // one more, not three
        #expect(rig.fake.calls.map(\.topUp) == [false, true, true])
    }

    @Test func goingToTheBackgroundStopsTheSyncAndDropsTheOneQueued() async {
        let gate = CallGate()
        let rig = SyncRig(.fresh([newest, started]), gate: gate)
        rig.sync.sync()
        #expect(await gate.waitForArrivals(1))
        rig.sync.sync()                                                        // queued behind it
        rig.sync.cancel()
        await gate.open(0)
        await rig.sync.settled()
        #expect(rig.fake.calls.map(\.day) == [started.day])
        #expect(rig.list.calls == 1)
        #expect(!rig.store.isSaved(started.day))
        #expect(rig.sync.state == .idle)
        #expect(rig.sync.syncingDay == nil)
    }

    @Test func settingChangesWaitForTheLastOneThenSyncOnce() async {
        let rig = SyncRig(.fresh([started]))
        rig.sync.settingsChanged()
        rig.sync.settingsChanged()
        rig.sync.settingsChanged()
        #expect(await rig.sleeper.waitFor(OfflineSync.settleDelay))
        #expect(await eventually { await rig.sleeper.waiting.count == 1 })
        #expect(await rig.sleeper.requested == [.seconds(1), .seconds(1), .seconds(1)])
        #expect(rig.list.calls == 0)
        await rig.sleeper.release(OfflineSync.settleDelay)
        await rig.sync.settled()
        #expect(rig.list.calls == 1)
        #expect(rig.store.isSaved(started.day))
    }

    @Test func aPinChangedMidSyncStopsTheSyncAndStartsOver() async {
        let gate = CallGate()
        let rig = SyncRig(.fresh([newest, started]), gate: gate)
        rig.sync.sync()
        #expect(await gate.waitForArrivals(1))
        rig.sync.pin(started.day, .never)                                      // the day being fetched
        for index in 0..<4 { await gate.open(index) }
        await rig.sync.settled()
        // The fetch was stopped, and the sync started over with the new plan.
        #expect(rig.fake.calls.map(\.day) == ids([started, newest, newest]))
        #expect(rig.fake.calls.map(\.topUp) == [false, false, true])
        #expect(rig.store.record(for: started.day) == nil)
        #expect(rig.list.calls == 2)
        #expect(rig.sync.savedDays == [newest.day])
    }

    @Test func switchingOnShowsIdleAtOnce() async {
        let settings = FakeOfflineSettings(enabled: false)
        let rig = SyncRig(.fresh([started]), settings: settings)
        #expect(rig.sync.state == .off)
        settings.set(enabled: true)
        rig.sync.settingsChanged()
        #expect(rig.sync.state == .idle)
        #expect(rig.list.calls == 0)                                           // the sync waits for the pause
    }

    @Test func aPinWithOfflineOffIsSavedAndPlannedButNotSynced() async {
        let settings = FakeOfflineSettings(enabled: false, pins: [started.day: .never])
        let rig = SyncRig(.fresh([started]), settings: settings)
        #expect(rig.sync.pins == [started.day: .never])                        // loaded at the start
        rig.sync.pin(newest.day, .always)
        #expect(rig.sync.pins == [started.day: .never, newest.day: .always])
        rig.sync.pin(started.day, .auto)                                       // auto is no pin at all
        #expect(rig.sync.pins == [newest.day: .always])
        #expect(settings.saves == [[started.day: .never, newest.day: .always], [newest.day: .always]])
        await rig.sync.settled()
        #expect(rig.list.calls == 0)
    }

    @Test func theFolderIsKeptOutOfBackupsOnceByTheFirstSyncWithOfflineOn() async {
        let rig = SyncRig(.fresh([started]))
        #expect(rig.backups.count == 0)
        await rig.syncNow()
        await rig.syncNow()
        #expect(rig.backups.count == 1)
    }

    @Test func theProgressShownNeverGoesBack() async {
        let gate = CallGate()
        let rig = SyncRig(.fresh([started]), settings: FakeOfflineSettings(crops: false), gate: gate)
        rig.fake.report([[5, 9], [2, 9]])
        rig.sync.sync()
        #expect(await gate.waitForArrivals(1))
        let title = "Mon, 5 Oct 2026"
        let sync = rig.sync
        #expect(await eventually { @MainActor in sync.state == .syncing(dayTitle: title, done: 5, total: 9) })
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.sync.state == .syncing(dayTitle: title, done: 5, total: 9))
        await gate.open(0)
        await rig.sync.settled()
        #expect(rig.sync.state == .idle)
    }

    @Test func theChooseDaysListMakesThePlanWithoutFetchingAnything() async {
        let rig = SyncRig(.savedCopy([newest, started]))
        await rig.sync.reload()
        #expect(rig.sync.days.map(\.day) == ids([newest, started]))
        #expect(rig.sync.plan.kept.map(\.id) == ids([started, newest]))
        #expect(rig.fake.calls.isEmpty)
        #expect(rig.sync.state == .idle)

        // A list that cannot be read keeps the one it had.
        rig.list.answer(.failure(CullingBayError.transport("offline")))
        await rig.sync.reload()
        #expect(rig.sync.days.map(\.day) == ids([newest, started]))
    }

    @Test func itStartsFromWhatTheStoreHasAndTheSwitch() async throws {
        let first = SyncRig(.fresh([started]))
        await first.syncNow()
        let on = SyncRig(.fresh([started]), root: first.root)
        #expect(on.sync.savedDays == [started.day])
        #expect(on.sync.state == .idle)
        let off = SyncRig(.fresh([started]), settings: FakeOfflineSettings(enabled: false), root: first.root)
        #expect(off.sync.state == .off)
    }
}
