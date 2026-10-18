import Foundation
import Testing
@testable import CullingBayCore

@Suite("Cull models")
struct CullModelsTests {
    let decoder = JSONDecoder()

    // MARK: Day

    @Test func cullDayDecodesTheRealShape() throws {
        let day = try decoder.decode(CullDay.self, from: Data(cullDayJSON.utf8))
        #expect(day.id == "2026/2026-10-01")
        #expect(day.folder == "2026-10-01")
        #expect(day.isoDate == DateComponents(year: 2026, month: 10, day: 1))
        #expect(day.summary == "Coastal rock formations and cliffs at dusk.")
        #expect(day.budget == Budget(stacks: 5, perHour: 10, hours: 0.19))
        #expect(day.progress == Progress(pass: 2, cursor: 1))
        #expect(day.stacks.map(\.id) == [0, 1, 2])
        #expect(day.stacks.map(\.kind) == [.single, .burst, .bracket])
        #expect(day.stacks.map(\.frames.count) == [1, 2, 2])
        #expect(day.stacks.allSatisfy { stack in stack.frames.contains { $0.id == stack.lead } })
    }

    @Test func aFrameDecodesEveryField() throws {
        let day = try decoder.decode(CullDay.self, from: Data(cullDayJSON.utf8))
        let frame = day.stacks[2].frames[1]
        #expect(frame.id == 43214)
        #expect(frame.file == "DSC05041.ARW")
        #expect(frame.partners == ["DSC05041.JPG"])
        #expect(frame.partnerIDs == [99041])
        #expect(frame.sharpness == 16.4)
        #expect(frame.af == nil)
        #expect(frame.badges.isEmpty)
        #expect(frame.lens == "24-70mm F2.8 DG DN | Art 019")
        #expect(frame.meanLum == 32.0)
        #expect(frame.blownPct == 0.0)
        #expect(frame.place == "greenwood, washington, us")
        #expect(frame.lr == LightroomState(pick: 1, rating: 0, by: .phone, starsBy: .unset))
        #expect(frame.decision == Decision(flag: .pick, state: .landed, outcome: "your 3 kept"))
        #expect(day.stacks[0].frames[0].af == [0.5, 0.454])
    }

    @Test func decisionsCoverTheirStates() throws {
        let day = try decoder.decode(CullDay.self, from: Data(cullDayJSON.utf8))
        let reject = try #require(day.stacks[1].frames[0].decision)
        #expect(reject.flag == .reject)
        #expect(reject.stars == nil)
        #expect(reject.note == "Burst reject \u{00B7} kept DSC05038")
        #expect(reject.state == .draft)
        let conflict = try #require(day.stacks[1].frames[1].decision)
        #expect(conflict == Decision(flag: .pick, stars: 4, state: .conflict, outcome: "rejected"))
        #expect(day.stacks[1].frames[0].badges == ["Softer"])
        #expect(day.stacks[2].frames[0].decision == nil)
        #expect(day.stacks[2].frames[0].lr == nil)
    }

    @Test func lightroomStateReadsWhoSetWhat() throws {
        let day = try decoder.decode(CullDay.self, from: Data(cullDayJSON.utf8))
        let lr = try #require(day.stacks[1].frames[1].lr)
        #expect(lr.pick == -1 && lr.isRejected && !lr.isPicked)
        #expect(lr.rating == 2)
        #expect(lr.by == .you)
        #expect(lr.starsBy == .phone)
        let phone = try #require(day.stacks[0].frames[0].lr)
        #expect(phone.isPicked && !phone.isRejected)
    }

    @Test func aDayWithNullsAndNoProgressDecodes() throws {
        let json = """
        {"day":"misc/unsorted","folder":"unsorted","date":null,"summary":null,
         "budget":{"stacks":5,"per_hour":10,"hours":0.0},"stacks":[],"progress":null}
        """
        let day = try decoder.decode(CullDay.self, from: Data(json.utf8))
        #expect(day.date == nil && day.isoDate == nil && day.summary == nil)
        #expect(day.progress == nil)
        #expect(day.stacks.isEmpty)
        #expect(day.budget.hours == 0)
    }

    @Test func progressAfterASendWithNoSavedPositionIsAllNil() throws {
        let json = """
        {"day":"d","folder":"d","budget":{"stacks":5,"per_hour":10,"hours":1},"stacks":[],
         "progress":{"pass":null,"cursor":null}}
        """
        let day = try decoder.decode(CullDay.self, from: Data(json.utf8))
        #expect(day.progress == Progress(pass: nil, cursor: nil))
    }

    @Test func aFrameMissingAKeyThatIsAlwaysThereIsADecodingError() {
        let json = #"{"id":1,"kind":"single","lead":1,"frames":[{"id":1,"file":"A.ARW"}]}"#
        #expect(throws: DecodingError.self) { try decoder.decode(Stack.self, from: Data(json.utf8)) }
    }

    // MARK: Closed value sets

    @Test func everyDocumentedKindDecodes() throws {
        for (raw, kind) in [("single", StackKind.single), ("burst", .burst), ("bracket", .bracket), ("pano", .pano)] {
            let stack = try decoder.decode(Stack.self, from: Data(stackJSON(kind: raw).utf8))
            #expect(stack.kind == kind)
            #expect(stack.kind.rawValue == raw)
        }
    }

    @Test func anUnknownKindDoesNotFailTheDay() throws {
        let json = cullDayJSON.replacingOccurrences(of: #""kind":"burst""#, with: #""kind":"timelapse""#)
        let day = try decoder.decode(CullDay.self, from: Data(json.utf8))
        #expect(day.stacks[1].kind == .other("timelapse"))
        #expect(day.stacks[0].kind == .single)
        #expect(day.stacks[1].frames.count == 2)
    }

    @Test func unknownFlagStateAndSourceValuesAreKept() throws {
        let json = cullDayJSON
            .replacingOccurrences(of: #""state":"conflict""#, with: #""state":"rolled_back""#)
            .replacingOccurrences(of: #""flag":"reject""#, with: #""flag":"star""#)
            .replacingOccurrences(of: #""by":"you""#, with: #""by":"auto""#)
        let day = try decoder.decode(CullDay.self, from: Data(json.utf8))
        #expect(day.stacks[1].frames[1].decision?.state == .other("rolled_back"))
        #expect(day.stacks[1].frames[0].decision?.flag == .other("star"))
        #expect(day.stacks[1].frames[1].lr?.by == .other("auto"))
    }

    @Test func openEnumsEncodeBackToTheirWireValue() throws {
        struct Holder: Codable, Equatable {
            var flag: CullFlag
            var via: CullVia
            var kind: StackKind
            var state: DecisionState
            var source: LightroomSource
        }
        let holder = Holder(flag: .clear, via: .rescue, kind: .other("x"), state: .missing, source: .unset)
        let data = try JSONEncoder().encode(holder)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["flag": "none", "via": "rescue", "kind": "x", "state": "missing", "source": ""])
        #expect(try decoder.decode(Holder.self, from: data) == holder)
    }

    @Test func knownRawValuesNeverBecomeOther() {
        #expect(CullFlag(rawValue: "none") == .clear)
        #expect(CullFlag(rawValue: "pick") == .pick)
        #expect(CullVia(rawValue: "sweep") == .sweep)
        #expect(DecisionState(rawValue: "queued") == .queued)
        #expect(LightroomSource(rawValue: "") == .unset)
        #expect(LightroomSource(rawValue: "you") == .you)
        #expect(StackKind(rawValue: "pano") == .pano)
    }

    // MARK: Day search

    @Test func daySearchDecodes() throws {
        let result = try decoder.decode(DaySearchResult.self, from: Data(daySearchJSON.utf8))
        #expect(result.query == "DSC05040")
        #expect(result.photos == 2)
        #expect(result.signals == ["words"])
        #expect(result.notes.isEmpty)
        #expect(result.days.map(\.id) == ["2026/2026-10-01", "2025/2025-06-02"])
        #expect(result.days[0] == DayMatch(
            day: "2026/2026-10-01", n: 2, ids: [43203, 43214], matchIDs: [43203, 43214],
            why: "2 photos \u{00B7} \u{201C}silhouettes\u{201D}"))
        #expect(result.days[1].n == 0 && result.days[1].ids.isEmpty)
        #expect(result.days[1].why == "Near Greenwood")
    }

    @Test func dayLikeHasNoQuery() throws {
        let result = try decoder.decode(DaySearchResult.self, from: Data(dayLikeJSON.utf8))
        #expect(result.query == nil)
        #expect(result.signals == ["pictures"])
        #expect(result.days[0].matchIDs.count == 5)
    }

    // MARK: Request and answer bodies

    @Test func aChangeLeavesOutWhatItDoesNotSet() throws {
        let change = CullChange(id: 7, flag: .reject, via: .card)
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "flag", "via"])
        #expect(object["flag"] as? String == "reject")
        let full = CullChange(id: 7, flag: .pick, stars: 5, note: "n", via: .burst)
        let all = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        #expect(Set(all.keys) == ["id", "flag", "stars", "note", "via"])
        #expect(all["stars"] as? Int == 5)
    }

    @Test func anAckWithoutReplayIsNotAReplay() throws {
        #expect(try decoder.decode(CullAck.self, from: Data(#"{"ok":true}"#.utf8)) == CullAck(ok: true, replay: false))
        #expect(try decoder.decode(CullAck.self, from: Data(#"{"ok":true,"replay":true}"#.utf8)).replay)
    }

    @Test func sendAndResetAnswersDecode() throws {
        let sent = try decoder.decode(SendResult.self, from: Data(#"{"ok":true,"queued":3,"file_rows":4}"#.utf8))
        #expect(sent == SendResult(queued: 3, fileRows: 4))
        let reset = try decoder.decode(ResetResult.self, from: Data(#"{"ok":true,"cleared":3,"withdrawn":4}"#.utf8))
        #expect(reset == ResetResult(cleared: 3, withdrawn: 4))
    }
}
