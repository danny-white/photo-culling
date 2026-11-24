import Foundation
import Testing
@testable import CullingBayCore

@Suite("Offline: planner")
struct OfflinePlannerTests {
    private func plan(
        _ days: [Day], pins: [String: OfflinePin] = [:], saved: [String: Int] = [:],
        limit: Int = 1_000_000_000_000, crops: Bool = true
    ) -> OfflinePlan {
        OfflinePlanner.plan(days: days, pins: pins, savedBytes: saved, limitBytes: limit, includeCrops: crops)
    }

    private func ids(_ plan: OfflinePlan) -> [String] { plan.entries.map(\.day.day) }

    // Newest first, as the server sends them.
    private let d5 = planDay("2026-10-05")
    private let d4 = planDay("2026-10-04", decided: 20)                        // partly culled
    private let d3 = planDay("2026-10-03")
    private let d2 = planDay("2026-10-02", decided: 10)                        // partly culled
    private let d1 = planDay("2026-10-01", decided: 100, finished: true)       // finished, all sent

    // MARK: Order

    @Test func partlyCulledDaysComeFirstThenTheNewestUntouchedOnes() {
        let result = plan([d5, d4, d3, d2, d1])
        #expect(ids(result) == ["2026/2026-10-04", "2026/2026-10-02", "2026/2026-10-05", "2026/2026-10-03"])
        #expect(result.entries.map(\.reason) == [.inProgress, .inProgress, .newest, .newest])
        #expect(result.entries.allSatisfy { $0.fits })
    }

    @Test func pinnedAlwaysDaysGoFirstNewestFirstEvenWhenFinished() {
        let result = plan([d5, d4, d3, d2, d1], pins: [d1.day: .always, d3.day: .always])
        #expect(ids(result) == [
            "2026/2026-10-03", "2026/2026-10-01", "2026/2026-10-04", "2026/2026-10-02", "2026/2026-10-05",
        ])
        #expect(result.entries.map(\.reason) == [.always, .always, .inProgress, .inProgress, .newest])
    }

    @Test func neverDaysAreSkipped() {
        let result = plan([d5, d4, d3, d2], pins: [d4.day: .never, d5.day: .never])
        #expect(ids(result) == ["2026/2026-10-02", "2026/2026-10-03"])
    }

    @Test func aFinishedDayWithNothingUnsentIsNotPickedButAnAlwaysPinKeepsIt() {
        #expect(!ids(plan([d1])).contains(d1.day))
        // Finished with nothing decided counts too (an older server: unsent is decided minus sent).
        let empty = planDay("2026-09-30", finished: true)
        #expect(plan([empty]).entries.isEmpty)
        let pinned = plan([d1, empty], pins: [d1.day: .always])
        #expect(ids(pinned) == [d1.day])
        #expect(pinned.entries[0].reason == .always)
    }

    @Test func aFinishedDayWithDecisionsStillToSendMatchesNeitherRule() {
        // Partly culled means not finished; untouched means nothing decided. Only a pin keeps it.
        let waiting = planDay("2026-09-29", decided: 50, sent: 10, finished: true, unsent: 40)
        #expect(plan([waiting]).entries.isEmpty)
        #expect(ids(plan([waiting], pins: [waiting.day: .always])) == [waiting.day])
    }

    @Test func aDayEveryStackOfWhichIsDoneInLightroomIsNotNew() {
        let culled = planDay("2026-09-28", frames: 40, stacks: 40, lrDone: 40)
        let partly = planDay("2026-09-27", frames: 40, stacks: 40, lrDone: 12)
        #expect(ids(plan([culled, partly])) == [partly.day])
    }

    @Test func aPartlyCulledDayStaysInProgressEvenIfLightroomDidItsStacks() {
        let day = planDay("2026-09-26", frames: 40, stacks: 40, decided: 5, lrDone: 40)
        #expect(plan([day]).entries.map(\.reason) == [.inProgress])
    }

    // MARK: The limit

    @Test func daysGoInWhileTheRunningTotalStaysWithinTheLimit() {
        // 100 frames with crops is 57 MB a day.
        let result = plan([d5, d4, d3, d2], limit: 57_000_000 * 3)
        #expect(result.entries.map(\.fits) == [true, true, true, false])
        #expect(ids(result) == ["2026/2026-10-04", "2026/2026-10-02", "2026/2026-10-05", "2026/2026-10-03"])
        #expect(result.plannedBytes == 57_000_000 * 3)
        #expect(result.kept.count == 3)
        #expect(result.limitBytes == 171_000_000)
    }

    @Test func aDayThatJustFitsIsIn() {
        #expect(plan([d5], limit: 5_700_000_0 * 100).entries.map(\.fits) == [true])
        #expect(plan([d5], limit: 57_000_000 - 1).entries.map(\.fits) == [false])
    }

    @Test func aDayThatDoesNotFitDoesNotStopASmallerOneAfterIt() {
        let big = planDay("2026-10-09", frames: 1000, decided: 10)           // 570 MB, in progress
        let small = planDay("2026-10-08", frames: 10, decided: 1)            // 5.7 MB, in progress
        let result = plan([big, small, d5], limit: 100_000_000)
        #expect(ids(result) == [big.day, small.day, d5.day])
        #expect(result.entries.map(\.fits) == [false, true, true])
        #expect(result.plannedBytes == 5_700_000 + 57_000_000)
    }

    @Test func aDayThatDoesNotFitIsNotCountedAgainstTheRest() {
        let big = planDay("2026-10-09", frames: 1000)
        let result = plan([big, d5], limit: 60_000_000)
        #expect(result.entries.map(\.fits) == [false, true])
    }

    @Test func aPinnedDayCanNotFitEither() {
        let result = plan([d1], pins: [d1.day: .always], limit: 1000)
        #expect(result.entries.map(\.fits) == [false])
        #expect(result.kept.isEmpty)
    }

    @Test func aSavedDaysRealSizeReplacesTheEstimate() {
        let result = plan([d4, d5], saved: [d4.day: 12_345_678])
        #expect(result.entries[0].estimatedBytes == 12_345_678)
        #expect(result.entries[1].estimatedBytes == 57_000_000)
    }

    @Test func aSavedDayLargerThanItsEstimateCanPushItselfOut() {
        let result = plan([d4], saved: [d4.day: 90_000_000], limit: 60_000_000)
        #expect(result.entries.map(\.fits) == [false])
    }

    // MARK: Per-frame estimate

    @Test func aFrameIsEstimatedAtThumbViewAndCrop() {
        #expect(OfflinePlanner.bytesPerFrame(includeCrops: true) == 570_000)
        #expect(OfflinePlanner.bytesPerFrame(includeCrops: false) == 350_000)
        let day = planDay("2026-10-05", frames: 480)
        #expect(plan([day], crops: true).entries[0].estimatedBytes == 480 * 570_000)
        #expect(plan([day], crops: false).entries[0].estimatedBytes == 480 * 350_000)
    }

    @Test func turningCropsOffLetsMoreDaysIn() {
        let days = [planDay("2026-10-05"), planDay("2026-10-04"), planDay("2026-10-03")]
        #expect(plan(days, limit: 120_000_000, crops: true).kept.count == 2)
        #expect(plan(days, limit: 120_000_000, crops: false).kept.count == 3)
    }

    @Test func gigabytesAreDecimal() {
        #expect(OfflinePlanner.bytes(gigabytes: 2) == 2_000_000_000)
        #expect(OfflinePlanner.bytes(gigabytes: 0.5) == 500_000_000)
        #expect(OfflinePlanner.bytes(gigabytes: 10) == 10_000_000_000)
    }

    @Test func noDaysIsAnEmptyPlan() {
        let result = plan([])
        #expect(result.entries.isEmpty && result.kept.isEmpty && result.plannedBytes == 0)
        #expect(result.entry(for: "x") == nil)
        #expect(plan([d4]).entry(for: d4.day)?.reason == .inProgress)
    }

    @Test func aPinThatIsNotThereMeansAuto() {
        #expect(plan([d4], pins: ["some/other-day": .never]).entries.count == 1)
        #expect(plan([d4], pins: [d4.day: .auto]).entries.count == 1)
    }
}

@Suite("Offline: words")
struct OfflineFormatTests {
    @Test func sizesAreDecimalWithAFractionOnlyForGigabytes() {
        #expect(OfflineFormat.size(0) == "0 MB")
        #expect(OfflineFormat.size(900) == "1 KB")
        #expect(OfflineFormat.size(320_000_000) == "320 MB")
        #expect(OfflineFormat.size(1_400_000_000) == "1.4 GB")
        #expect(OfflineFormat.size(2_000_000_000) == "2 GB")
        #expect(OfflineFormat.size(1_449_000_000) == "1.4 GB")
        #expect(OfflineFormat.size(1_451_000_000) == "1.5 GB")
    }

    @Test func theLimitReadsLikeTheSlider() {
        #expect(OfflineFormat.limit(gigabytes: 2) == "2 GB")
        #expect(OfflineFormat.limit(gigabytes: 2.5) == "2.5 GB")
        #expect(OfflineFormat.limit(gigabytes: 0.5) == "0.5 GB")
    }

    @Test func theStatusLines() {
        #expect(OfflineFormat.saved(days: 6, bytes: 1_400_000_000) == "6 days · 1.4 GB saved")
        #expect(OfflineFormat.saved(days: 1, bytes: 90_000_000) == "1 day · 90 MB saved")
        #expect(OfflineFormat.saved(days: 0, bytes: 0) == "No days saved yet")
        #expect(OfflineFormat.saving(title: "Tue, 29 Sep 2026", done: 120, total: 480)
            == "Saving Tue, 29 Sep 2026 · 120 of 480")
        #expect(OfflineFormat.saving(title: "Tue, 29 Sep 2026", done: 0, total: 0) == "Saving Tue, 29 Sep 2026…")
    }
}
