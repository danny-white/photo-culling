import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Cull: Send all")
struct CullSendAllModelTests {
    private func day(
        _ id: String, finished: Bool, unsent: Int?, decided: Int = 10, sent: Int = 0, place: String? = nil
    ) -> Day {
        Day(day: id, folder: String(id.split(separator: "/").last ?? ""), date: String(id.suffix(10)),
            frames: 20, stacks: 12, thumbs: [], lastTs: 0, place: place, places: [], gpsFrames: 0,
            decided: decided, sent: sent, landed: 0, conflicts: 0, lrDone: 0, finished: finished, unsent: unsent)
    }

    private func model(_ days: [Day], rig: CullRig) -> CullSendAllModel {
        CullSendAllModel(days: days, client: rig.client, queue: rig.queue)
    }

    @Test func finishedDaysAreTickedAndUnfinishedOnesListedUnticked() {
        let rig = CullRig(day: cullDay([]))
        let m = model([
            day("2026/2026-09-29", finished: true, unsent: 12, place: "victoria, british columbia, canada"),
            day("2026/2026-08-04", finished: false, unsent: 3),
            day("2026/2026-08-03", finished: true, unsent: 0),           // nothing to send: not listed
            day("2026/2026-04-18", finished: true, unsent: 2),
        ], rig: rig)
        #expect(m.finished.map(\.id) == ["2026/2026-09-29", "2026/2026-04-18"])
        #expect(m.unfinished.map(\.id) == ["2026/2026-08-04"])
        #expect(m.selected == ["2026/2026-09-29", "2026/2026-04-18"])
        #expect(m.finished[0].place == "victoria, british columbia")
        #expect(m.finished[0].countText == "12 decisions")
        #expect(m.selectionText == "14 decisions from 2 days")
        #expect(m.sendLabel == "Send 2 days to Lightroom")
        m.toggle("2026/2026-09-29")
        m.toggle("2026/2026-08-04")
        #expect(m.selectionText == "5 decisions from 2 days")
        m.selectNone()
        #expect(m.sendLabel == "Pick the days to send")
        m.selectAll()
        #expect(m.selected.count == 3)
        m.toggle("nonsense")
        #expect(m.selected.count == 3)
    }

    @Test func anOlderServerWithoutUnsentFallsBackToDecidedMinusSent() {
        #expect(CullSendAllModel.unsent(day("2026/2026-09-29", finished: true, unsent: nil, decided: 46, sent: 6)) == 40)
        #expect(CullSendAllModel.unsent(day("2026/2026-09-29", finished: true, unsent: nil, decided: 3, sent: 3)) == 0)
    }

    @Test func sendPostsTheTickedDaysInTheListsOrder() async {
        let rig = CullRig(day: cullDay([]))
        rig.server.on("POST send") { _ in
            Reply(body: #"{"ok":true,"queued":14,"file_rows":16,"days":[{"day":"2026/2026-09-29","queued":12},{"day":"2026/2026-04-18","queued":2}]}"#)
        }
        let m = model([
            day("2026/2026-09-29", finished: true, unsent: 12),
            day("2026/2026-08-04", finished: false, unsent: 3),
            day("2026/2026-04-18", finished: true, unsent: 2),
        ], rig: rig)
        #expect(await m.send())
        #expect(m.didSend)
        #expect(m.message == "Queued 14 decisions from 2 days for Lightroom. On the Mac: Sync AI Cull Data.")
        let call = rig.server.calls("/m/api/send").first
        #expect(call?.method == "POST")
        let body = call.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: [String]] }
        #expect(body?["days"] == ["2026/2026-09-29", "2026/2026-04-18"])
    }

    @Test func aRefusedSendSaysWhyAndStaysOpen() async {
        let rig = CullRig(day: cullDay([]))
        rig.server.on("POST send") { _ in Reply(status: 503, body: #"{"error":"the inbox share is not mounted; nothing was sent"}"#) }
        let m = model([day("2026/2026-09-29", finished: true, unsent: 12)], rig: rig)
        #expect(await m.send() == false)
        #expect(!m.didSend)
        #expect(m.message.hasPrefix("Not sent: "))
        #expect(m.message.contains("inbox share is not mounted"))
    }

    @Test func nothingTickedSendsNothing() async {
        let rig = CullRig(day: cullDay([]))
        let m = model([day("2026/2026-08-04", finished: false, unsent: 3)], rig: rig)
        #expect(await m.send() == false)
        #expect(rig.server.calls("/m/api/send").isEmpty)
    }
}
