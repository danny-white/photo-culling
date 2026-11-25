import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

/// Decode-ahead: the app names the RAWs a 1:1 check will want, so the PC decodes them first.
@MainActor
@Suite("Cull: decode-ahead")
struct CullWarmTests {
    /// `count` single RAW stacks, photo ids 101 up.
    private func singles(_ count: Int = 5) -> CullDay {
        cullDay((0..<count).map { cullStack($0, .single, [cullFrame(101 + $0, file: "S\(101 + $0).ARW")]) })
    }

    /// A burst of 101...105, then a single, 900.
    private func burstThenSingle() -> CullDay {
        cullDay([
            cullStack(0, .burst, (101...105).map { cullFrame($0) }, lead: 101),
            cullStack(1, .single, [cullFrame(900, file: "S900.ARW")]),
        ])
    }

    private func open(_ day: CullDay) async -> (CullSessionModel, CullRig, CullWarmer) {
        let rig = CullRig(day: day)
        let warmer = rig.warmer()
        let model = rig.session(warmer: warmer)
        await model.load()
        return (model, rig, warmer)
    }

    /// Lets anything that was going to happen happen.
    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    // MARK: The client

    @Test func warmSendsOneGetNamingTheIdsInOrderAndAcceptsA204() async throws {
        let transport = FakeTransport { request, _ in (Data(), makeResponse(for: request, status: 204)) }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        try await client.warm(ids: [12, 13])
        let sent = await transport.requests
        #expect(sent.count == 1)
        #expect(sent[0].httpMethod == "GET")
        #expect(sent[0].url?.path == "/m/api/warm")
        #expect(queryItems(sent[0]) == ["ids": "12,13"])
        #expect(sent[0].timeoutInterval == 3)                       // a hint: it gives up quickly
        #expect(sent[0].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func warmNamesAtMostFourAndSendsNothingForNone() async throws {
        let transport = FakeTransport { request, _ in (Data(), makeResponse(for: request, status: 204)) }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        try await client.warm(ids: [])
        #expect(await transport.requests.isEmpty)
        try await client.warm(ids: [1, 2, 3, 4, 5, 6])
        #expect(queryItems(await transport.requests[0]) == ["ids": "1,2,3,4"])
    }

    @Test func warmThrowsWhatWentWrongForTheCallerToIgnore() async {
        let refused = CullingBayClient(baseURL: testBaseURL, transport: fixedTransport(status: 500))
        await #expect(throws: CullingBayError.http(status: 500, message: nil)) { try await refused.warm(ids: [1]) }
        let lost = CullingBayClient(
            baseURL: testBaseURL,
            transport: FakeTransport { _, _ in throw CullingBayError.transport("offline") })
        await #expect(throws: CullingBayError.transport("offline")) { try await lost.warm(ids: [1]) }
        let broken = CullingBayClient(baseURL: testBaseURL, transport: FakeTransport { _, _ in throw TestFailure() })
        await #expect(throws: CullingBayError.self) { try await broken.warm(ids: [1]) }
    }

    @Test func theRawExtensionsAreTheServersAndCaseDoesNotMatter() {
        for file in ["a.ARW", "a.nef", "a.Cr2", "a.CR3", "a.dng", "a.RAF", "a.orf", "a.RW2", "a.pef", "a.SRW", "x.y.arw"] {
            #expect(CullWarmer.isRAW(file), "\(file)")
        }
        for file in ["a.JPG", "a.jpeg", "a.HEIC", "a.png", "a.arw.jpg", "arw", ".arw", "a.", ""] {
            #expect(!CullWarmer.isRAW(file), "\(file)")
        }
    }

    // MARK: A day

    @Test func aDayLoadAsksForTheCardOnScreenAndTheNextOne() async {
        let (model, rig, _) = await open(singles())
        #expect(model.card?.frame.id == 101)
        #expect(rig.warmed.isEmpty)                                 // it waits for the card to settle
        #expect(await rig.sendWarm(requests: 1))
        #expect(rig.warmed == [[101, 102]])
        #expect(rig.server.calls("/m/api/warm")[0].timeout == 3)
        #expect(rig.server.calls("/m/api/warm")[0].method == "GET")
    }

    @Test func goAsksForTheNewPairLeavingOutWhatWasAskedFor() async {
        let (model, rig, _) = await open(singles())
        #expect(await rig.sendWarm(requests: 1))
        model.go(1)
        #expect(await rig.sendWarm(requests: 2))
        model.go(1)
        #expect(await rig.sendWarm(requests: 3))
        #expect(rig.warmed == [[101, 102], [103], [104]])

        // Back over cards already asked for: nothing to say.
        model.go(-1)
        model.go(-1)
        await settle()
        #expect(rig.warmed.count == 3)
        #expect(model.cursor == 0)
    }

    @Test func theLastCardAsksForItselfAlone() async {
        let (model, rig, _) = await open(singles(2))
        #expect(await rig.sendWarm(requests: 1))
        model.go(1)
        await settle()
        #expect(rig.warmed == [[101, 102]])                         // both asked already
        let day = cullDay([cullStack(0, .single, [cullFrame(7)])])
        let (alone, only, _) = await open(day)
        #expect(await only.sendWarm(requests: 1))
        #expect(only.warmed == [[7]])
        withExtendedLifetime(alone) {}
    }

    @Test func swipingFastAsksOnlyForTheCardItStopsOn() async {
        let (model, rig, _) = await open(singles())
        model.go(1)
        model.go(1)
        model.go(1)                                                 // the first three waits were replaced
        #expect(await rig.sendWarm(requests: 1))
        await settle()
        #expect(rig.warmed == [[104, 105]])
    }

    @Test func aDecisionMovesTheCardAndAsksForTheNewOnes() async {
        let (model, rig, _) = await open(singles())
        #expect(await rig.sendWarm(requests: 1))
        model.keep()                                                // on to 102
        #expect(await rig.sendWarm(requests: 2))
        #expect(rig.warmed == [[101, 102], [103]])
        model.undo()                                                // back to 101: asked for already
        await settle()
        #expect(model.cursor == 0)
        #expect(rig.warmed.count == 2)
    }

    @Test func theFrameAskedForFirstIsTheOneTheFocusCheckOpens() async throws {
        // A burst whose card shows the sharpest frame, and one whose card shows the kept frame.
        let day = cullDay([
            cullStack(0, .burst, [cullFrame(101), cullFrame(102), cullFrame(103, decision: draft(.pick))], lead: 102),
            cullStack(1, .burst, [cullFrame(201), cullFrame(202), cullFrame(203)], lead: 202),
            cullStack(2, .single, [cullFrame(900)]),
        ])
        let (model, rig, _) = await open(day)
        #expect(model.cursor == 1)                                  // the first stack is done
        model.openFocus()
        #expect(model.focus?.frame.id == 202)
        #expect(await rig.sendWarm(requests: 1))
        #expect(rig.warmed[0].first == 202)
        #expect(rig.warmed == [[202, 900]])
        model.closeFocus()

        model.go(-1)                                                // the card shows the kept frame
        model.openFocus()
        #expect(model.focus?.frame.id == 103)
        #expect(await rig.sendWarm(requests: 2))
        #expect(rig.warmed[1] == [103])                             // 202 was asked for already
    }

    @Test func aSavedDayAsksEvenThoughItsCardsComeFromThePhone() async {
        // The card's picture is never fetched, so the only request is the warm one.
        let (model, rig, _) = await open(singles())
        #expect(await rig.sendWarm(requests: 1))
        #expect(rig.server.allCalls.filter { $0.path.hasPrefix("/m/api/img/") }.isEmpty)
        #expect(rig.server.allCalls.map(\.path) == ["/m/api/day/2026/2026-10-01", "/m/api/warm"])
        withExtendedLifetime(model) {}
    }

    @Test func noCardOnScreenNothingIsAskedFor() async {
        let done = cullDay([
            cullStack(0, .single, [cullFrame(1, decision: draft(.pick))]),
            cullStack(1, .single, [cullFrame(2, decision: draft(.reject))]),
        ])
        let (model, rig, _) = await open(done)
        #expect(model.screen == .summary)
        await settle()
        #expect(!(await rig.wantedToWarm))
        #expect(rig.warmed.isEmpty)
    }

    @Test func aSessionWithoutAWarmerAsksForNothing() async {
        let rig = CullRig(day: singles())
        let model = rig.session()
        await model.load()
        model.go(1)
        model.keep()
        await settle()
        #expect(!(await rig.wantedToWarm))
        #expect(rig.warmed.isEmpty)
    }

    @Test func closingTheDayDropsARequestStillWaiting() async {
        let (model, rig, _) = await open(singles())
        model.close()
        await rig.sleeper.release(CullWarmer.delay)
        await settle()
        #expect(rig.warmed.isEmpty)
    }

    // MARK: Offline and failures

    @Test func nothingIsAskedWhileTheQueueIsOfflineAndTheFramesAreAskedWhenItIsBack() async {
        let rig = CullRig(day: singles())
        rig.server.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        let model = rig.session(warmer: rig.warmer())
        await model.load()
        #expect(await rig.sendWarm(requests: 1))
        model.keep()                                                // the tap fails: the queue goes offline
        let queue = rig.queue
        #expect(await eventually { await queue.isOffline })
        await rig.sleeper.release(CullWarmer.delay)
        await settle()
        #expect(rig.warmed == [[101, 102]])                         // no request while offline

        rig.server.on("POST /m/api/decide") { _ in Reply() }
        rig.queue.resume()
        await rig.settle()
        #expect(!rig.queue.isOffline)
        model.go(1)                                                 // 103 was never asked for: it is now
        #expect(await rig.sendWarm(requests: 2))
        #expect(rig.warmed == [[101, 102], [103, 104]])
    }

    @Test func aFailedRequestChangesNothingYouCanSeeAndTheFramesAreTriedAgain() async {
        for failure in [
            Reply(status: 500, body: #"{"error":"boom"}"#), nil,
        ] as [Reply?] {
            let rig = CullRig(day: singles())
            rig.server.on("GET /m/api/warm") { _ in
                if let failure { return failure }
                throw CullingBayError.transport("The Internet connection appears to be offline.")
            }
            let warmer = rig.warmer()
            let model = rig.session(warmer: warmer)
            await model.load()
            #expect(await rig.sendWarm(requests: 1))
            #expect(await eventually { await warmer.asked.isEmpty })    // forgotten, to be asked again

            #expect(model.phase == .loaded && model.screen == .cards)
            #expect(model.toast == nil && model.refreshError == nil)
            #expect(!rig.queue.isOffline && rig.queue.pending == 0 && rig.queue.queuedWrites.isEmpty)
            #expect(rig.queue.lastDrop == nil)

            rig.server.on("GET /m/api/warm") { _ in Reply(status: 204, body: "") }
            model.go(1)
            #expect(await rig.sendWarm(requests: 2))
            #expect(rig.warmed == [[101, 102], [102, 103]])
            #expect(await eventually { await warmer.asked == [102, 103] })
            #expect(model.toast == nil)
        }
    }

    @Test func aWarmRequestIsNeverQueuedAsAWrite() async {
        let (model, rig, _) = await open(singles())
        #expect(await rig.sendWarm(requests: 1))
        model.go(1)
        #expect(await rig.sendWarm(requests: 2))
        #expect(rig.queue.queuedWrites.allSatisfy { if case .progress = $0 { true } else { false } })
        #expect(rig.server.calls("/m/api/decide").isEmpty)
    }

    // MARK: Memory

    @Test func onlyTheLastSixteenAreRemembered() async {
        let rig = CullRig(day: singles(1))
        let warmer = rig.warmer()
        for id in 1...17 {
            warmer.warm([cullFrame(id)])
            #expect(await rig.sendWarm(requests: id))
        }
        #expect(warmer.asked == Array(2...17))
        warmer.warm([cullFrame(17)])                                // remembered: nothing to say
        warmer.warm([cullFrame(2)])                                 // remembered too
        warmer.warm([cullFrame(1)])                                 // forgotten: asked for again
        #expect(await rig.sendWarm(requests: 18))
        #expect(rig.warmed.last == [1])
        #expect(rig.warmed.count == 18)
    }

    // MARK: Non-RAW files

    @Test func framesThatAreNotRawsAreNotAskedFor() async {
        let day = cullDay([
            cullStack(0, .single, [cullFrame(1, file: "A.JPG")]),
            cullStack(1, .single, [cullFrame(2, file: "B.HEIC")]),
            cullStack(2, .single, [cullFrame(3, file: "C.arw")]),
            cullStack(3, .single, [cullFrame(4, file: "D.ARW")]),
        ])
        let (model, rig, _) = await open(day)
        await settle()
        #expect(!(await rig.wantedToWarm))                          // two JPEG-ish cards: nothing to ask
        model.go(1)                                                 // B.HEIC and C.arw
        #expect(await rig.sendWarm(requests: 1))
        #expect(rig.warmed == [[3]])
        model.go(1)                                                 // C.arw and D.ARW
        #expect(await rig.sendWarm(requests: 2))
        #expect(rig.warmed == [[3], [4]])
    }

    // MARK: The burst picker

    @Test func theStripAsksForTheFrameOnTheBigPictureAndTheNextOne() async throws {
        let (model, rig, _) = await open(burstThenSingle())
        #expect(await rig.sendWarm(requests: 1))
        #expect(rig.warmed == [[101, 900]])                         // the card

        model.openPicker()                                          // on 101, the next is 102
        #expect(await rig.sendWarm(requests: 2))
        let picker = try #require(model.picker)
        picker.step(1)                                              // on 102, the next is 103
        #expect(await rig.sendWarm(requests: 3))
        picker.show(4)                                              // the last frame has no next
        #expect(await rig.sendWarm(requests: 4))
        picker.step(1)                                              // stays on the last: nothing changed
        picker.show(2)                                              // on 103: 104 is the one not asked for
        #expect(await rig.sendWarm(requests: 5))
        #expect(rig.warmed == [[101, 900], [102], [103], [105], [104]])
        await settle()
        #expect(rig.warmed.count == 5)

        model.closePicker()                                         // back on the card: both asked for
        await settle()
        #expect(rig.warmed.count == 5)
    }

    @Test func aPickerOpenedOnTheFrameTheCardShowsAsksForTheStripFromThere() async throws {
        let (model, rig, _) = await open(burstThenSingle())
        #expect(await rig.sendWarm(requests: 1))
        model.openPicker(fromStart: false)
        #expect(try #require(model.picker).viewIndex == 0)
        #expect(await rig.sendWarm(requests: 2))
        #expect(rig.warmed == [[101, 900], [102]])
    }

    @Test func aPickerWithNoWarmerAsksForNothing() async throws {
        let rig = CullRig(day: burstThenSingle())
        let model = rig.session()
        await model.load()
        model.openPicker()
        try #require(model.picker).step(1)
        await settle()
        #expect(!(await rig.wantedToWarm))
    }
}
