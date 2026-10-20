import Foundation
import Testing
@testable import CullingBayCore

@Suite("Cull: formats")
struct CullFormatTests {
    @Test func stemDropsTheLastExtensionOnly() {
        #expect(CullFormat.stem("DSC05040.ARW") == "DSC05040")
        #expect(CullFormat.stem("a.b.JPG") == "a.b")
        #expect(CullFormat.stem("noext") == "noext")
        #expect(CullFormat.stem("trailing.") == "trailing.")
    }

    @Test func starTextRepeatsTheStar() {
        #expect(CullFormat.starText(3) == "★★★")
        #expect(CullFormat.starText(0) == "")
    }

    @Test func dayTitleIsTheBritishShortDateOrTheFolder() {
        #expect(CullFormat.dayTitle(date: "2026-10-17", folder: "2026-10-17") == "Sat, 17 Oct 2026")
        #expect(CullFormat.dayTitle(date: "2026-09-01", folder: "x") == "Tue, 1 Sept 2026")
        #expect(CullFormat.dayTitle(date: "2024-02-29", folder: "x") == "Thu, 29 Feb 2024")
        #expect(CullFormat.dayTitle(date: nil, folder: "unsorted") == "unsorted")
        #expect(CullFormat.dayTitle(date: "2026-13-40", folder: "weird") == "weird")
    }

    @Test func numbersPrintTheWayJavaScriptDoes() {
        #expect(CullFormat.grouped(1234567) == "1,234,567")
        #expect(CullFormat.grouped(999) == "999")
        #expect(CullFormat.number(2) == "2")
        #expect(CullFormat.number(0.19) == "0.19")
    }

    @Test func errorTextIsTheServersOrTheStatus() {
        #expect(CullFormat.errorText(CullingBayError.http(status: 400, message: "bad")) == "bad")
        #expect(CullFormat.errorText(CullingBayError.http(status: 404, message: nil)) == "HTTP 404")
        #expect(CullFormat.errorText(CullingBayError.conflict(message: nil, applied: 2)) == "HTTP 409")
        #expect(CullFormat.errorText(CullingBayError.unavailable(message: "inbox")) == "inbox")
    }
}

/// The rules of `app.js` that turn decisions into what a card says.
@Suite("Cull: board rules")
struct CullBoardTests {
    private func board(_ stacks: [Stack], _ decisions: [Int: Decision] = [:], budget: Int = 0) -> CullBoard {
        CullBoard(stacks: stacks, decisions: decisions, budget: budget)
    }

    private func lr(_ by: LightroomSource, pick: Int = 0, rating: Int = 0, starsBy: LightroomSource? = nil) -> LightroomState {
        LightroomState(pick: pick, rating: rating, by: by, starsBy: starsBy ?? (rating > 0 ? by : .unset))
    }

    // MARK: lrMark

    @Test func onlyYourOwnLightroomFlagsAndStarsCount() {
        let b = board([])
        #expect(b.lrMark(cullFrame(1, lr: lr(.you, pick: -1))) == .reject)
        #expect(b.lrMark(cullFrame(2, lr: lr(.you, pick: 1))) == .pick)
        #expect(b.lrMark(cullFrame(3, lr: lr(.unset, rating: 3, starsBy: .you))) == .rated)
        #expect(b.lrMark(cullFrame(4, lr: lr(.phone, pick: 1))) == nil)             // the plug-in's own, already in decisions
        #expect(b.lrMark(cullFrame(5, lr: lr(.phone, pick: 0, rating: 4, starsBy: .phone))) == nil)
        #expect(b.lrMark(cullFrame(6, lr: lr(.unset, pick: 0, rating: 0))) == nil)
        #expect(b.lrMark(cullFrame(7)) == nil)
    }

    @Test func aFlagOutranksStarsInTheLightroomMark() {
        let both = LightroomState(pick: -1, rating: 4, by: .you, starsBy: .you)
        #expect(board([]).lrMark(cullFrame(1, lr: both)) == .reject)
    }

    @Test func lightroomWordsAndShortWords() {
        let b = board([])
        let pick = cullFrame(1, lr: lr(.you, pick: 1))
        let reject = cullFrame(2, lr: lr(.you, pick: -1))
        let rated = cullFrame(3, lr: lr(.unset, rating: 4, starsBy: .you))
        #expect(b.lrWord(pick) == "Picked in Lightroom" && b.lrShort(pick) == "Picked in LR")
        #expect(b.lrWord(reject) == "Rejected in Lightroom" && b.lrShort(reject) == "Rejected in LR")
        #expect(b.lrWord(rated) == "★4 in Lightroom" && b.lrShort(rated) == "★4 in LR")
        #expect(b.lrWord(cullFrame(4)) == nil && b.lrShort(cullFrame(4)) == "Kept as you set it")
    }

    // MARK: status

    @Test func aPickedFrameKeepsTheStackAndFiveStarsMakeItAHero() {
        let kept = cullStack(0, .burst, [cullFrame(1), cullFrame(2)])
        let b = board([kept], [2: draft(.pick, stars: 3)])
        #expect(b.status(kept).verdict == .keep && b.status(kept).source == .phone)
        let hero = board([kept], [1: draft(.reject), 2: draft(.pick, stars: 5)])
        #expect(hero.status(kept).verdict == .hero)
        let heroAmongKeeps = board([kept], [1: draft(.pick), 2: draft(.pick, stars: 5)])
        #expect(heroAmongKeeps.status(kept).verdict == .hero)
    }

    @Test func aStackIsRejectedOnlyWhenEveryFrameIs() {
        let stack = cullStack(0, .burst, [cullFrame(1), cullFrame(2)])
        #expect(board([stack], [1: draft(.reject), 2: draft(.reject)]).status(stack).verdict == .reject)
        #expect(!board([stack], [1: draft(.reject)]).status(stack).isDone)
        #expect(!board([stack], [1: draft(.reject), 2: draft(.clear)]).status(stack).isDone)
        #expect(!board([stack]).status(stack).isDone)
    }

    @Test func aPickInLightroomKeepsTheStackAndNamesTheFrame() {
        let stack = cullStack(0, .burst, [cullFrame(1), cullFrame(2, lr: lr(.you, pick: 1)), cullFrame(3)])
        let status = board([stack]).status(stack)
        #expect(status.verdict == .keep && status.source == .lightroom)
        #expect(status.frame?.id == 2)
    }

    @Test func aStarRatingAloneAlsoMeansYouHaveBeenThroughIt() {
        let stack = cullStack(0, .single, [cullFrame(1, lr: lr(.unset, rating: 2, starsBy: .you))])
        let status = board([stack]).status(stack)
        #expect(status.verdict == .keep && status.source == .lightroom && status.frame?.id == 1)
    }

    @Test func aPickBeatsAStarRatingForTheFrameItNames() {
        let stack = cullStack(0, .burst, [
            cullFrame(1, lr: lr(.unset, rating: 5, starsBy: .you)), cullFrame(2, lr: lr(.you, pick: 1)),
        ])
        #expect(board([stack]).status(stack).frame?.id == 2)
    }

    @Test func aStackRejectedInLightroomNeedsEveryFrameRejectedThere() {
        let all = cullStack(0, .burst, [cullFrame(1, lr: lr(.you, pick: -1)), cullFrame(2, lr: lr(.you, pick: -1))])
        let status = board([all]).status(all)
        #expect(status.verdict == .reject && status.source == .lightroom)
        let some = cullStack(1, .burst, [cullFrame(3, lr: lr(.you, pick: -1)), cullFrame(4)])
        #expect(!board([some]).status(some).isDone)
    }

    @Test func thePhonesDecisionTakesPrecedenceOverLightroom() {
        // kept on the phone although Lightroom has a reject: the phone's keep stands
        let stack = cullStack(0, .single, [cullFrame(1, lr: lr(.you, pick: -1))])
        let kept = board([stack], [1: draft(.pick)]).status(stack)
        #expect(kept.verdict == .keep && kept.source == .phone)
        // rejected on the phone although Lightroom picked it
        let rejected = board([stack.withFrames([cullFrame(1, lr: lr(.you, pick: 1))])], [1: draft(.reject)])
        #expect(rejected.status(rejected.stacks[0]).verdict == .reject)
        #expect(rejected.status(rejected.stacks[0]).source == .phone)
    }

    @Test func aPartlyRejectedStackFallsThroughToLightroom() {
        let stack = cullStack(0, .burst, [cullFrame(1), cullFrame(2, lr: lr(.you, pick: 1))])
        let status = board([stack], [1: draft(.reject)]).status(stack)
        #expect(status.source == .lightroom && status.verdict == .keep)
    }

    // MARK: shown, firstOpen, counts

    @Test func theCardShowsTheKeptFrameElseTheLead() {
        let burst = cullStack(0, .burst, [cullFrame(1), cullFrame(2), cullFrame(3)], lead: 2)
        #expect(board([burst]).shown(burst).id == 2)
        #expect(board([burst], [3: draft(.pick)]).shown(burst).id == 3)
        #expect(board([burst], [3: draft(.reject)]).shown(burst).id == 2)
        let single = cullStack(1, .single, [cullFrame(9)])
        #expect(board([single]).shown(single).id == 9)
        let strayLead = cullStack(2, .burst, [cullFrame(4), cullFrame(5)], lead: 99)
        #expect(board([strayLead]).leadOf(strayLead).id == 4)
    }

    @Test func firstOpenWrapsRoundAndIsNilWhenAllAreDone() {
        let stacks = (0..<4).map { cullStack($0, .single, [cullFrame(10 + $0)]) }
        let b = board(stacks, [10: draft(.reject), 12: draft(.pick)])
        #expect(b.firstOpen() == 1)
        #expect(b.firstOpen(from: 2) == 3)
        #expect(b.firstOpen(from: 4) == 1)       // from past the end wraps to the start
        let done = board(stacks, [10: draft(.reject), 11: draft(.reject), 12: draft(.pick), 13: draft(.pick)])
        #expect(done.firstOpen() == nil)
        #expect(done.doneCount == 4)
        #expect(board([]).firstOpen() == nil)
    }

    @Test func keptCountIncludesStacksKeptInLightroom() {
        let stacks = [
            cullStack(0, .single, [cullFrame(1)]), cullStack(1, .single, [cullFrame(2)]),
            cullStack(2, .single, [cullFrame(3, lr: lr(.you, pick: 1))]),
            cullStack(3, .single, [cullFrame(4, lr: lr(.you, pick: -1))]),
        ]
        let b = board(stacks, [1: draft(.pick), 2: draft(.reject)])
        #expect(b.keptCount == 2)
        #expect(b.lrDone == 2)
        #expect(b.doneCount == 4)
    }

    // MARK: frameMark

    @Test func frameMarkReadsThePhoneFirstThenLightroom() {
        let b = board([], [1: draft(.reject), 2: draft(.pick, stars: 5), 3: draft(.pick), 4: draft(.pick, stars: 2)])
        #expect(b.frameMark(cullFrame(1)) == FrameMark(verdict: .reject, text: "Rejected", stars: 0))
        #expect(b.frameMark(cullFrame(2)) == FrameMark(verdict: .hero, text: "Hero", stars: 5))
        #expect(b.frameMark(cullFrame(3, lr: lr(.unset, rating: 3, starsBy: .phone)))
            == FrameMark(verdict: .keep, text: "Kept", stars: 3))   // no stars of its own: Lightroom's show
        #expect(b.frameMark(cullFrame(4)) == FrameMark(verdict: .keep, text: "Kept", stars: 2))
        #expect(b.frameMark(cullFrame(5, lr: lr(.you, pick: -1)))
            == FrameMark(verdict: .reject, text: "Rejected in Lightroom", stars: 0))
        #expect(b.frameMark(cullFrame(6, lr: lr(.you, pick: 1, rating: 2)))
            == FrameMark(verdict: .keep, text: "Picked in Lightroom", stars: 2))
        #expect(b.frameMark(cullFrame(7, lr: lr(.unset, rating: 4, starsBy: .you)))
            == FrameMark(verdict: .keep, text: "Rated in Lightroom", stars: 4))
        #expect(b.frameMark(cullFrame(8)) == nil)
    }

    // MARK: clashes and the budget

    @Test func onlyAFlagYouSetInLightroomClashes() {
        let stack = cullStack(0, .burst, [
            cullFrame(1, lr: lr(.you, pick: 1)), cullFrame(2, lr: lr(.you, pick: -1)), cullFrame(3),
            cullFrame(4, lr: lr(.unset, rating: 3, starsBy: .you)),
        ])
        let b = board([stack])
        let rejectAll = stack.frames.map { CullChange(id: $0.id, flag: .reject, via: .card) }
        #expect(b.lrClashes(rejectAll) == 1)          // the pick; the reject agrees; stars are not a flag
        #expect(b.lrRatedRejects(rejectAll) == 1)
        let keepAll = stack.frames.map { CullChange(id: $0.id, flag: .pick, via: .card) }
        #expect(b.lrClashes(keepAll) == 1)            // the reject
        #expect(b.lrRatedRejects(keepAll) == 0)
        let takeOff = stack.frames.map { CullChange(id: $0.id, flag: .clear, via: .rescue) }
        #expect(b.lrClashes(takeOff) == 0)
    }

    @Test func clashNoteWordsOneAndMany() {
        #expect(CullBoard.clashNote(0, 0) == "")
        #expect(CullBoard.clashNote(1, 0) == " · Lightroom keeps your own flag on it")
        #expect(CullBoard.clashNote(3, 0) == " · Lightroom keeps your own flag on 3 of them")
        #expect(CullBoard.clashNote(0, 1) == " · it had your stars in Lightroom")
        #expect(CullBoard.clashNote(0, 2) == " · 2 had your stars in Lightroom")
        #expect(CullBoard.clashNote(2, 1)
            == " · Lightroom keeps your own flag on 2 of them · it had your stars in Lightroom")
    }

    @Test func overNoteAppearsOnlyPastTheBudget() {
        let stacks = (0..<4).map { cullStack($0, .single, [cullFrame(10 + $0)]) }
        let picks: [Int: Decision] = [10: draft(.pick), 11: draft(.pick), 12: draft(.pick)]
        #expect(board(stacks, picks, budget: 3).overNote == "")
        #expect(board(stacks, picks, budget: 2).overNote == " · 1 over this shoot’s 2")
        #expect(board(stacks, picks, budget: 0).overNote == "")
    }

    // MARK: Status line

    @Test func theStatusLineOfASingle() {
        let stack = cullStack(0, .single, [cullFrame(1)])
        #expect(board([stack]).statusLine(stack) == nil)
        #expect(board([stack], [1: draft(.pick)]).statusLine(stack) == CullStatusLine(text: "Kept", verdict: .keep, stars: 0))
        #expect(board([stack], [1: draft(.pick, stars: 5)]).statusLine(stack)
            == CullStatusLine(text: "Hero", verdict: .hero, stars: 5))
        #expect(board([stack], [1: draft(.pick, stars: 3)]).statusLine(stack)?.stars == 3)
        #expect(board([stack], [1: draft(.reject)]).statusLine(stack)
            == CullStatusLine(text: "Rejected", verdict: .reject, stars: 0))
    }

    @Test func theStatusLineOfABurst() {
        let stack = cullStack(0, .burst, [cullFrame(1, file: "DSC1.ARW"), cullFrame(2, file: "DSC2.ARW"), cullFrame(3, file: "DSC3.ARW")])
        func line(_ d: [Int: Decision]) -> String? { board([stack], d).statusLine(stack)?.text }
        #expect(line([1: draft(.reject), 2: draft(.reject), 3: draft(.reject)]) == "Rejected · all 3 frames")
        #expect(line([1: draft(.pick), 2: draft(.pick), 3: draft(.pick)]) == "Kept all 3")
        #expect(line([1: draft(.pick), 2: draft(.pick), 3: draft(.reject)]) == "Kept 2 of 3 · 1 rejected")
        #expect(line([1: draft(.reject), 2: draft(.pick), 3: draft(.reject)]) == "Kept DSC2 · 2 others rejected")
        let pair = cullStack(1, .burst, [cullFrame(4, file: "P4.ARW"), cullFrame(5, file: "P5.ARW")])
        #expect(board([pair], [4: draft(.reject), 5: draft(.pick)]).statusLine(pair)?.text == "Kept P5 · 1 other rejected")
    }

    @Test func bracketsAndPanosSayWhatTheyAre() {
        let frames = [cullFrame(1), cullFrame(2), cullFrame(3)]
        let all: [Int: Decision] = [1: draft(.pick), 2: draft(.pick), 3: draft(.pick)]
        let bracket = cullStack(0, .bracket, frames)
        #expect(board([bracket], all).statusLine(bracket)?.text == "Kept all 3 · bracket")
        let pano = cullStack(0, .pano, frames)
        #expect(board([pano], all).statusLine(pano)?.text == "Kept all 3 · panorama")
        let burst = cullStack(0, .burst, frames)
        #expect(board([burst], all).statusLine(burst)?.text == "Kept all 3")
    }

    @Test func theStatusLineOfAStackFlaggedInLightroom() {
        let picked = cullStack(0, .single, [cullFrame(1, lr: lr(.you, pick: 1, rating: 3))])
        #expect(board([picked]).statusLine(picked) == CullStatusLine(text: "Picked in Lightroom", verdict: .keep, stars: 3))
        let rated = cullStack(1, .single, [cullFrame(2, lr: lr(.unset, rating: 2, starsBy: .you))])
        #expect(board([rated]).statusLine(rated)?.text == "Rated in Lightroom")
        let rejected = cullStack(2, .burst, [cullFrame(3, lr: lr(.you, pick: -1)), cullFrame(4, lr: lr(.you, pick: -1))])
        #expect(board([rejected]).statusLine(rejected)?.text == "Rejected in Lightroom · all 2 frames")
        let lone = cullStack(3, .single, [cullFrame(5, lr: lr(.you, pick: -1))])
        #expect(board([lone]).statusLine(lone)?.text == "Rejected in Lightroom")
    }

    @Test func aConflictAddsYourLightroomFlagWon() {
        let stack = cullStack(0, .single, [cullFrame(1, lr: lr(.you, pick: -1))])
        let line = board([stack], [1: draft(.pick, state: .conflict)]).statusLine(stack)
        #expect(line?.text == "Kept · your Lightroom flag won")
    }
}

extension Stack {
    func withFrames(_ frames: [Frame]) -> Stack {
        Stack(id: id, kind: kind, lead: frames[0].id, frames: frames)
    }
}
