import Foundation
import Testing
@testable import CullingBayCore

/// The data behind the card and the review: `vCull` and `vSummary`.
@MainActor
@Suite("Cull: card and summary")
struct CullCardTests {
    private func open(_ day: CullDay) async -> CullSessionModel {
        let rig = CullRig(day: day)
        let model = rig.session()
        await model.load()
        return model
    }

    private func burst(_ id: Int, count: Int = 3, kind: StackKind = .burst, lead: Int? = nil) -> Stack {
        cullStack(id, kind, (0..<count).map { cullFrame(id * 100 + $0, file: "B\(id * 100 + $0).ARW") }, lead: lead)
    }

    // MARK: Card

    @Test func aSingleWithAJpegPartnerShowsItsChipAndBadges() async throws {
        let day = cullDay([
            cullStack(0, .single, [cullFrame(100, file: "S100.ARW", badges: ["Blown"], partners: ["S100.JPG", "S100.heic"])]),
            cullStack(1, .single, [cullFrame(101)]),
        ])
        let card = try #require(await open(day).card)
        #expect(card.chip == .partners("RAW + JPG + HEIC"))
        #expect(card.chip?.text == "RAW + JPG + HEIC")
        #expect(card.badges == [CullBadge(text: "Blown", style: .measured)])
        #expect(card.fileLine == "S100.ARW + S100.JPG + S100.heic · 1/2")
        #expect(!card.isBurst && !card.suggestsKeepAll && card.strip.isEmpty && card.stripMore == 0)
        #expect(card.statusLine == nil && card.stars == 0)
        #expect(card.pressed == CullPressed(reject: false, keepAll: false, keep: false))
        let plain = try #require(await open(cullDay([cullStack(0, .single, [cullFrame(1)])])).card)
        #expect(plain.chip == nil && plain.badges.isEmpty)
    }

    @Test func aPanoramaAndABracketSuggestKeepAllUntilDecided() async throws {
        let model = await open(cullDay([burst(0, kind: .pano), burst(1, kind: .bracket), burst(2)]))
        var card = try #require(model.card)
        #expect(card.badges == [CullBadge(text: "Looks like a panorama", style: .hint)])
        #expect(card.suggestsKeepAll)
        model.keepAll()
        card = try #require(model.card)
        #expect(card.badges == [CullBadge(text: "Looks like a bracket", style: .hint)])
        #expect(card.suggestsKeepAll)
        model.go(-1)
        card = try #require(model.card)
        #expect(!card.suggestsKeepAll)                                      // decided now
        #expect(card.statusLine?.text == "Kept all 3 · panorama")
        #expect(try #require(model.card).keepAllLabel == "Keep all 3")
    }

    @Test func aBurstShowsItsChipSharpestBadgeAndStrip() async throws {
        let model = await open(cullDay([
            cullStack(0, .burst, (0..<8).map { cullFrame(10 + $0, badges: $0 == 2 ? ["Softer"] : []) }, lead: 12),
        ]))
        let card = try #require(model.card)
        #expect(card.isBurst && card.chip == .burst(count: 8) && card.chip?.text == "8")
        #expect(card.frame.id == 12)
        #expect(card.badges == [CullBadge(text: "Sharpest", style: .hint), CullBadge(text: "Softer", style: .measured)])
        #expect(card.strip.map(\.frame.id) == [10, 11, 12, 13, 14, 15])
        #expect(card.stripMore == 2)
        #expect(card.strip.allSatisfy { $0.mark == .clear })
        #expect(card.stars == 0)                                            // a burst has no star row
    }

    @Test func theStripMarksWhatWasDecidedAndTheCardShowsTheKeptFrame() async throws {
        let model = await open(cullDay([
            cullStack(0, .burst, [
                cullFrame(1), cullFrame(2, decision: draft(.pick, stars: 4)), cullFrame(3, decision: draft(.reject)),
            ], lead: 1),
            cullStack(1, .single, [cullFrame(9)]),
        ]))
        model.go(-1)
        let card = try #require(model.card)
        #expect(card.frame.id == 2)
        #expect(card.badges.isEmpty)                                         // not the sharpest any more
        #expect(card.strip.map(\.mark) == [.clear, .pick, .reject])
    }

    @Test func yourLightroomFlagShowsAsABadgeWhenThePhoneDecidedOtherwise() async throws {
        let model = await open(cullDay([
            cullStack(0, .single, [cullFrame(1, lr: lrByYou(pick: -1), decision: draft(.pick, state: .conflict))]),
            cullStack(1, .single, [cullFrame(2)]),
        ]))
        model.go(-1)
        #expect(try #require(model.card).badges == [CullBadge(text: "Rejected in Lightroom", style: .lightroom)])
        // a stack decided in Lightroom only already says so on the photo: no badge
        let only = await open(cullDay([cullStack(0, .single, [cullFrame(3, lr: lrByYou(pick: 1))]), cullStack(1, .single, [cullFrame(4)])]))
        only.go(-1)
        let card = try #require(only.card)
        #expect(card.badges.isEmpty && card.statusLine?.text == "Picked in Lightroom")
    }

    @Test func thePressedButtonShowsWhereTheDecisionWasMade() async throws {
        let model = await open(cullDay([
            cullStack(0, .single, [cullFrame(1)]), cullStack(1, .single, [cullFrame(2)]),
            cullStack(2, .single, [cullFrame(3)]), burst(3), burst(4), burst(5),
            cullStack(6, .single, [cullFrame(7)]),
        ]))
        model.keep()                                                          // 0 kept
        model.keep(stars: 5)                                                  // 1 hero
        model.reject()                                                        // 2 rejected
        model.keepAll()                                                       // 3 kept all
        model.keep()                                                          // 4 one kept
        model.reject()                                                        // 5 rejected all
        func pressed(_ index: Int) throws -> CullPressed {
            model.go(index - model.cursor)
            return try #require(model.card).pressed
        }
        #expect(try pressed(0) == CullPressed(reject: false, keepAll: false, keep: true))
        #expect(try pressed(1) == CullPressed(reject: false, keepAll: false, keep: true))    // Keep, for a hero too
        #expect(try pressed(2) == CullPressed(reject: true, keepAll: false, keep: false))
        #expect(try pressed(3) == CullPressed(reject: false, keepAll: true, keep: false))
        #expect(try pressed(4) == CullPressed(reject: false, keepAll: false, keep: true))    // Choose
        #expect(try pressed(5) == CullPressed(reject: true, keepAll: false, keep: false))
        #expect(try pressed(6) == CullPressed(reject: false, keepAll: false, keep: false))   // still open
    }

    @Test func aBurstKeptInLightroomPressesChooseNotKeepAll() async throws {
        let model = await open(cullDay([
            cullStack(0, .burst, [cullFrame(1, lr: lrByYou(pick: 1)), cullFrame(2)]), cullStack(1, .single, [cullFrame(3)]),
        ]))
        model.go(-1)
        #expect(try #require(model.card).pressed == CullPressed(reject: false, keepAll: false, keep: true))
    }

    @Test func theStarRowShowsTheKeptRating() async throws {
        let model = await open(cullDay([
            cullStack(0, .single, [cullFrame(1)]), cullStack(1, .single, [cullFrame(2)]), cullStack(2, .single, [cullFrame(3)]),
        ]))
        model.keep(stars: 3)
        model.reject()
        model.go(-2)
        #expect(try #require(model.card).stars == 3)
        model.go(1)
        #expect(try #require(model.card).stars == 0)                        // rejected
    }

    @Test func stacksToGoCountsAndPluralises() async {
        let model = await open(cullDay((0..<3).map { cullStack($0, .single, [cullFrame(10 + $0)]) }))
        #expect(model.toGoText == "3 stacks to go")
        model.keep()
        #expect(model.toGoText == "2 stacks to go" && model.stacksLeft == 2)
        model.keep()
        #expect(model.toGoText == "1 stack to go")
        model.keep()
        #expect(model.toGoText == "0 stacks to go")
    }

    @Test func theProgressFractionIsTheShareOfStacksDecided() async {
        let model = await open(cullDay((0..<4).map { cullStack($0, .single, [cullFrame(10 + $0)]) }))
        #expect(model.progressFraction == 0)
        model.keep()
        #expect(model.progressFraction == 0.25)
        #expect(await open(cullDay([])).progressFraction == 0)
    }

    @Test func theBudgetBarCountsKeptStacksAndTurnsAmber() async throws {
        let model = await open(cullDay((0..<4).map { cullStack($0, .single, [cullFrame(10 + $0)]) }, budget: 2))
        var bar = try #require(model.budgetBar)
        #expect(bar.text == "Kept 0 of 2" && bar.fraction == 0 && !bar.isOver)
        #expect(bar.detail == "10 stacks an hour of shooting (0.5 h)")
        model.keep(); model.keep()
        bar = try #require(model.budgetBar)
        #expect(bar.text == "Kept 2 of 2" && bar.fraction == 1 && !bar.isOver)
        model.keep()
        bar = try #require(model.budgetBar)
        #expect(bar.text == "Kept 3 · 1 over 2" && bar.fraction == 1 && bar.isOver)
        #expect(await open(cullDay([cullStack(0, .single, [cullFrame(1)])], budget: 0)).budgetBar == nil)
    }

    @Test func theTitleIsTheBritishDate() async {
        #expect(await open(cullDay([cullStack(0, .single, [cullFrame(1)])])).title == "Thu, 1 Oct 2026")
        #expect(await open(cullDay([cullStack(0, .single, [cullFrame(1)])], date: nil)).title == "2026-10-01")
    }

    // MARK: Summary

    /// Eight stacks that put one frame in each of the review's groups.
    private func reviewDay(budget: Int = 2) -> CullDay {
        cullDay([
            cullStack(0, .single, [cullFrame(100, decision: draft(.pick))]),
            cullStack(1, .single, [cullFrame(101, decision: draft(.pick, stars: 5, state: .queued))]),
            cullStack(2, .burst, [
                cullFrame(110, decision: draft(.reject, note: "Burst reject · kept B111", state: .landed)),
                cullFrame(111, decision: draft(.pick, state: .landed)),
            ]),
            cullStack(3, .single, [cullFrame(120, decision: draft(.reject))]),
            cullStack(4, .single, [cullFrame(130, lr: lrByYou(pick: 1))]),
            cullStack(5, .single, [cullFrame(140)]),
            cullStack(6, .single, [cullFrame(150, lr: lrByYou(pick: -1), decision: draft(.pick, state: .conflict))]),
            cullStack(7, .single, [cullFrame(160, decision: draft(.reject, state: .missing))]),
        ], budget: budget, summary: "Dune walk\nand sunset")
    }

    @Test func theSummaryCountsFramesByWhatBecameOfThem() async {
        let summary = await open(reviewDay()).summary
        #expect(summary.kept == 3)            // 100, 111 and 150 (a conflict is still a keep on the phone)
        #expect(summary.hero == 1)
        #expect(summary.rejected == 3)        // 110, 120, 160
        #expect(summary.unflagged == 1)       // 140; 130 was culled in Lightroom, so it is not "unflagged"
        #expect(summary.subtitle == "Rejects so far")           // 140 is still open
        #expect(summary.daySummary == "Dune walk\nand sunset")
    }

    @Test func theSummaryShowsWhereTheDecisionsHaveGotTo() async {
        let summary = await open(reviewDay()).summary
        #expect(summary.unsent == 3 && summary.missing == 1)    // 100, 120 draft; 160 missing
        #expect(summary.queued == 1 && summary.landed == 2 && summary.conflicts == 1)
        #expect(summary.lightroomLines == [
            "2 in Lightroom", "1 waiting for the next Sync AI Cull Data",
            "1 not found in the last sync, will go again",
            "1 stack was already flagged or rated in Lightroom and skipped",
        ])
        #expect(summary.sendLabel == "Send 3 to Lightroom" && summary.canSend)
    }

    @Test func theLightroomLinesPluraliseTheSkippedStacks() async {
        let day = cullDay([
            cullStack(0, .single, [cullFrame(1, lr: lrByYou(pick: 1))]), cullStack(1, .single, [cullFrame(2, lr: lrByYou(pick: -1))]),
        ])
        let summary = await open(day).summary
        #expect(summary.lightroomLines == ["2 stacks were already flagged or rated in Lightroom and skipped"])
        #expect(summary.subtitle == "Day finished")
        #expect(!summary.canSend && summary.sendLabel == "Send to Lightroom")
    }

    @Test func yourLightroomFlagWonListsTheFramesWithTheirLabels() async {
        let summary = await open(reviewDay()).summary
        #expect(summary.won.map(\.frame.id) == [150])
        #expect(summary.won.map(\.label) == ["Rejected in LR"])
        #expect(summary.wonNote == "The phone said otherwise, but you had flagged this in Lightroom yourself, so Lightroom kept your flag. Change it there if the phone was right.")
        let two = cullDay([
            cullStack(0, .single, [cullFrame(1, lr: lrByYou(pick: 1), decision: draft(.reject, state: .conflict))]),
            cullStack(1, .single, [cullFrame(2, lr: lrByYou(pick: -1), decision: draft(.pick, state: .conflict))]),
        ])
        let both = await open(two).summary
        #expect(both.won.map(\.label) == ["Picked in LR", "Rejected in LR"])
        #expect(both.wonNote?.contains("flagged these in Lightroom yourself") == true)
        #expect(both.rejectsOutright.isEmpty)                       // a conflict is not in the reject lists
        #expect(await open(cullDay([cullStack(0, .single, [cullFrame(1)])])).summary.wonNote == nil)
    }

    @Test func rejectsAreSplitByWhetherABurstKeepLeftANote() async {
        let summary = await open(reviewDay()).summary
        #expect(summary.rejectsFromBursts.map(\.id) == [110])
        #expect(summary.rejectsOutright.map(\.id) == [120, 160])
    }

    @Test func theBudgetNoteSaysHowFarOverOrHowMuchIsLeft() async {
        let over = await open(reviewDay(budget: 2)).summary       // five stacks kept (100, 101, 111's, 130, 150)
        #expect(over.overBudget == 3)
        #expect(over.budgetHeading == "Kept · 5 of 2")
        #expect(over.budgetNote == "3 over this shoot’s budget of 2 (10 stacks an hour of shooting).")
        #expect(over.budgetDropHint == "Tap a stack to drop it.")
        let within = await open(reviewDay(budget: 9)).summary
        #expect(within.overBudget == 0 && within.budgetHeading == nil && within.budgetDropHint == nil)
        #expect(within.budgetNote == "Kept 5 of this shoot’s budget of 9.")
        #expect(await open(reviewDay(budget: 0)).summary.budgetNote == nil)
    }

    @Test func theSendLabelFollowsTheDecisionsStates() async {
        func label(_ states: [DecisionState]) async -> (String, Bool) {
            let stacks = states.enumerated().map { i, state in
                cullStack(i, .single, [cullFrame(10 + i, decision: draft(.pick, state: state))])
            }
            let summary = await open(cullDay(stacks)).summary
            return (summary.sendLabel, summary.canSend)
        }
        #expect(await label([.draft, .queued, .landed]) == ("Send 1 to Lightroom", true))
        #expect(await label([.missing, .missing]) == ("Send 2 to Lightroom", true))
        #expect(await label([.queued, .landed]) == ("Waiting for Lightroom", false))
        #expect(await label([.landed, .conflict]) == ("In Lightroom", false))
        #expect(await label([.conflict]) == ("Send to Lightroom", false))
        #expect(await label([]) == ("Send to Lightroom", false))
    }
}
