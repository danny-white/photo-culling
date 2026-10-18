import Foundation
import Testing
@testable import CullingBayCore

@Suite("Library index")
struct LibraryIndexTests {
    private func days() -> [Day] {
        [
            libraryDay("2026-10-17", frames: 100, place: "seattle, washington, us", thumbs: [1, 2, 3]),
            libraryDay("2026-10-16", frames: 50, place: "greenwood, washington, us", thumbs: [4, 5]),
            libraryDay("2026-10-01", frames: 20, place: "greenwood, washington, us", thumbs: [6]),
            libraryDay("2026-08-09", frames: 30, place: "seattle, washington, us", thumbs: [7, 8, 9]),
            libraryDay("2025-12-31", frames: 5, thumbs: []),
            libraryDay(nil, frames: 3, thumbs: [10]),
            libraryDay(nil, frames: 4, thumbs: [11, 12]),
        ]
    }

    @Test func groupsIntoYearsAndMonthsInListOrder() {
        let index = LibraryIndex(days: days())
        #expect(index.years.map(\.year) == ["2026", "2025", "Undated"])
        #expect(index.years[0].months.map(\.key) == ["2026-10", "2026-08"])
        #expect(index.years[0].months[0].days.count == 3)
        #expect(index.years[1].months.map(\.key) == ["2025-12"])
        #expect(index.dayCount == 7)
    }

    @Test func undatedDaysGoUnderUndatedAndAreCalledOtherFolders() throws {
        let index = LibraryIndex(days: days())
        let undated = try #require(index.years.last)
        #expect(undated.year == "Undated")
        #expect(undated.months.map(\.key) == ["Undated"])
        #expect(undated.months[0].name == "Other folders")
        #expect(undated.months[0].days.count == 2)
        #expect(index.years[0].months[0].name == "October")
        #expect(index.years[0].months[1].name == "August")
    }

    @Test func aNonConsecutiveRepeatMakesANewGroupLikeTheWebPage() {
        let index = LibraryIndex(days: [
            libraryDay("2026-10-17"), libraryDay(nil), libraryDay("2026-10-01"),
        ])
        #expect(index.years.map(\.year) == ["2026", "Undated", "2026"])
    }

    @Test func countsPhotosByFramesAndFindsTheTopTown() {
        let index = LibraryIndex(days: days())
        let year = index.years[0]
        #expect(year.photoCount == 200)
        // greenwood has 70 frames, seattle 130
        #expect(year.topTown == "Seattle")
        let october = year.months[0]
        #expect(october.photoCount == 170)
        #expect(october.topTown == "Seattle")
        #expect(october.subtitle == "3 days · 170 photos · Seattle")
        #expect(index.years[1].topTown == nil)
        #expect(index.years[1].subtitle == "1 day · 5 photos")
    }

    @Test func aTopTownTieGoesToTheFirstSeen() {
        let index = LibraryIndex(days: [
            libraryDay("2026-10-17", frames: 10, place: "tacoma, washington, us"),
            libraryDay("2026-10-16", frames: 10, place: "seattle, washington, us"),
        ])
        #expect(index.years[0].topTown == "Tacoma")
    }

    @Test func aMonthStripTakesOneThumbPerDayWhenThereAreThreeDays() {
        let october = LibraryIndex(days: days()).years[0].months[0]
        #expect(october.strip == [1, 4, 6])
    }

    @Test func aMonthStripTakesThreeThumbsPerDayWhenThereAreTwoOrFewer() {
        let august = LibraryIndex(days: days()).years[0].months[1]
        #expect(august.strip == [7, 8, 9])
        let two = LibraryIndex(days: [
            libraryDay("2026-10-17", thumbs: [1, 2, 3]), libraryDay("2026-10-16", thumbs: [4, 5, 6]),
        ]).years[0].months[0]
        #expect(two.strip == [1, 2, 3, 4, 5, 6])
    }

    @Test func aMonthStripHoldsAtMostSix() {
        let many = (1...9).map { libraryDay("2026-10-\(String(format: "%02d", $0))", thumbs: [$0, $0 + 100]) }
        let strip = LibraryIndex(days: many).years[0].months[0].strip
        #expect(strip == [1, 2, 3, 4, 5, 6])
        let two = [libraryDay("2026-10-02", thumbs: [1, 2, 3]), libraryDay("2026-10-01", thumbs: [4, 5, 6])]
        #expect(LibraryIndex(days: two).years[0].months[0].strip.count == 6)
    }

    @Test func aDayRowSubtitleJoinsTownCountAndSummary() {
        let day = libraryDay("2026-10-17", frames: 1, place: "greenwood, washington, us", summary: "Dune walk")
        #expect(day.rowSubtitle.replacingOccurrences(of: "\u{202F}", with: " ") == "Greenwood · 1 photo · Dune walk")
        #expect(libraryDay("2026-10-17", frames: 0).rowSubtitle == "0 photos")
    }

    // MARK: On this day

    private func today(_ year: Int, _ month: Int, _ day: Int, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private let pacific = TimeZone(identifier: "America/Los_Angeles")!

    @Test func onThisDayFindsEarlierYearsWithinTwoDays() {
        let index = LibraryIndex(days: [
            libraryDay("2026-10-17", thumbs: [1]),                          // this year
            libraryDay("2025-10-19", place: "seattle, washington, us", thumbs: [2]),
            libraryDay("2024-10-15", thumbs: [3]),
            libraryDay("2023-10-14", thumbs: [4]),                          // three days off
            libraryDay("2022-10-20", thumbs: [5]),                          // three days off
            libraryDay("2021-10-17", thumbs: []),                           // nothing to show
            libraryDay(nil, thumbs: [6]),
        ])
        let found = index.onThisDay(today: today(2026, 10, 17, in: pacific), timeZone: pacific)
        #expect(found.map(\.thumb) == [2, 3])
        #expect(found.map(\.year) == [2025, 2024])
        #expect(found.map(\.label) == ["2025 · Seattle", "2024"])
    }

    @Test func onThisDayWrapsTheNewYear() {
        let index = LibraryIndex(days: [
            libraryDay("2026-12-31", thumbs: [1]),
            libraryDay("2026-01-02", thumbs: [2]),
            libraryDay("2025-12-30", thumbs: [3]),
            libraryDay("2025-06-15", thumbs: [4]),
        ])
        let newYearsDay = index.onThisDay(today: today(2027, 1, 1, in: pacific), timeZone: pacific)
        #expect(newYearsDay.map(\.thumb) == [1, 2, 3])
        let newYearsEve = index.onThisDay(today: today(2026, 12, 31, in: pacific), timeZone: pacific)
        // this year's days don't count, and 30 December 2025 is one day off
        #expect(newYearsEve.map(\.thumb) == [3])
    }

    @Test func onThisDayHandlesTheLeapDay() {
        let index = LibraryIndex(days: [libraryDay("2024-02-29", thumbs: [1]), libraryDay("2024-03-02", thumbs: [2])])
        let found = index.onThisDay(today: today(2026, 3, 1, in: pacific), timeZone: pacific)
        #expect(found.map(\.thumb) == [1, 2])
    }

    @Test func onThisDayUsesTheGivenZoneForToday() {
        // 2026-10-18 03:00 UTC is still the 17th in Los Angeles
        let instant = Date(timeIntervalSince1970: 1_792_292_400)
        let index = LibraryIndex(days: [libraryDay("2025-10-15", thumbs: [1])])
        #expect(index.onThisDay(today: instant, timeZone: pacific).count == 1)
        #expect(index.onThisDay(today: instant, timeZone: TimeZone(identifier: "UTC")!).count == 0)
    }
}
