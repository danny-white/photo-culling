import Foundation
import Testing
@testable import CullingBayCore

@Suite("Gallery formatting")
struct GalleryFormatTests {
    let english = Locale(identifier: "en_US")
    let pacific = TimeZone(identifier: "America/Los_Angeles")!

    @Test func longDateHasWeekdayMonthDayYear() {
        #expect(GalleryFormat.longDate("2026-10-17") == "Sat, Oct 17 2026")
        #expect(GalleryFormat.longDate("2026-10-01") == "Thu, Oct 1 2026")
        #expect(GalleryFormat.longDate("2024-02-29") == "Thu, Feb 29 2024")
        #expect(GalleryFormat.longDate("2000-01-01") == "Sat, Jan 1 2000")
        #expect(GalleryFormat.longDate("2027-01-01") == "Fri, Jan 1 2027")
    }

    @Test func longDateOfNilIsUndatedAndOfJunkIsTheJunk() {
        #expect(GalleryFormat.longDate(nil) == "Undated")
        #expect(GalleryFormat.longDate("unsorted") == "unsorted")
        #expect(GalleryFormat.longDate("2026-13-01") == "2026-13-01")
    }

    @Test func shortDateHasATwoDigitYear() {
        #expect(GalleryFormat.shortDate("2026-10-17") == "Oct 17 ’26")
        #expect(GalleryFormat.shortDate("2005-03-04") == "Mar 4 ’05")
        #expect(GalleryFormat.shortDate(nil) == "")
        #expect(GalleryFormat.shortDate("nope") == "")
    }

    @Test func timeIsShownInTheGivenZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        let when = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 17, hour: 15, minute: 41)))
        let text = GalleryFormat.time(when.timeIntervalSince1970, timeZone: pacific, locale: english)
        #expect(normalizeSpaces(text) == "3:41 PM")
        let utc = GalleryFormat.time(
            when.timeIntervalSince1970, timeZone: TimeZone(identifier: "UTC")!, locale: english)
        #expect(normalizeSpaces(utc) == "10:41 PM")
    }

    @Test func timeIsEmptyWithoutATimestamp() {
        #expect(GalleryFormat.time(nil, timeZone: pacific, locale: english) == "")
        #expect(GalleryFormat.time(0, timeZone: pacific, locale: english) == "")
    }

    @Test func megabytesRoundsFromTenUp() {
        #expect(GalleryFormat.megabytes(12_400_000) == "12 MB")
        #expect(GalleryFormat.megabytes(43_100_672) == "43 MB")
        #expect(GalleryFormat.megabytes(3_400_000) == "3.4 MB")
        #expect(GalleryFormat.megabytes(9_960_000) == "10.0 MB")
        #expect(GalleryFormat.megabytes(0) == "")
        #expect(GalleryFormat.megabytes(nil) == "")
    }

    @Test func photoCountPluralisesAndGroupsThousands() {
        #expect(GalleryFormat.photoCount(1, locale: english) == "1 photo")
        #expect(GalleryFormat.photoCount(0, locale: english) == "0 photos")
        #expect(GalleryFormat.photoCount(1234, locale: english) == "1,234 photos")
        #expect(GalleryFormat.dayCount(1) == "1 day")
        #expect(GalleryFormat.dayCount(12) == "12 days")
    }

    @Test func starsAreCappedAtFive() {
        #expect(GalleryFormat.stars(3) == "★★★")
        #expect(GalleryFormat.stars(0) == "")
        #expect(GalleryFormat.stars(9) == "★★★★★")
        #expect(GalleryFormat.stars(-1) == "")
    }
}

/// Recent ICU writes a narrow no-break space before AM/PM; older versions a plain space.
func normalizeSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}
