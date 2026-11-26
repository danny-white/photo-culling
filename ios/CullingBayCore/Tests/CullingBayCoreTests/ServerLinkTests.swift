import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import CullingBayCore

// MARK: A PC on a fake network

/// The PC at the other end: it answers, fails at the network level, keeps silent, or answers
/// every request with one status, as the test sets. It records every request (`GET /m/api/ping`).
/// With `holdPings`, each ping waits at `pings` until the test opens it.
final class FakePC: HTTPTransport, Sendable {
    enum Mode: Sendable {
        case up
        /// No answer: the request fails with this network error.
        case failing(URLError.Code)
        /// No answer at all until the request is cancelled, as a network that swallows packets.
        case silent
        case status(Int)
    }

    static let down = Mode.failing(.cannotConnectToHost)

    private let state: Mutex<(mode: Mode, log: [String])>
    let pings: CallGate?

    init(_ mode: Mode, holdPings: Bool = false) {
        state = Mutex((mode, []))
        pings = holdPings ? CallGate() : nil
    }

    var mode: Mode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue } }
    }

    /// `GET /m/api/ping`, `POST /m/api/decide`, ... in order.
    var log: [String] { state.withLock { $0.log } }
    var pingCount: Int { log.filter { $0 == "GET /m/api/ping" }.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let (mode, index) = state.withLock { state in
            state.log.append("\(method) \(path)")
            return (state.mode, state.log.filter { $0 == "GET /m/api/ping" }.count - 1)
        }
        if path == "/m/api/ping", let pings { await pings.pass(index) }
        switch mode {
        case .failing(let code):
            throw URLError(code)
        case .silent:
            try await Task.sleep(for: .seconds(600))
            throw URLError(.timedOut)
        case .status(let status):
            return jsonResponse(#"{"error":"busy"}"#, for: request, status: status)
        case .up:
            if path == "/m/api/ping" { return (Data(), makeResponse(for: request, status: 204)) }
            if path == "/m/api/days" { return jsonResponse(daysResponseJSON([dayFullJSON]), for: request) }
            if path.hasPrefix("/m/api/day/") { return jsonResponse(cullDayJSON, for: request) }
            if path.hasPrefix("/m/api/crop/") {
                return (Data("jpeg".utf8), makeResponse(for: request, headers: ["X-Crop-Box": "0,0,64,64,8000,5320"]))
            }
            return jsonResponse(#"{"ok":true}"#, for: request)
        }
    }
}

/// Work offline, kept in memory, as `UserDefaults` keeps it across launches in the app.
final class MemoryWorkOffline: WorkOfflineSetting {
    var isOn = false
}

/// A link over a fake PC, with the client and write queue going through it and through the days
/// saved on the phone, as the app wires them. Reaching the PC again sends the queue
/// (`onReachable`), as the app does.
@MainActor
struct LinkRig {
    let pc: FakePC
    let sleeper = ManualSleeper()
    let setting: MemoryWorkOffline
    let link: ServerLink
    let root = TempRoot()
    let store: OfflineStore
    let gated: ServerLinkTransport
    let client: CullingBayClient
    let queue: CullWriteQueue
    let reached = Tally()
    let stopped = Tally()

    static let savedDay = "2026/2026-10-01"
    static let unsavedDay = "2026/2026-09-29"

    init(_ mode: FakePC.Mode, setting: MemoryWorkOffline = MemoryWorkOffline(), keepsDays: Bool = true,
         holdPings: Bool = false) throws {
        pc = FakePC(mode, holdPings: holdPings)
        self.setting = setting
        link = ServerLink(baseURL: testBaseURL, network: pc, setting: setting, sleep: sleeper.sleep)
        store = root.store()
        try store.writeDays(Data(daysResponseJSON([dayFullJSON]).utf8))
        try store.begin(day: Self.savedDay, frames: 1, photos: [43220])
        try store.writeDay(Self.savedDay, Data(cullDayJSON.utf8))
        try store.writeImage(Data("saved thumb".utf8), kind: .thumb, id: 43220)
        try store.finish(day: Self.savedDay)
        gated = ServerLinkTransport(base: pc, gate: link.gate)
        client = CullingBayClient(
            baseURL: testBaseURL, transport: OfflineTransport(base: gated, store: store, isEnabled: { keepsDays }))
        queue = CullWriteQueue(client: client, store: InMemoryCullWriteStore(), sleep: sleeper.sleep)
        let queue = queue, reached = reached, stopped = stopped
        link.onReachable = {
            reached.count += 1
            queue.resume()
        }
        link.onWorkOffline = { stopped.count += 1 }
    }

    func keep(_ id: Int, action: String = "A-1") {
        queue.enqueue(.decide(
            actionID: action, day: Self.savedDay, label: "Keep", changes: [CullChange(id: id, flag: .pick, via: .card)]))
    }

    /// Lets the next poll's wait run out, once it is the one waiting.
    func poll(after delay: Duration) async -> Bool {
        guard await sleeper.waitFor(delay) else { return false }
        await sleeper.release(delay)
        return true
    }

    /// The poll waits still pending, without the probes' own time limits.
    func pollsWaiting() async -> [Duration] {
        await sleeper.waiting.filter { $0 != ServerLink.probeTimeout }
    }

    /// No poll is waiting, once the cancelled ones have let go.
    func noPollWaiting() async -> Bool {
        let sleeper = sleeper
        return await eventually { await sleeper.waiting.allSatisfy { $0 == ServerLink.probeTimeout } }
    }
}

@MainActor
@Suite("Offline: the connection state")
struct ServerLinkTests {
    private let unreachable = CullingBayError.transport(ServerLink.unreachableMessage)
    private let forced = CullingBayError.transport(ServerLink.forcedMessage)

    // MARK: Probe once, then fail fast

    @Test func aFailedFirstProbeMakesSavedDaysAnswerFromThePhoneWithNoRequest() async throws {
        let rig = try LinkRig(FakePC.down)
        #expect(rig.link.state == .checking)
        await rig.link.start()
        #expect(rig.link.state == .unreachable)
        #expect(rig.pc.log == ["GET /m/api/ping"])

        let days = try await rig.client.fetchDays()
        #expect(days.servedOffline)
        #expect(days.value.map(\.day) == [LinkRig.savedDay])
        let day = try await rig.client.cullDay(LinkRig.savedDay)
        #expect(day.day == LinkRig.savedDay)
        let loader = ImageDataLoader(transport: OfflineTransport(base: rig.gated, store: rig.store, isEnabled: { true }))
        let thumb = try await loader.data(for: rig.client.imageURL(id: 43220, size: .thumb))
        #expect(thumb == Data("saved thumb".utf8))
        #expect(rig.pc.log == ["GET /m/api/ping"])                            // the probe, and nothing since
    }

    @Test func whileTheProbeIsOutRequestsWaitForItsAnswer() async throws {
        let rig = try LinkRig(.up, holdPings: true)
        let link = rig.link
        let starting = Task { await link.start() }
        #expect(await rig.pc.pings!.waitForArrivals(1))
        let client = rig.client
        let fetch = Task { try await client.cullDay(LinkRig.unsavedDay) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.pc.log == ["GET /m/api/ping"])                            // the day waits for the probe
        await rig.pc.pings!.open(0)
        _ = try await fetch.value
        #expect(rig.pc.log == ["GET /m/api/ping", "GET /m/api/day/\(LinkRig.unsavedDay)"])
        await starting.value
        #expect(rig.link.state == .online)
        #expect(rig.reached.count == 0)                                       // the first probe is no recovery
    }

    @Test func aProbeWithNoAnswerInItsTimeLetsTheWaitingRequestsFailFast() async throws {
        let rig = try LinkRig(.silent)
        let link = rig.link
        let starting = Task { await link.start() }
        let pc = rig.pc
        #expect(await eventually { pc.pingCount == 1 })
        let client = rig.client
        let days = Task { try await client.fetchDays() }
        let day = Task { try await client.cullDay(LinkRig.unsavedDay) }
        // The probe's own limit, and each request's wait for it.
        #expect(await rig.sleeper.waitFor(ServerLink.probeTimeout, count: 3))
        #expect(rig.pc.log == ["GET /m/api/ping"])
        await rig.sleeper.release(ServerLink.probeTimeout)
        #expect(try await days.value.servedOffline)
        await #expect(throws: unreachable) { try await day.value }
        await starting.value
        #expect(rig.link.state == .unreachable)
        #expect(rig.pc.log == ["GET /m/api/ping"])
    }

    @Test func anUnsavedDayACropAndAWriteFailAtOnceAndTheWriteStaysQueued() async throws {
        let rig = try LinkRig(FakePC.down)
        await rig.link.start()
        await #expect(throws: unreachable) { try await rig.client.cullDay(LinkRig.unsavedDay) }
        let crop = rig.client.probeCropURL(id: 43220, center: Point(x: 0.5, y: 0.5))
        await #expect(throws: unreachable) { try await CropProbe.load(url: crop, transport: rig.gated) }
        await #expect(throws: unreachable) { try await rig.client.info(id: 43220) }
        await #expect(throws: unreachable) { try await rig.client.warm(ids: [43220]) }

        rig.keep(43220)
        let queue = rig.queue
        #expect(await eventually { await queue.isOffline })
        #expect(rig.queue.pending == 1)
        // Its retry fails the same way, and the write is still there.
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        await rig.sleeper.release(.seconds(4))
        #expect(await rig.sleeper.waitFor(.seconds(4)))
        #expect(rig.queue.pending == 1)
        #expect(rig.queue.lastDrop == nil)
        #expect(rig.pc.log == ["GET /m/api/ping"])
    }

    @Test func withDaysNotKeptOnThePhoneEverythingFailsAtOnce() async throws {
        let rig = try LinkRig(FakePC.down, keepsDays: false)
        await rig.link.start()
        await #expect(throws: unreachable) { try await rig.client.fetchDays() }
        await #expect(throws: unreachable) { try await rig.client.cullDay(LinkRig.savedDay) }
        #expect(rig.pc.log == ["GET /m/api/ping"])
    }

    // MARK: Learning from traffic

    @Test func aNetworkFailureMakesThePCUnreachableAndA503DoesNot() async throws {
        let rig = try LinkRig(.up)
        await rig.link.start()
        #expect(rig.link.state == .online)

        rig.pc.mode = .status(503)
        await #expect(throws: CullingBayError.http(status: 503, message: "busy")) {
            try await rig.client.galleryDay(LinkRig.unsavedDay)
        }
        await Task.yield()
        #expect(rig.link.gate.state == .online)
        #expect(rig.link.state == .online)

        rig.pc.mode = .failing(.timedOut)
        await #expect(throws: CullingBayError.self) { try await rig.client.galleryDay(LinkRig.unsavedDay) }
        #expect(rig.link.gate.state == .unreachable)                          // at once, for the next request
        let link = rig.link
        #expect(await eventually { await link.state == .unreachable })
        // The next one does not go.
        let before = rig.pc.log.count
        await #expect(throws: unreachable) { try await rig.client.galleryDay(LinkRig.unsavedDay) }
        #expect(rig.pc.log.count == before)
    }

    @Test func eachKindOfNetworkFailureCounts() {
        for code: URLError.Code in [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                                    .cannotFindHost, .dnsLookupFailed] {
            #expect(ServerLink.isNetworkFailure(URLError(code)))
        }
        #expect(!ServerLink.isNetworkFailure(URLError(.cancelled)))
        #expect(!ServerLink.isNetworkFailure(CancellationError()))
        #expect(!ServerLink.isNetworkFailure(CullingBayError.transport("Read-only run: POST was not sent.")))
        #expect(!ServerLink.isNetworkFailure(CullingBayError.http(status: 503, message: nil)))
    }

    @Test func aProbeAnsweredWithAnErrorStatusStillFindsThePC() async throws {
        let rig = try LinkRig(.status(503))
        await rig.link.start()
        #expect(rig.link.state == .online)
        #expect(await rig.pollsWaiting().isEmpty)
    }

    @Test func aCancelledRequestSaysNothing() async throws {
        let rig = try LinkRig(.up)
        await rig.link.start()
        rig.pc.mode = .silent
        let client = rig.client
        let request = Task { try await client.galleryDay(LinkRig.unsavedDay) }
        let pc = rig.pc
        #expect(await eventually { pc.log.count == 2 })
        request.cancel()
        _ = await request.result
        rig.pc.mode = .failing(.cancelled)                                     // the system called it off
        _ = try? await rig.client.galleryDay(LinkRig.unsavedDay)
        await Task.yield()
        #expect(rig.link.gate.state == .online)
        #expect(rig.link.state == .online)
    }

    // MARK: When it checks again

    @Test func whileUnreachableItProbesAfter5Then10Then20ThenEvery30Seconds() async throws {
        let rig = try LinkRig(FakePC.down)
        await rig.link.start()
        let pc = rig.pc
        for (n, seconds) in [5, 10, 20, 30, 30, 30].enumerated() {
            #expect(await rig.sleeper.waitFor(.seconds(seconds)))
            #expect(await rig.pollsWaiting() == [.seconds(seconds)])
            await rig.sleeper.release(.seconds(seconds))
            #expect(await eventually { pc.pingCount == n + 2 })
        }
        #expect(rig.link.state == .unreachable)
        #expect(rig.pc.log.allSatisfy { $0 == "GET /m/api/ping" })
    }

    @Test func aNetworkChangeAndTryNowProbeAtOnceAndStartTheWaitsAgain() async throws {
        let rig = try LinkRig(FakePC.down)
        await rig.link.start()
        #expect(await rig.poll(after: .seconds(5)))
        #expect(await rig.poll(after: .seconds(10)))
        #expect(await rig.sleeper.waitFor(.seconds(20)))
        #expect(rig.pc.pingCount == 3)

        rig.link.pathChanged(hasPath: true)
        let pc = rig.pc
        #expect(await eventually { pc.pingCount == 4 })
        #expect(await rig.sleeper.waitFor(.seconds(5)))
        let sleeper = rig.sleeper
        #expect(await eventually { await sleeper.waiting.filter { $0 != ServerLink.probeTimeout } == [.seconds(5)] })

        #expect(await rig.poll(after: .seconds(5)))
        #expect(await rig.sleeper.waitFor(.seconds(10)))
        await rig.link.checkNow()                                             // Try now
        #expect(rig.pc.pingCount == 6)
        #expect(await eventually { await sleeper.waiting.filter { $0 != ServerLink.probeTimeout } == [.seconds(5)] })
    }

    @Test func withNoNetworkTheLinkIsUnreachableAtOnceAndDoesNotPoll() async throws {
        let rig = try LinkRig(.up)
        await rig.link.start()
        #expect(rig.link.state == .online)
        rig.link.pathChanged(hasPath: false)
        #expect(rig.link.state == .unreachable)
        #expect(rig.link.gate.state == .unreachable)
        #expect(await rig.noPollWaiting())
        await rig.link.checkNow()                                             // no network: nothing to send it on
        #expect(rig.pc.pingCount == 1)
        #expect(await rig.noPollWaiting())

        rig.link.pathChanged(hasPath: true)                                   // the network is back
        let link = rig.link
        #expect(await eventually { await link.state == .online })
        #expect(rig.pc.pingCount == 2)
        #expect(rig.reached.count == 1)
    }

    @Test func losingTheNetworkStopsThePolls() async throws {
        let rig = try LinkRig(FakePC.down)
        await rig.link.start()
        #expect(await rig.sleeper.waitFor(.seconds(5)))
        rig.link.pathChanged(hasPath: false)
        #expect(await rig.noPollWaiting())
        #expect(rig.pc.pingCount == 1)
    }

    @Test func inTheBackgroundNothingPollsAndComingBackProbes() async throws {
        let rig = try LinkRig(FakePC.down)
        await rig.link.start()
        #expect(await rig.sleeper.waitFor(.seconds(5)))
        rig.link.setActive(false)
        #expect(await rig.noPollWaiting())
        #expect(rig.pc.pingCount == 1)

        rig.pc.mode = .up
        rig.link.setActive(true)
        let link = rig.link
        #expect(await eventually { await link.state == .online })
        #expect(rig.pc.pingCount == 2)
        #expect(await rig.pollsWaiting().isEmpty)                             // online: no polling
    }

    @Test func whileOnlineNothingPolls() async throws {
        let rig = try LinkRig(.up)
        await rig.link.start()
        _ = try await rig.client.fetchDays()
        #expect(await rig.pollsWaiting().isEmpty)
        #expect(rig.pc.log == ["GET /m/api/ping", "GET /m/api/days"])
    }

    // MARK: Reaching the PC again

    @Test func reachingThePCAgainCallsTheHookOnceAndSendsTheQueue() async throws {
        let rig = try LinkRig(FakePC.down)
        await rig.link.start()
        rig.keep(43220)
        let queue = rig.queue
        #expect(await eventually { await queue.isOffline })

        rig.pc.mode = .up
        #expect(await rig.poll(after: .seconds(5)))
        let link = rig.link
        #expect(await eventually { await link.state == .online })
        #expect(rig.reached.count == 1)
        #expect(rig.link.recoveries == 1)
        #expect(await eventually { await queue.pending == 0 })
        #expect(rig.pc.log == ["GET /m/api/ping", "GET /m/api/ping", "POST /m/api/decide"])

        // More traffic, and the app coming back to the front, are no recovery.
        _ = try await rig.client.fetchDays()
        rig.link.setActive(true)
        let pc = rig.pc
        #expect(await eventually { pc.pingCount == 3 })
        #expect(rig.reached.count == 1)
    }

    @Test func aFailedRequestStartsThePollsAndTheNextAnswerIsARecovery() async throws {
        let rig = try LinkRig(.up)
        await rig.link.start()
        rig.pc.mode = .silent
        let client = rig.client
        let slow = Task { try await client.galleryDay(LinkRig.unsavedDay) }
        let pc = rig.pc
        #expect(await eventually { pc.log.count == 2 })
        rig.pc.mode = FakePC.down
        _ = try? await rig.client.galleryDay("2026/2026-08-08")               // fails: unreachable
        let link = rig.link
        #expect(await eventually { await link.state == .unreachable })
        slow.cancel()
        _ = await slow.result
        #expect(rig.reached.count == 0)

        rig.pc.mode = .up
        #expect(await rig.poll(after: .seconds(5)))
        #expect(await eventually { await link.state == .online })
        #expect(rig.reached.count == 1)
    }

    // MARK: Work offline

    @Test func workOfflineIsKeptSendsNothingAndTurningItOffProbes() async throws {
        let setting = MemoryWorkOffline()
        let first = try LinkRig(.up, setting: setting)
        await first.link.start()
        first.link.setWorkingOffline(true)
        #expect(setting.isOn)
        #expect(first.link.state == .forcedOffline)
        #expect(first.stopped.count == 1)
        await #expect(throws: forced) { try await first.client.cullDay(LinkRig.unsavedDay) }
        #expect(first.pc.log == ["GET /m/api/ping"])
        first.link.stop()

        // The app starts again: still offline, and nothing at all is sent.
        let again = try LinkRig(.up, setting: setting)
        #expect(again.link.state == .forcedOffline)
        await again.link.start()
        again.link.setActive(true)
        again.link.pathChanged(hasPath: true)
        await again.link.checkNow()
        #expect(try await again.client.fetchDays().servedOffline)
        await #expect(throws: forced) { try await again.client.cullDay(LinkRig.unsavedDay) }
        await #expect(throws: forced) { try await again.client.info(id: 43220) }
        again.keep(43220)
        let queue = again.queue
        #expect(await eventually { await queue.isOffline })
        #expect(again.queue.pending == 1)
        #expect(await again.pollsWaiting().filter { ServerLink.pollDelays.contains($0) }.isEmpty)
        #expect(again.pc.log.isEmpty)

        // Off: a probe at once, and the taps go.
        again.link.setWorkingOffline(false)
        #expect(!setting.isOn)
        let link = again.link
        #expect(await eventually { await link.state == .online })
        #expect(again.reached.count == 1)
        #expect(await eventually { await queue.pending == 0 })
        #expect(again.pc.log == ["GET /m/api/ping", "POST /m/api/decide"])
    }

    @Test func turningWorkOfflineOnStopsThePolls() async throws {
        let rig = try LinkRig(FakePC.down)
        await rig.link.start()
        #expect(await rig.sleeper.waitFor(.seconds(5)))
        rig.link.setWorkingOffline(true)
        #expect(await rig.noPollWaiting())
        rig.link.pathChanged(hasPath: false)
        rig.link.pathChanged(hasPath: true)
        #expect(rig.link.state == .forcedOffline)
        #expect(rig.pc.pingCount == 1)
    }

    @Test func trafficThatArrivesAfterWorkOfflineIsTurnedOnDoesNotTurnItOff() async throws {
        let rig = try LinkRig(.up)
        await rig.link.start()
        rig.pc.mode = .silent
        let client = rig.client
        let slow = Task { try await client.galleryDay(LinkRig.unsavedDay) }
        let pc = rig.pc
        #expect(await eventually { pc.log.count == 2 })
        rig.link.setWorkingOffline(true)
        rig.pc.mode = .up
        slow.cancel()
        _ = await slow.result
        rig.link.gate.heard(answer: true)                                     // a late answer
        rig.link.gate.heard(answer: false)                                    // or a late failure
        await Task.yield()
        #expect(rig.link.gate.state == .forcedOffline)
        #expect(rig.link.state == .forcedOffline)
    }

    // MARK: What the screens say

    @Test func aScreenThatFailsForWantOfThePCSaysWhichKindOfOffline() {
        #expect(GalleryMessages.failure(unreachable, loading: "the challenges")
            == "Can’t reach the photo server. Is the PC on and in Ubuntu?")
        #expect(GalleryMessages.failure(forced, loading: "the challenges")
            == "Work offline is on. Turn it off to load the challenges.")
        #expect(GalleryMessages.failure(forced, loading: "the library")
            == "Work offline is on. Turn it off to load the library.")
    }

    // MARK: The offline downloads

    @Test func theOfflineDownloadsDoNotRunWhileThePCCannotBeReachedAndStartWhenItCan() async throws {
        let rig = try LinkRig(FakePC.down)
        let link = rig.link
        let sync = SyncRig(.fresh([planDay("2026-10-01", frames: 2, decided: 1)]), canReachPC: { link.isOnline })
        rig.link.onReachable = { sync.sync.sync() }
        await rig.link.start()

        await sync.syncNow()
        #expect(sync.fake.calls.isEmpty)
        #expect(sync.list.calls == 0)
        #expect(sync.sync.state == .offline)

        rig.pc.mode = .up
        #expect(await rig.poll(after: .seconds(5)))
        #expect(await eventually { await link.state == .online })
        let fake = sync.fake
        #expect(await eventually { fake.calls.count == 2 })                   // pictures, then 1:1 crops
        await sync.sync.settled()
        #expect(sync.store.isSaved("2026/2026-10-01"))
    }

    @Test func theRealDownloaderFailsAtOnceThroughTheLink() async throws {
        let rig = try LinkRig(FakePC.down)
        await rig.link.start()
        let downloads = SyncRig(.fresh([planDay("2026-10-01", frames: 1, decided: 1)]), network: rig.gated)
        await downloads.syncNow()
        #expect(downloads.sync.state == .offline)
        #expect(rig.pc.log == ["GET /m/api/ping"])
    }
}
