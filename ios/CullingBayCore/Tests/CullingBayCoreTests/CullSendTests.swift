import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

/// Send, and reloading the day for receipts.
@MainActor
@Suite("Cull: send and refresh")
struct CullSendTests {
    private func singles(_ count: Int = 3) -> CullDay {
        cullDay((0..<count).map { cullStack($0, .single, [cullFrame(100 + $0, file: "S\(100 + $0).ARW")]) })
    }

    private func open(_ day: CullDay) async -> (CullSessionModel, CullRig) {
        let rig = CullRig(day: day)
        let model = rig.session()
        await model.load()
        return (model, rig)
    }

    private func answerSend(_ rig: CullRig, queued: Int = 2) {
        rig.server.on("POST send") { _ in Reply(body: #"{"ok":true,"queued":\#(queued),"file_rows":\#(queued)}"#) }
    }

    // MARK: Send

    @Test func sendWaitsForTheQueueThenPostsAndMarksTheDecisionsQueued() async {
        let (model, rig) = await open(singles())
        answerSend(rig)
        rig.server.on("POST /m/api/decide") { count in
            if count == 0 { throw CullingBayError.transport("offline") }       // the first try fails: still waiting
            return Reply()
        }
        model.keep()
        model.reject()
        #expect(rig.queue.pending == 2)
        let sending = Task { await model.send() }
        #expect(await rig.sleeper.waitFor(.seconds(4)))                         // offline: the retry is waiting
        await rig.sleeper.release(.seconds(4))
        await sending.value
        let paths = rig.server.allCalls.map(\.path)
        #expect(paths.suffix(3) == ["/m/api/decide", "/m/api/decide", "/m/api/day/2026/2026-10-01/send"])
        #expect(paths.filter { $0 == "/m/api/decide" }.count == 3)                // the retry made it three
        #expect(model.decisions.values.allSatisfy { $0.state == .queued })
        #expect(model.toast?.text == "Queued 2 for Lightroom. On the Mac: Sync AI Cull Data.")
        #expect(!model.isSending)
        let send = rig.server.allCalls.last
        #expect(send?.method == "POST" && send?.body == Data("{}".utf8))
    }

    @Test func onlyDraftAndMissingDecisionsBecomeQueued() async {
        let day = cullDay([
            cullStack(0, .single, [cullFrame(1, decision: draft(.pick))]),
            cullStack(1, .single, [cullFrame(2, decision: Decision(flag: .reject, state: .missing, outcome: "not in the Lightroom selection"))]),
            cullStack(2, .single, [cullFrame(3, decision: draft(.pick, state: .landed))]),
            cullStack(3, .single, [cullFrame(4, decision: draft(.pick, state: .conflict))]),
            cullStack(4, .single, [cullFrame(5)]),
        ])
        let (model, rig) = await open(day)
        answerSend(rig)
        await model.send()
        #expect(model.decisions[1]?.state == .queued)
        #expect(model.decisions[2]?.state == .queued)
        #expect(model.decisions[2]?.outcome == "not in the Lightroom selection")    // as the web app leaves it
        #expect(model.decisions[3]?.state == .landed)
        #expect(model.decisions[4]?.state == .conflict)
        #expect(model.decisions[5] == nil)
        #expect(model.summary.sendLabel == "Waiting for Lightroom" && !model.summary.canSend)
    }

    @Test func sendSaysWhenThereWasNothingNew() async {
        let (model, rig) = await open(singles())
        answerSend(rig, queued: 0)
        await model.send()
        #expect(model.toast?.text == "Nothing new to send.")
    }

    @Test func aRefusedSendSaysWhyAndChangesNothing() async {
        let (model, rig) = await open(singles())
        rig.server.on("POST send") { _ in Reply(status: 503, body: #"{"error":"inbox share is not mounted"}"#) }
        model.keep()
        await model.send()
        #expect(model.toast?.text == "Not sent: inbox share is not mounted")
        #expect(model.decisions[100]?.state == .draft)
        #expect(!model.isSending)
        rig.server.on("POST send") { _ in throw CullingBayError.http(status: 500, message: nil) }
        await model.send()
        #expect(model.toast?.text == "Not sent: HTTP 500")
    }

    @Test func sendGivesUpAfterTenSecondsOfWaitingAndSaysHowManyTapsAreStuck() async {
        let (model, rig) = await open(singles())
        answerSend(rig)
        rig.server.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        model.keep()
        model.keep()
        let sending = Task { await model.send() }
        #expect(await rig.sleeper.waitFor(.seconds(10)))
        #expect(model.isSending)
        await rig.sleeper.release(.seconds(10))
        await sending.value
        #expect(model.toast?.text == "Still offline: 2 taps waiting to save. Send once they are in.")
        #expect(rig.server.calls("/send").isEmpty)                                  // nothing was sent
        #expect(model.decisions.values.allSatisfy { $0.state == .draft })
        #expect(!model.isSending)
        #expect(rig.queue.pending == 2)                                             // and the taps are still safe
    }

    @Test func aSecondSendWhileOneIsWaitingDoesNothing() async {
        let (model, rig) = await open(singles())
        rig.server.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        model.keep()
        let first = Task { await model.send() }
        #expect(await rig.sleeper.waitFor(.seconds(10)))
        await model.send()
        #expect(await rig.sleeper.requested.filter { $0 == .seconds(10) }.count == 1)
        await rig.sleeper.release(.seconds(10))
        await first.value
    }

    // MARK: Refresh

    @Test func refreshBringsTheReceiptsAndKeepsTheCursorOnTheSameStack() async {
        let (model, rig) = await open(singles(4))
        model.keep()                                      // 100
        model.go(1)
        #expect(model.currentStack?.lead == 102)
        await rig.settle()
        // the server now has a new stack ahead of the others, and the Mac synced the first keep
        let moved = cullDay([cullStack(0, .single, [cullFrame(99)])] + (0..<4).map { i in
            cullStack(i + 1, .single, [cullFrame(100 + i, decision: i == 0 ? draft(.pick, state: .landed) : nil)])
        })
        rig.server.setDay(moved)
        await model.refresh()
        #expect(model.stacks.count == 5)
        #expect(model.currentStack?.lead == 102 && model.cursor == 3)
        #expect(model.decisions[100]?.state == .landed)
        #expect(model.refreshError == nil && model.screen == .cards)
        #expect(model.canUndo)                                                      // the history stays
    }

    @Test func refreshKeepsTheMatchesFirstOrder() async {
        let rig = CullRig(day: singles(4))
        let model = rig.session(match: CullMatch(ids: [102], label: "“x”"))
        await model.load()
        #expect(model.stacks.map(\.id) == [2, 0, 1, 3])
        await model.refresh()
        #expect(model.stacks.map(\.id) == [2, 0, 1, 3] && model.cursor == 0)
        #expect(model.matches?.count == 1)
    }

    @Test func refreshWaitsForTheQueueFirstAndWontReplaceTapsStillWaiting() async {
        let (model, rig) = await open(singles())
        rig.server.on("POST /m/api/decide") { _ in throw CullingBayError.transport("offline") }
        model.keep()
        let refreshing = Task { await model.refresh(waiting: .seconds(3)) }
        #expect(await rig.sleeper.waitFor(.seconds(3)))
        await rig.sleeper.release(.seconds(3))
        await refreshing.value
        #expect(model.refreshError == "Still offline: 1 taps waiting to save. Refresh once they are in.")
        #expect(rig.server.allCalls.filter { $0.method == "GET" }.count == 1)       // no second load
        #expect(model.decisions[100]?.flag == .pick)
    }

    @Test func aRefreshThatFailsKeepsTheDayOnScreen() async {
        let (model, rig) = await open(singles())
        rig.server.on("GET /m/api/day") { _ in throw CullingBayError.transport("offline") }
        await model.refresh()
        #expect(model.phase == .loaded && model.stacks.count == 3)
        #expect(model.refreshError == "Can’t reach the photo server. Is the PC on and in Ubuntu?")
    }

    @Test func aTapWhileTheRefreshIsOnItsWayWinsOverTheAnswer() async {
        let day = cullJSON(singles())
        let transport = GatedTransport { request, _ in jsonResponse(request.httpMethod == "GET" ? day : #"{"ok":true}"#, for: request) }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let queue = CullWriteQueue(client: client, store: InMemoryCullWriteStore(), sleep: ManualSleeper().sleep)
        let model = CullSessionModel(
            day: "2026/2026-10-01", client: client, queue: queue, sleep: ManualSleeper().sleep)
        let loading = Task { await model.load() }
        await transport.waitForRequests(1)
        await transport.release(0)
        await loading.value

        let refreshing = Task { await model.refresh() }
        await transport.waitForRequests(2)                                          // the reload is in flight
        model.keep()                                                                // a tap lands meanwhile
        await transport.release(1)                                                  // the old answer arrives
        await refreshing.value
        #expect(model.decisions[100]?.flag == .pick)                                // still there
        #expect(model.cursor == 1)
        await transport.waitForRequests(3)
        await transport.release(2)
        #expect(await eventually { await queue.pending == 0 })
    }
}
