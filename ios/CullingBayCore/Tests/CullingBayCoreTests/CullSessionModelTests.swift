import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Cull: session model")
struct CullSessionModelTests {
    let progressDelay = CullSessionModel.progressDelay

    /// Four single stacks, ids 100 to 103.
    private func singles(_ count: Int = 4, budget: Int = 0, progress: CullingBayCore.Progress? = nil) -> CullDay {
        cullDay(
            (0..<count).map { cullStack($0, .single, [cullFrame(100 + $0, file: "S\(100 + $0).ARW")]) },
            budget: budget, progress: progress)
    }

    private func open(_ day: CullDay, match: CullMatch? = nil) async -> (CullSessionModel, CullRig) {
        let rig = CullRig(day: day)
        let model = rig.session(match: match)
        await model.load()
        return (model, rig)
    }

    private func decided(_ rig: CullRig) -> [RecordedCall] { rig.server.calls("/m/api/decide") }

    private func sentChanges(_ call: RecordedCall) -> [[String: Any]] {
        (call.json["changes"] as? [[String: Any]]) ?? []
    }

    // MARK: Opening

    @Test func openingFillsTheDecisionsAndStartsAtTheSavedStack() async {
        let day = cullDay([
            cullStack(0, .single, [cullFrame(100, decision: draft(.pick, state: .landed))]),
            cullStack(1, .burst, [cullFrame(110), cullFrame(111, decision: draft(.reject, note: "n"))]),
            cullStack(2, .single, [cullFrame(120)]),
            cullStack(3, .single, [cullFrame(130)]),
        ], progress: CullingBayCore.Progress(pass: 2, cursor: 2))
        let (model, _) = await open(day)
        #expect(model.phase == .loaded)
        #expect(model.pass == 2)
        #expect(model.cursor == 2 && model.screen == .cards)
        #expect(model.decisions[100] == draft(.pick, state: .landed))
        #expect(model.decisions[111]?.note == "n")
        #expect(model.decisions[110] == nil)
        #expect(model.canUndo == false)
    }

    @Test func aSavedStackThatIsDoneMovesToTheFirstOpenOneAfterIt() async {
        let day = cullDay([
            cullStack(0, .single, [cullFrame(100)]),
            cullStack(1, .single, [cullFrame(110, decision: draft(.pick))]),
            cullStack(2, .single, [cullFrame(120, decision: draft(.reject))]),
            cullStack(3, .single, [cullFrame(130)]),
        ], progress: CullingBayCore.Progress(pass: 2, cursor: 1))
        #expect(await open(day).0.cursor == 3)
        let wraps = cullDay(day.stacks.dropLast() + [cullStack(3, .single, [cullFrame(130, decision: draft(.pick))])],
                            progress: CullingBayCore.Progress(pass: 2, cursor: 2))
        #expect(await open(wraps).0.cursor == 0)                  // looks on from 2, wraps to the first open
    }

    @Test func withNothingOpenTheDayStartsOnTheSummary() async {
        let day = cullDay([
            cullStack(0, .single, [cullFrame(100, decision: draft(.pick))]),
            cullStack(1, .single, [cullFrame(110, lr: lrByYou(pick: -1))]),
        ])
        let (model, _) = await open(day)
        #expect(model.screen == .summary)
        #expect(model.summary.subtitle == "Day finished")
    }

    @Test func aMissingOrEmptyProgressStartsAtTheFirstStack() async {
        #expect(await open(singles()).0.cursor == 0)
        #expect(await open(singles(progress: CullingBayCore.Progress(pass: nil, cursor: nil))).0.cursor == 0)
        #expect(await open(singles(progress: CullingBayCore.Progress(pass: 2, cursor: 99))).0.cursor == 0)
    }

    @Test func theSavedCursorIsAStackIDNotAPositionInTheArray() async {
        let day = cullDay([
            cullStack(5, .single, [cullFrame(100)]), cullStack(9, .single, [cullFrame(110)]),
            cullStack(12, .single, [cullFrame(120)]),
        ], progress: CullingBayCore.Progress(pass: 2, cursor: 9))
        #expect(await open(day).0.cursor == 1)
    }

    @Test func aDayThatCannotBeLoadedSaysWhy() async {
        let rig = CullRig(day: singles())
        rig.server.on("GET /m/api/day") { _ in Reply(status: 404, body: #"{"error":"no such day"}"#) }
        let model = rig.session()
        await model.load()
        #expect(model.phase == .failed("That isn’t in the library any more."))
        #expect(model.card == nil)
    }

    // MARK: Matches first

    private func matched() -> CullDay {
        cullDay((0..<5).map { cullStack($0, .burst, [cullFrame(100 + $0 * 10), cullFrame(101 + $0 * 10)]) },
                progress: CullingBayCore.Progress(pass: 2, cursor: 4))
    }

    @Test func matchingStacksGoFirstInTheirOwnOrderAndTheSavedCursorIsIgnored() async {
        let match = CullMatch(ids: [131, 110, 99999], label: "“chick”")
        let (model, _) = await open(matched(), match: match)
        #expect(model.stacks.map(\.id) == [1, 3, 0, 2, 4])
        #expect(model.cursor == 0)
        #expect(model.matchesChip == "2 matches first")
        model.explainMatches()
        #expect(model.toast?.text == "2 stacks matched “chick”, so they come first. The rest of the day follows.")
    }

    @Test func oneMatchSaysMatchNotMatches() async {
        let (model, _) = await open(matched(), match: CullMatch(ids: [120], label: "“x”"))
        #expect(model.matchesChip == "1 match first")
        model.explainMatches()
        #expect(model.toast?.text == "1 stack matched “x”, so they come first. The rest of the day follows.")
    }

    @Test func noReorderWhenEverythingOrNothingMatches() async {
        let all = CullMatch(ids: [100, 110, 120, 130, 140], label: "“x”")
        let (everything, _) = await open(matched(), match: all)
        #expect(everything.matches == nil && everything.stacks.map(\.id) == [0, 1, 2, 3, 4])
        #expect(everything.cursor == 4)                              // the saved cursor applies
        let (nothing, _) = await open(matched(), match: CullMatch(ids: [7], label: "“x”"))
        #expect(nothing.matches == nil && nothing.matchesChip == nil)
        let (empty, _) = await open(matched(), match: CullMatch(ids: [], label: "“x”"))
        #expect(empty.matches == nil)
    }

    // MARK: Deciding

    @Test func rejectingASingleSavesItAndMovesOn() async throws {
        let (model, rig) = await open(singles())
        model.reject()
        #expect(model.decisions[100] == draft(.reject))               // at once, before the server
        #expect(model.cursor == 1)
        #expect(model.toast?.text == "Rejected S100" && model.toast?.offersUndo == true)
        await rig.settle()
        let call = try #require(decided(rig).first)
        #expect(call.json["action_id"] as? String == "A-1")
        #expect(call.json["day"] as? String == "2026/2026-10-01")
        #expect(call.json["label"] as? String == "Rejected S100")
        let change = try #require(sentChanges(call).first)
        #expect(change["id"] as? Int == 100 && change["flag"] as? String == "reject")
        #expect(change["note"] as? String == "" && change["via"] as? String == "card")
        #expect(change["stars"] == nil)
    }

    @Test func rejectingABurstRejectsEveryFrame() async {
        let day = cullDay([cullStack(0, .burst, [cullFrame(1), cullFrame(2), cullFrame(3)]), cullStack(1, .single, [cullFrame(4)])])
        let (model, rig) = await open(day)
        model.reject()
        #expect(model.decisions.values.allSatisfy { $0.flag == .reject })
        #expect(model.decisions.count == 3)
        #expect(model.toast?.text == "Rejected all 3")
        await rig.settle()
        #expect(sentChanges(decided(rig)[0]).map { $0["id"] as? Int } == [1, 2, 3])
    }

    @Test func keepAllSaysBracketAndPanorama() async {
        let day = cullDay([
            cullStack(0, .bracket, [cullFrame(1), cullFrame(2)]), cullStack(1, .pano, [cullFrame(3), cullFrame(4)]),
            cullStack(2, .burst, [cullFrame(5), cullFrame(6)]), cullStack(3, .single, [cullFrame(7)]),
        ])
        let (model, rig) = await open(day)
        model.keepAll()
        #expect(model.toast?.text == "Kept all 2 · bracket")
        model.keepAll()
        #expect(model.toast?.text == "Kept all 2 · panorama")
        model.keepAll()
        #expect(model.toast?.text == "Kept all 2")
        #expect([5, 6].allSatisfy { model.decisions[$0]?.flag == .pick })
        await rig.settle()
        let changes = sentChanges(decided(rig)[0])
        #expect(changes.map { $0["flag"] as? String } == ["pick", "pick"])
        #expect(changes.allSatisfy { $0["note"] as? String == "" && $0["via"] as? String == "card" })
    }

    @Test func keepingASingleWithStarsRatesIt() async {
        let (model, rig) = await open(singles())
        model.keep(stars: 3)
        #expect(model.decisions[100] == draft(.pick, stars: 3))
        #expect(model.toast?.text == "Kept S100 ★★★")
        model.keep()
        #expect(model.decisions[101] == draft(.pick))
        #expect(model.toast?.text == "Kept S101")
        model.keep(stars: 9)                                           // not a rating: ignored
        #expect(model.decisions[102] == draft(.pick))
        await rig.settle()
        #expect(sentChanges(decided(rig)[0])[0]["stars"] as? Int == 3)
    }

    @Test func keepingOneFrameOfABurstRejectsTheOthersWithANote() async {
        let day = cullDay([
            cullStack(0, .burst, [cullFrame(1, file: "B1.ARW"), cullFrame(2, file: "B2.ARW"), cullFrame(3, file: "B3.ARW")], lead: 2),
            cullStack(1, .single, [cullFrame(4)]),
        ])
        let (model, rig) = await open(day)
        model.keep(stars: 4)
        let note = "Burst reject · kept B2"
        #expect(CullSessionModel.notePrefix + "B2" == note)
        #expect(model.decisions[2] == draft(.pick, stars: 4))
        #expect(model.decisions[1] == draft(.reject, note: note))
        #expect(model.decisions[3] == draft(.reject, note: note))
        #expect(model.toast?.text == "Kept B2 ★★★★ · 2 rejected with a note")
        await rig.settle()
        let changes = sentChanges(decided(rig)[0])
        #expect(changes.map { $0["id"] as? Int } == [2, 1, 3])         // the keeper first, then the rest in shot order
        #expect(changes[0]["flag"] as? String == "pick" && changes[0]["stars"] as? Int == 4 && changes[0]["note"] as? String == "")
        #expect(changes[1]["flag"] as? String == "reject" && changes[1]["note"] as? String == note)
        #expect(changes[1]["stars"] == nil)
        #expect(changes.allSatisfy { $0["via"] as? String == "card" })
        #expect(decided(rig)[0].json["label"] as? String == "Kept B2 ★★★★ · 2 rejected with a note")
    }

    @Test func aBurstKeepKeepsTheFrameOnTheCardWhichIsTheLeadUntilOneIsKept() async {
        let day = cullStack(0, .burst, [cullFrame(1), cullFrame(2)], lead: 2)
        let (model, _) = await open(cullDay([day, cullStack(1, .single, [cullFrame(3)])]))
        #expect(model.card?.frame.id == 2)
        model.go(1)
        model.go(-1)
        model.keep()
        #expect(model.decisions[2]?.flag == .pick && model.decisions[1]?.flag == .reject)
        model.go(-1)
        #expect(model.card?.frame.id == 2)                              // the kept one now
    }

    @Test func everyTapIsASeparateActionWithItsOwnID() async {
        let (model, rig) = await open(singles())
        model.reject()
        model.keep()
        await rig.settle()
        #expect(decided(rig).compactMap { $0.json["action_id"] as? String } == ["A-1", "A-2"])
    }

    @Test func tapsOutsideTheCardsDoNothing() async {
        let (model, rig) = await open(cullDay([cullStack(0, .single, [cullFrame(1, decision: draft(.pick))])]))
        #expect(model.screen == .summary)
        model.reject()
        model.keep()
        model.keepAll()
        #expect(model.decisions[1] == draft(.pick))
        await rig.settle()
        #expect(decided(rig).isEmpty)
        let (empty, _) = await open(cullDay([]))
        empty.reject()
        #expect(empty.screen == .summary && empty.card == nil)
    }

    // MARK: Toast notes

    @Test func aToastAddsWhatLightroomWillKeep() async {
        let day = cullDay([
            cullStack(0, .burst, [cullFrame(1), cullFrame(2, lr: lrByYou(pick: 1)), cullFrame(3, lr: lrByYou(pick: 1))]),
            cullStack(1, .single, [cullFrame(4)]),
        ])
        let (model, _) = await open(day)
        model.go(-1)                                                      // a stack with a pick in Lightroom counts as done
        model.reject()
        #expect(model.toast?.text == "Rejected all 3 · Lightroom keeps your own flag on 2 of them")
    }

    @Test func aToastAddsStarsYouGaveInLightroom() async {
        let day = cullDay([
            cullStack(0, .single, [cullFrame(1, lr: LightroomState(pick: 0, rating: 3, by: .unset, starsBy: .you))]),
            cullStack(1, .single, [cullFrame(4)]),
        ])
        let (model, _) = await open(day)
        model.go(-1)
        model.reject()
        #expect(model.toast?.text == "Rejected DSC00001 · it had your stars in Lightroom")
    }

    @Test func aKeepPastTheBudgetSaysHowFarOver() async {
        let (model, _) = await open(singles(budget: 2))
        model.keep()
        #expect(model.toast?.text == "Kept S100")
        model.keep()
        #expect(model.toast?.text == "Kept S101")
        model.keep()
        #expect(model.toast?.text == "Kept S102 · 1 over this shoot’s 2")
        model.reject()
        #expect(model.toast?.text == "Rejected S103")                  // a reject never mentions the budget
    }

    // MARK: Moving on

    @Test func decidingSkipsStacksAlreadyDoneAndWrapsRound() async {
        let day = cullDay([
            cullStack(0, .single, [cullFrame(100)]), cullStack(1, .single, [cullFrame(110, decision: draft(.pick))]),
            cullStack(2, .single, [cullFrame(120)]), cullStack(3, .single, [cullFrame(130, lr: lrByYou(pick: 1))]),
        ])
        let (model, _) = await open(day)
        model.keep()
        #expect(model.cursor == 2)                                      // 1 is kept already
        model.go(1)
        #expect(model.cursor == 3)
        model.go(-1)
        model.keep()                                                    // 3 was done in Lightroom: wrap to... nothing open
        #expect(model.screen == .summary)
    }

    @Test func browsingMovesBackAndForthAndStopsAtTheStart() async {
        let (model, _) = await open(singles())
        model.go(-1)
        #expect(model.cursor == 0)
        model.go(1); model.go(1)
        #expect(model.cursor == 2)
        model.go(-1)
        #expect(model.cursor == 1 && model.screen == .cards)
    }

    @Test func goingOnFromTheLastStackOpensTheSummary() async {
        let (model, rig) = await open(singles(2))
        model.go(1)
        model.go(1)
        #expect(model.screen == .summary && model.cursor == 1)
        model.go(1)                                                      // not on the cards: nothing happens
        #expect(model.cursor == 1)
        #expect(await rig.sleeper.waitFor(progressDelay))
        for _ in 0..<50 { await Task.yield() }
        #expect(await rig.sleeper.requested == [progressDelay])          // only the first move asked to save
    }

    @Test func backToTheCardsLandsOnTheFirstOpenStack() async {
        let day = cullDay([
            cullStack(0, .single, [cullFrame(100, decision: draft(.pick))]), cullStack(1, .single, [cullFrame(110)]),
            cullStack(2, .single, [cullFrame(120, decision: draft(.pick))]),
        ])
        let (model, _) = await open(day)
        model.go(1); model.go(1)
        model.go(1)
        #expect(model.screen == .summary)
        model.backToCards()
        #expect(model.screen == .cards && model.cursor == 1)
    }

    // MARK: Progress

    private func progressCalls(_ rig: CullRig) -> [RecordedCall] { rig.server.calls("/progress") }

    @Test func aRunOfMovesSavesThePositionOnceAfterTheDelay() async throws {
        let (model, rig) = await open(singles(6))
        model.go(1)
        #expect(await rig.sleeper.waitFor(progressDelay))
        model.go(1)
        model.go(1)
        #expect(await rig.sleeper.waitFor(progressDelay))
        #expect(await rig.sleeper.requested.filter { $0 == progressDelay }.count == 3)
        #expect(rig.queue.pending == 0 && progressCalls(rig).isEmpty)       // nothing yet
        await rig.sleeper.release(progressDelay)
        await rig.settle()
        let saved = progressCalls(rig)
        #expect(saved.count == 1)                                           // the first two were replaced
        let body = try #require(saved.first).json
        #expect(body["cursor"] as? Int == 3 && body["pass"] as? Int == 2)
        #expect(body["finished"] as? Bool == false)
        #expect(body["lead"] as? Int == 103)
        #expect(saved[0].method == "PUT" && saved[0].path == "/m/api/day/2026/2026-10-01/progress")
    }

    @Test func aDecisionSavesThePositionAfterTheDelayToo() async {
        let (model, rig) = await open(singles())
        model.keep()
        #expect(await rig.sleeper.waitFor(progressDelay))
        await rig.sleeper.release(progressDelay)
        await rig.settle()
        #expect(rig.server.allCalls.map(\.path).suffix(2) == ["/m/api/decide", "/m/api/day/2026/2026-10-01/progress"])
        #expect(progressCalls(rig).first?.json["cursor"] as? Int == 1)
    }

    @Test func theProgressUsesTheStackIDAndLeadOfTheStackWhenMatchesCameFirst() async {
        let (model, rig) = await open(matched(), match: CullMatch(ids: [131], label: "“x”"))
        model.go(1)
        #expect(await rig.sleeper.waitFor(progressDelay))
        await rig.sleeper.release(progressDelay)
        await rig.settle()
        let body = progressCalls(rig).first?.json
        #expect(body?["cursor"] as? Int == 0)                                // the stack after the match is stack 0
        #expect(body?["lead"] as? Int == 100)
    }

    @Test func decidingTheLastOpenStackFinishesTheDayAtOnce() async throws {
        let (model, rig) = await open(singles(2))
        model.keep()
        #expect(await rig.sleeper.waitFor(progressDelay))                    // the first save is still waiting
        model.reject()
        #expect(model.screen == .summary)
        await rig.settle()                                                   // no release: the finish does not wait
        let saved = progressCalls(rig)
        #expect(saved.count == 1)                                            // and it replaced the waiting one
        let body = try #require(saved.first).json
        #expect(body["finished"] as? Bool == true)
        #expect(body["cursor"] as? Int == 1 && body["lead"] as? Int == 101)
        #expect(rig.server.allCalls.map(\.path).suffix(3) == [
            "/m/api/decide", "/m/api/decide", "/m/api/day/2026/2026-10-01/progress",
        ])
    }

    // MARK: Undo

    @Test func undoPutsBackTheDecisionsTheCursorAndTheToast() async {
        let day = cullDay([
            cullStack(0, .burst, [cullFrame(1, file: "B1.ARW"), cullFrame(2, file: "B2.ARW")]),
            cullStack(1, .single, [cullFrame(3, decision: draft(.pick, stars: 2, state: .landed))]),
            cullStack(2, .single, [cullFrame(4)]),
        ])
        let (model, rig) = await open(day)
        model.keep()
        #expect(model.cursor == 2 && model.canUndo)
        model.undo()
        #expect(model.decisions[1] == nil && model.decisions[2] == nil)       // a frame with none loses it
        #expect(model.cursor == 0 && model.screen == .cards)
        #expect(model.toast == CullSessionModel.Toast(id: model.toast?.id ?? 0, text: "Undone: Kept B1 · 1 rejected with a note", offersUndo: false))
        #expect(!model.canUndo)
        await rig.settle()
        #expect(rig.server.calls("/m/api/undo").first?.json["action_id"] as? String == "A-1")
        #expect(rig.server.allCalls.map(\.path).prefix(3) == ["/m/api/day/2026/2026-10-01", "/m/api/decide", "/m/api/undo"])
    }

    @Test func undoRestoresAnEarlierDecisionOnTheSameFrame() async {
        let (model, _) = await open(singles(2))
        model.keep(stars: 2)
        model.go(-1)
        model.reject()
        #expect(model.decisions[100] == draft(.reject))
        model.undo()
        #expect(model.decisions[100] == draft(.pick, stars: 2))
        model.undo()
        #expect(model.decisions[100] == nil)
        model.undo()
        #expect(model.toast?.text == "Nothing to undo")
    }

    @Test func undoReturnsToTheStackTheTapWasMadeOn() async {
        let (model, _) = await open(singles())
        model.go(1); model.go(1)
        model.keep()
        #expect(model.cursor == 3)
        model.undo()
        #expect(model.cursor == 2)
    }

    @Test func undoAfterTheDayFinishedGoesBackToTheCards() async {
        let (model, _) = await open(singles(1))
        model.keep()
        #expect(model.screen == .summary)
        model.undo()
        #expect(model.screen == .cards && model.cursor == 0)
        #expect(model.decisions.isEmpty)
    }

    @Test func aRefusedUndoPutsTheDecisionsBackAndSaysSo() async {
        let (model, rig) = await open(singles())
        rig.server.on("POST /m/api/undo") { _ in
            Reply(status: 409, body: #"{"error":"already in Lightroom","applied":1}"#)
        }
        model.keep(stars: 3)
        model.undo()
        #expect(model.decisions[100] == nil)                                  // optimistic, until the server answers
        #expect(await eventually { await model.decisions[100] == draft(.pick, stars: 3) })
        #expect(model.toast?.text == "Not undone: already in Lightroom")
        await rig.settle()
        #expect(rig.server.calls("/m/api/undo").count == 1)                   // dropped, not retried
        #expect(!model.canUndo)
    }

    @Test func aRefusedUndoLeavesAFrameYouDecidedAgainAlone() async {
        let (model, rig) = await open(singles(2))
        rig.server.on("POST /m/api/undo") { _ in
            Reply(status: 409, body: #"{"error":"already in Lightroom","applied":1}"#)
        }
        model.keep()
        model.undo()
        model.reject()          // all three taps land before the server is asked: the undo is refused afterwards
        #expect(model.decisions[100] == draft(.reject))
        #expect(await eventually { await model.toast?.text == "Not undone: already in Lightroom" })
        #expect(model.decisions[100] == draft(.reject))                       // the newer decision stands
    }

    @Test func aSimpleSaveFailureIsToastedAsNotSaved() async {
        let (model, rig) = await open(singles())
        rig.server.on("POST /m/api/decide") { _ in Reply(status: 400, body: #"{"error":"unknown frame"}"#) }
        model.keep()
        #expect(await eventually { await model.toast?.text == "Not saved: unknown frame" })
        #expect(model.decisions[100]?.flag == .pick)                          // the web keeps it on screen
        model.close()
        rig.server.on("POST /m/api/decide") { _ in Reply(status: 400, body: #"{"error":"again"}"#) }
        model.keep()
        await rig.settle()
        #expect(rig.queue.lastDrop?.message == "Not saved: again")
        #expect(model.toast?.text != "Not saved: again")                      // a closed session stops listening
    }

    // MARK: Feedback

    @Test func theLastActionIsAFeedbackEventForAHaptic() async {
        let (model, _) = await open(singles(6))
        #expect(model.feedback == nil)
        model.keep()
        #expect(model.feedback?.kind == .kept && model.feedback?.id == 1)
        model.keep(stars: 5)
        #expect(model.feedback?.kind == .hero && model.feedback?.id == 2)
        model.reject()
        #expect(model.feedback?.kind == .rejected && model.feedback?.id == 3)
        model.undo()
        #expect(model.feedback?.kind == .undone && model.feedback?.id == 4)
        model.go(1)
        #expect(model.feedback?.id == 4)                                       // browsing is not an action
    }

    @Test func eachToastIsNewEvenWithTheSameWords() async {
        let (model, _) = await open(singles())
        model.undo()
        let first = model.toast
        model.undo()
        #expect(model.toast?.text == first?.text && model.toast?.id != first?.id)
        model.dismissToast()
        #expect(model.toast == nil)
    }
}
