import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

/// The burst picker: `openPicker`, `vStrip`, `vKnock` and the picker's part of the click switch.
@MainActor
@Suite("Cull: burst picker")
struct CullPickerModelTests {
    /// A burst of `count` frames, ids `base + 1...`, files `B<id>.ARW`, then a single to move on to.
    private func day(
        _ count: Int, base: Int = 100, lead: Int? = nil, decisions: [Int: Decision] = [:],
        badges: [Int: [String]] = [:], lr: [Int: LightroomState] = [:]
    ) -> CullDay {
        let frames = (1...count).map { i -> Frame in
            let id = base + i
            return cullFrame(id, file: "B\(id).ARW", lr: lr[id], decision: decisions[id], badges: badges[id] ?? [])
        }
        return cullDay([
            cullStack(0, .burst, frames, lead: lead ?? frames[0].id),
            cullStack(1, .single, [cullFrame(900, file: "S900.ARW")]),
        ])
    }

    private func open(_ day: CullDay) async -> (CullSessionModel, CullRig) {
        let rig = CullRig(day: day)
        let model = rig.session()
        await model.load()
        return (model, rig)
    }

    private func decided(_ rig: CullRig) -> [RecordedCall] { rig.server.calls("/m/api/decide") }

    private func sentChanges(_ call: RecordedCall) -> [[String: Any]] {
        (call.json["changes"] as? [[String: Any]]) ?? []
    }

    private func picker(_ model: CullSessionModel) throws -> CullPickerModel {
        try #require(model.picker)
    }

    // MARK: Opening

    @Test func aBurstOfSixOrFewerOpensAsAStripAndABiggerOneAsAKnockOut() async throws {
        let (six, _) = await open(day(6))
        six.openPicker()
        #expect(six.screen == .picker)
        #expect(try picker(six).mode == .strip)
        let (seven, _) = await open(day(7))
        seven.openPicker()
        #expect(seven.screen == .picker)
        #expect(try picker(seven).mode == .knockOut)
        #expect(CullPickerModel.stripMax == 6)
        let (two, _) = await open(day(2))
        two.openPicker()
        #expect(try picker(two).mode == .strip)
    }

    @Test func aSingleDoesNotOpenAPickerAndNeitherDoesAScreenOtherThanTheCards() async {
        let single = cullDay([cullStack(0, .single, [cullFrame(1)]), cullStack(1, .single, [cullFrame(2)])])
        let (model, _) = await open(single)
        model.openPicker()
        #expect(model.screen == .cards && model.picker == nil)
        let (summary, _) = await open(cullDay([cullStack(0, .burst, [cullFrame(1, decision: draft(.pick)), cullFrame(2)])]))
        #expect(summary.screen == .summary)
        summary.openPicker()
        #expect(summary.screen == .summary && summary.picker == nil)
    }

    @Test func aSwipeUpAndChooseOpenOnTheFirstFrameButTheStripUnderTheCardOpensOnTheShownOne() async throws {
        let (model, _) = await open(day(5, lead: 103))
        model.openPicker()                                                 // swipe up, Choose
        #expect(try picker(model).viewIndex == 0)                          // not the sharpest
        model.closePicker()
        model.openPicker(fromStart: false)                                 // the strip under the card
        #expect(try picker(model).viewIndex == 2)                          // the lead is what the card shows
        #expect(try picker(model).viewed.isSharpest)
    }

    @Test func comingBackToADecidedBurstTicksTheFramesThatWereKept() async throws {
        let decisions = [
            101: draft(.reject, note: "n"), 102: draft(.pick, stars: 3), 103: draft(.reject, note: "n"),
            104: draft(.pick), 105: draft(.reject, note: "n"),
        ]
        let (model, _) = await open(day(5, decisions: decisions))
        #expect(model.cursor == 1)                                         // the burst is done: the single is open
        model.go(-1)
        model.openPicker()
        let p = try picker(model)
        #expect(p.selected == [102, 104])
        #expect(p.viewIndex == 0)                                          // swipe up and Choose start at the first
        #expect(p.rates == [102: 3])                                       // the star row shows 3, so a keep saves 3
        #expect(p.keeps.map(\.id) == [102, 104])
        model.closePicker()
        model.openPicker(fromStart: false)
        #expect(try picker(model).viewIndex == 1)                          // the strip: the first kept frame, as the card shows
    }

    @Test func comingBackToADecidedBigBurstKnocksOutTheFramesThatWereNot() async throws {
        let decisions: [Int: Decision] = [
            101: draft(.reject, note: "n"), 102: draft(.pick), 103: draft(.reject, note: "n"),
            104: draft(.reject, note: "n"), 105: draft(.pick), 106: draft(.reject, note: "n"),
            107: draft(.reject, note: "n"),
        ]
        let (model, _) = await open(day(7, decisions: decisions))
        model.go(-1)
        model.openPicker()
        let p = try picker(model)
        #expect(p.mode == .knockOut)
        #expect(p.knockedOut == [101, 103, 104, 106, 107])
        #expect(p.keeps.map(\.id) == [102, 105])
        #expect(p.subtitle == "2 left · tap the weaker frames out")
    }

    @Test func anUndecidedBigBurstStartsWithNothingOutAndSoDoesOneThatWasRejectedWhole() async throws {
        let (fresh, _) = await open(day(8))
        fresh.openPicker()
        #expect(try picker(fresh).knockedOut.isEmpty)
        #expect(try picker(fresh).keeps.count == 8)
        let rejected = Dictionary(uniqueKeysWithValues: (101...107).map { ($0, draft(.reject)) })
        let (all, _) = await open(day(7, decisions: rejected))
        all.go(-1)
        all.openPicker()
        #expect(try picker(all).knockedOut.isEmpty)                        // nothing was kept, so nothing starts out
    }

    @Test func openingAndClosingThePickerSavesAndDecidesNothing() async throws {
        let (model, rig) = await open(day(4))
        model.openPicker()
        let p = try picker(model)
        p.tick()
        p.rate(stars: 4)
        model.closePicker()
        #expect(model.screen == .cards && model.picker == nil && model.cursor == 0)
        #expect(model.decisions.isEmpty && !model.canUndo)
        #expect(model.feedback == nil && model.toast == nil)
        await rig.settle()
        #expect(decided(rig).isEmpty)
        #expect(rig.server.calls("/progress").isEmpty)
        #expect(await rig.sleeper.requested.isEmpty)                       // no position save was even asked for
    }

    // MARK: The strip

    @Test func theStripShowsTheSharpestBadgeTheMeasuredHintAndTheMarkOfEachFrame() async throws {
        let (model, _) = await open(day(3, lead: 102, badges: [102: ["Dark"]], lr: [103: lrByYou(pick: 1)]))
        model.go(-1)                                                       // the Lightroom pick makes the burst done
        model.openPicker()
        let p = try picker(model)
        #expect(p.frames[0].badges.isEmpty && p.frames[0].mark == nil && !p.frames[0].isSharpest)
        #expect(p.frames[1].badges == [CullBadge(text: "Sharpest", style: .hint), CullBadge(text: "Dark", style: .measured)])
        #expect(p.frames[1].isSharpest)
        #expect(p.frames[2].mark?.text == "Picked in Lightroom")
        #expect(p.title == "Burst of 3" && p.subtitle == "Tick the keepers")
        #expect(p.note.hasPrefix("A dot marks the sharpest frame."))
    }

    @Test func aLightroomFlagIsBadgedOnlyWhenTheMarkDoesNotSayItAlready() async throws {
        // Frame 1: the mark says "Rejected in Lightroom". Frame 2 was kept on the phone, so its
        // mark says "Kept", and the badge adds that you had picked it in Lightroom too.
        let (model, _) = await open(day(3, decisions: [102: draft(.pick)], lr: [101: lrByYou(pick: -1), 102: lrByYou(pick: 1)]))
        model.go(-1)
        model.openPicker()
        let p = try picker(model)
        #expect(p.frames[0].mark?.text == "Rejected in Lightroom")
        #expect(p.frames[0].badges == [CullBadge(text: "Sharpest", style: .hint)])
        #expect(p.frames[1].mark?.text == "Kept")
        #expect(p.frames[1].badges == [CullBadge(text: "Picked in Lightroom", style: .lightroom)])
    }

    @Test func swipingMovesBetweenFramesAndStopsAtTheEnds() async throws {
        let (model, _) = await open(day(3))
        model.openPicker()
        let p = try picker(model)
        p.step(-1)
        #expect(p.viewIndex == 0)
        p.step(1); p.step(1); p.step(1)
        #expect(p.viewIndex == 2)
        p.show(0)
        #expect(p.viewIndex == 0)
        p.show(99)
        #expect(p.viewIndex == 2)
        p.show(-4)
        #expect(p.viewIndex == 0)
    }

    @Test func aTickKeepsOrDropsTheFrameOnShow() async throws {
        let (model, _) = await open(day(3))
        model.openPicker()
        let p = try picker(model)
        p.tick()
        p.step(1); p.step(1)
        p.tick()
        #expect(p.selected == [101, 103])
        #expect(p.isTicked(101) && !p.isTicked(102))
        #expect(p.keepLabel == "Keep 2 · reject 1")
        p.tick()
        #expect(p.selected == [101])
    }

    @Test func aStarRatesTheFrameOnShowAndTicksIt() async throws {
        let (model, _) = await open(day(3))
        model.openPicker()
        let p = try picker(model)
        p.step(1)
        #expect(p.viewedStars == 0)
        p.rate(stars: 4)
        #expect(p.rates == [102: 4] && p.selected == [102] && p.viewedStars == 4)
        p.rate(stars: 2)
        #expect(p.rates == [102: 2])
        p.rate(stars: 0)
        p.rate(stars: 6)
        #expect(p.rates == [102: 2])                                        // not ratings
        p.tick()                                                            // unticking leaves the rating but not the keep
        #expect(p.selected.isEmpty && p.keeps.isEmpty)
        #expect(p.keepRates == [102: 2])
    }

    @Test func theKeepButtonSaysWhatItWillDo() async throws {
        let (model, _) = await open(day(5))
        model.openPicker()
        let p = try picker(model)
        #expect(p.keepLabel == "Tick a keeper" && !p.canKeep)
        p.tick()
        #expect(p.keepLabel == "Keep 1 · reject 4" && p.canKeep)
        #expect(p.rejectAllLabel == "Reject all 5")
    }

    // MARK: Keeping

    @Test func keepingTickedFramesSavesPicksWithStarsAndRejectsTheRestWithTheNoteByBurst() async throws {
        let (model, rig) = await open(day(5))
        model.openPicker()
        let p = try picker(model)
        p.step(3); p.tick()                                                 // B104, no stars
        p.show(0); p.rate(stars: 5)                                         // B101 hero
        model.keepPicked()
        let note = "Burst reject · kept B101, B104"
        #expect(model.decisions[101] == draft(.pick, stars: 5))
        #expect(model.decisions[104] == draft(.pick))
        #expect([102, 103, 105].allSatisfy { model.decisions[$0] == draft(.reject, note: note) })
        #expect(model.toast?.text == "Kept 2 frames · 3 rejected with a note" && model.toast?.offersUndo == true)
        #expect(model.feedback?.kind == .hero)
        #expect(model.screen == .cards && model.picker == nil && model.cursor == 1)   // on to the single
        await rig.settle()
        let call = try #require(decided(rig).first)
        #expect(call.json["label"] as? String == "Kept 2 frames · 3 rejected with a note")
        let changes = sentChanges(call)
        #expect(changes.map { $0["id"] as? Int } == [101, 104, 102, 103, 105])   // keepers in shot order, then the rest
        #expect(changes.map { $0["flag"] as? String } == ["pick", "pick", "reject", "reject", "reject"])
        #expect(changes[0]["stars"] as? Int == 5 && changes[1]["stars"] == nil)
        #expect(changes.prefix(2).allSatisfy { $0["note"] as? String == "" })
        #expect(changes.suffix(3).allSatisfy { $0["note"] as? String == note && $0["stars"] == nil })
        #expect(changes.allSatisfy { $0["via"] as? String == "burst" })
    }

    @Test func keepingOneRatedFrameNamesItAndItsStarsInTheLabel() async throws {
        let (model, rig) = await open(day(3))
        model.openPicker()
        let p = try picker(model)
        p.step(2)
        p.rate(stars: 3)
        model.keepPicked()
        #expect(model.toast?.text == "Kept B103 ★★★ · 2 rejected with a note")
        #expect(model.feedback?.kind == .kept)
        await rig.settle()
        #expect(decided(rig).count == 1)
    }

    @Test func keepingEveryFrameRejectsNothingAndSaysFrames() async throws {
        let (model, rig) = await open(day(2))
        model.openPicker()
        let p = try picker(model)
        p.tick(); p.step(1); p.tick()
        model.keepPicked()
        #expect(model.toast?.text == "Kept 2 frames")
        #expect(model.decisions.values.allSatisfy { $0.flag == .pick })
        await rig.settle()
        #expect(sentChanges(decided(rig)[0]).count == 2)
    }

    @Test func aKeepAgainstAFlagYouSetInLightroomSaysSo() async throws {
        let one = cullDay([
            cullStack(0, .burst, [cullFrame(1, file: "B1.ARW", lr: lrByYou(pick: -1)), cullFrame(2, file: "B2.ARW")]),
            cullStack(1, .single, [cullFrame(3)]),
        ])
        let (model, _) = await open(one)
        #expect(model.cursor == 0)                                          // one frame rejected in Lightroom is not a decision
        model.openPicker()
        try picker(model).tick()                                            // pick the frame you rejected in Lightroom
        model.keepPicked()
        #expect(model.toast?.text == "Kept B1 · 1 rejected with a note · Lightroom keeps your own flag on it")
    }

    @Test func aKeepOverTheBudgetSaysHowFarOver() async throws {
        let stacks = (0..<3).map { cullStack($0, .burst, [cullFrame(10 * $0 + 1, file: "B\(10 * $0 + 1).ARW"), cullFrame(10 * $0 + 2)]) }
        let (model, _) = await open(cullDay(stacks, budget: 1))
        for i in 0..<2 {
            model.openPicker()
            try picker(model).tick()
            model.keepPicked()
            #expect(model.toast?.text == (i == 0 ? "Kept B1 · 1 rejected with a note" : "Kept B11 · 1 rejected with a note · 1 over this shoot’s 1"))
        }
    }

    @Test func reKeepingARatedFrameKeepsItsStars() async throws {
        let decisions: [Int: Decision] = [
            101: draft(.pick, stars: 4), 102: draft(.reject, note: "x"), 103: draft(.reject, note: "x"),
        ]
        let (model, rig) = await open(day(3, decisions: decisions))
        model.go(-1)
        model.openPicker(fromStart: false)
        let p = try picker(model)
        #expect(p.viewedStars == 4)
        p.step(1); p.tick()                                                 // add B102 as well
        model.keepPicked()
        #expect(model.decisions[101] == draft(.pick, stars: 4))
        #expect(model.decisions[102] == draft(.pick))
        #expect(model.decisions[103]?.flag == .reject)
        await rig.settle()
        #expect(sentChanges(decided(rig)[0])[0]["stars"] as? Int == 4)
    }

    @Test func nothingTickedCannotBeKept() async throws {
        let (model, rig) = await open(day(4))
        model.openPicker()
        model.keepPicked()
        #expect(model.screen == .picker && model.picker != nil)
        #expect(model.decisions.isEmpty && !model.canUndo)
        await rig.settle()
        #expect(decided(rig).isEmpty)
    }

    @Test func keepingOutsideThePickerDoesNothing() async throws {
        let (model, rig) = await open(day(4))
        model.keepPicked()
        #expect(model.screen == .cards && model.decisions.isEmpty)
        await rig.settle()
        #expect(decided(rig).isEmpty)
    }

    @Test func rejectAllFromThePickerRejectsTheBurstAndMovesOn() async throws {
        let (model, rig) = await open(day(4))
        model.openPicker()
        model.reject()
        #expect(model.toast?.text == "Rejected all 4")
        #expect(model.screen == .cards && model.picker == nil && model.cursor == 1)
        #expect((101...104).allSatisfy { model.decisions[$0] == draft(.reject) })
        await rig.settle()
        #expect(sentChanges(decided(rig)[0]).allSatisfy { $0["via"] as? String == "card" })
    }

    @Test func theCardsDecisionsAreOffWhileThePickerIsOpen() async throws {
        let (model, rig) = await open(day(4))
        model.openPicker()
        model.keep()
        model.keepAll()
        model.go(1)
        model.openPicker()                                                  // already open
        #expect(model.decisions.isEmpty && model.cursor == 0 && model.screen == .picker)
        await rig.settle()
        #expect(decided(rig).isEmpty)
    }

    @Test func closingLeavesTheCardAsItWas() async throws {
        let (model, _) = await open(day(4))
        model.openPicker()
        try picker(model).tick()
        model.closePicker()
        #expect(model.screen == .cards && model.picker == nil)
        model.closePicker()                                                 // nothing to close
        #expect(model.screen == .cards)
        model.openPicker()
        #expect(try picker(model).selected.isEmpty)                         // a fresh picker
    }

    // MARK: Undo

    @Test func undoAfterAPickerKeepBringsBackTheBurstAndItsCard() async throws {
        let (model, rig) = await open(day(5))
        model.openPicker()
        let p = try picker(model)
        p.step(1); p.rate(stars: 2)
        model.keepPicked()
        #expect(model.cursor == 1 && model.canUndo)
        model.undo()
        #expect(model.decisions.isEmpty)
        #expect(model.cursor == 0 && model.screen == .cards && model.picker == nil)
        #expect(model.toast?.text == "Undone: Kept B102 ★★ · 4 rejected with a note")
        #expect(model.feedback?.kind == .undone)
        await rig.settle()
        #expect(rig.server.calls("/m/api/undo").first?.json["action_id"] as? String == "A-1")
    }

    @Test func undoAfterAKeepFromAReopenedBurstPutsBackWhatItHad() async throws {
        let decisions: [Int: Decision] = [101: draft(.pick, stars: 2), 102: draft(.reject, note: "x"), 103: draft(.reject, note: "x")]
        let (model, _) = await open(day(3, decisions: decisions))
        model.go(-1)
        model.openPicker()
        let p = try picker(model)
        p.show(2); p.tick()
        model.keepPicked()
        #expect(model.decisions[103]?.flag == .pick)
        model.undo()
        #expect(model.decisions[103] == draft(.reject, note: "x"))
        #expect(model.decisions[101] == draft(.pick, stars: 2))
    }

    // MARK: Knock-out

    @Test func tappingAFrameOutAndBackInAndKeepingWhatIsLeft() async throws {
        let (model, rig) = await open(day(8))
        model.openPicker()
        let p = try picker(model)
        p.toggleOut(102)
        p.toggleOut(103)
        p.toggleOut(102)                                                    // back in
        #expect(p.knockedOut == [103])
        #expect(p.isOut(103) && !p.isOut(102))
        #expect(p.subtitle == "7 left · tap the weaker frames out")
        #expect(p.keepLabel == "Keep the 7 left")
        for id in 104...108 { p.toggleOut(id) }
        #expect(p.keepLabel == "Keep the 2 left")
        model.keepPicked()
        let note = "Burst reject · kept B101, B102"
        #expect(model.decisions[101] == draft(.pick) && model.decisions[102] == draft(.pick))
        #expect((103...108).allSatisfy { model.decisions[$0] == draft(.reject, note: note) })
        #expect(model.toast?.text == "Kept 2 frames · 6 rejected with a note")
        await rig.settle()
        let changes = sentChanges(decided(rig)[0])
        #expect(changes.allSatisfy { $0["via"] as? String == "burst" && $0["stars"] == nil })
        #expect(changes.map { $0["id"] as? Int } == [101, 102, 103, 104, 105, 106, 107, 108])
    }

    @Test func aKnockOutKeepsOneFrameByNameAndNeverTakesStars() async throws {
        let (model, _) = await open(day(7))
        model.openPicker()
        let p = try picker(model)
        for id in 101...107 where id != 105 { p.toggleOut(id) }
        p.tick()                                                            // the strip's controls do nothing here
        p.rate(stars: 5)
        #expect(p.selected.isEmpty && p.rates.isEmpty && p.keepRates.isEmpty)
        model.keepPicked()
        #expect(model.toast?.text == "Kept B105 · 6 rejected with a note")
        #expect(model.decisions[105] == draft(.pick))
    }

    @Test func aKnockOutWithEveryFrameOutCannotBeKept() async throws {
        let (model, rig) = await open(day(7))
        model.openPicker()
        let p = try picker(model)
        for id in 101...107 { p.toggleOut(id) }
        #expect(p.keeps.isEmpty && !p.canKeep && p.keepLabel == "Keep the 0 left")
        model.keepPicked()
        #expect(model.screen == .picker && model.decisions.isEmpty)
        await rig.settle()
        #expect(decided(rig).isEmpty)
    }

    @Test func aKnockOutTapDecidesBetweenAToggleAndADoubleTap() async throws {
        let (model, _) = await open(day(8))
        model.openPicker()
        let p = try picker(model)
        let t0 = ContinuousClock.now
        #expect(p.tapKnockOut(2, at: t0) == .toggled)
        #expect(p.knockedOut == [103])
        // A second tap on the same tile soon after takes the first one's toggle back and asks for focus.
        #expect(p.tapKnockOut(2, at: t0.advanced(by: .milliseconds(200))) == .focus)
        #expect(p.knockedOut.isEmpty)
        // A third tap straight after is a new first tap, not another double.
        #expect(p.tapKnockOut(2, at: t0.advanced(by: .milliseconds(300))) == .toggled)
        #expect(p.knockedOut == [103])
        // Too slow, or another tile: two single taps.
        #expect(p.tapKnockOut(2, at: t0.advanced(by: .milliseconds(900))) == .toggled)
        #expect(p.knockedOut.isEmpty)
        #expect(p.tapKnockOut(4, at: t0.advanced(by: .milliseconds(1000))) == .toggled)
        #expect(p.tapKnockOut(5, at: t0.advanced(by: .milliseconds(1100))) == .toggled)
        #expect(p.knockedOut == [105, 106])
        #expect(p.tapKnockOut(99, at: t0.advanced(by: .milliseconds(1200))) == .toggled)   // no such tile
    }

    @Test func aDoubleTapOnAFrameThatWasOutLeavesItOut() async throws {
        let (model, _) = await open(day(7))
        model.openPicker()
        let p = try picker(model)
        p.toggleOut(101)                                                    // out already
        let t0 = ContinuousClock.now
        #expect(p.tapKnockOut(0, at: t0) == .toggled && !p.isOut(101))      // the first tap brought it back
        #expect(p.tapKnockOut(0, at: t0.advanced(by: .milliseconds(100))) == .focus)
        #expect(p.isOut(101))                                               // and the second put it back out, as it was
    }

    // MARK: The card

    @Test func aBurstCardsKeepButtonIsChooseAndASingleCardsIsKeep() async throws {
        let (model, _) = await open(day(3))
        #expect(try #require(model.card).keepLabel == "Choose")
        model.openPicker()
        model.reject()
        #expect(try #require(model.card).keepLabel == "Keep")
    }
}
