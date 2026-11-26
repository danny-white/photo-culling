import Foundation
import Testing
@testable import CullingBayCore

@Suite("Photo details: wording")
struct PhotoInfoFormatTests {
    let english = Locale(identifier: "en_US")

    private func info(_ json: String) throws -> PhotoInfo {
        try JSONDecoder().decode(PhotoInfo.self, from: Data(json.utf8))
    }

    // MARK: Shutter

    @Test func aFastShutterIsAFraction() {
        #expect(PhotoInfoFormat.shutter(0.0004) == "1/2500 s")
        #expect(PhotoInfoFormat.shutter(0.000625) == "1/1600 s")
        #expect(PhotoInfoFormat.shutter(0.05882352941) == "1/17 s")
        #expect(PhotoInfoFormat.shutter(1.0 / 8000) == "1/8000 s")
        #expect(PhotoInfoFormat.shutter(1.0 / 60) == "1/60 s")
        #expect(PhotoInfoFormat.shutter(0.008) == "1/125 s")
        #expect(PhotoInfoFormat.shutter(0.25) == "1/4 s")
        #expect(PhotoInfoFormat.shutter(0.5) == "1/2 s")
    }

    @Test func aShutterThatIsNotNearAWholeFractionIsADecimal() {
        #expect(PhotoInfoFormat.shutter(0.3) == "0.3 s")        // 1/3.3
        #expect(PhotoInfoFormat.shutter(0.4) == "0.4 s")        // 1/2.5
        #expect(PhotoInfoFormat.shutter(0.6) == "0.6 s")
        #expect(PhotoInfoFormat.shutter(0.8) == "0.8 s")
    }

    @Test func aFractionWithinFivePercentOfAWholeNumberIsRoundedToIt() {
        #expect(PhotoInfoFormat.shutter(1.0 / 99.7) == "1/100 s")
        #expect(PhotoInfoFormat.shutter(1.0 / 3.1) == "1/3 s")            // 3.1 is 3.3% from 3
        #expect(PhotoInfoFormat.shutter(1.0 / 3.2) == "0.3 s")            // 6.7% from 3
    }

    @Test func aTimeNearOneSecondIsNeverOneOverOne() {
        #expect(PhotoInfoFormat.shutter(0.96) == "1 s")
        #expect(PhotoInfoFormat.shutter(0.9) == "0.9 s")
        #expect(PhotoInfoFormat.shutter(0.7) == "0.7 s")
    }

    @Test func aLongShutterIsSecondsWithAtMostOneDecimal() {
        #expect(PhotoInfoFormat.shutter(1) == "1 s")
        #expect(PhotoInfoFormat.shutter(2.5) == "2.5 s")
        #expect(PhotoInfoFormat.shutter(30) == "30 s")
        #expect(PhotoInfoFormat.shutter(13.04) == "13 s")
        #expect(PhotoInfoFormat.shutter(120) == "120 s")
    }

    @Test func aShutterThatIsMissingOrNonsenseIsLeftOut() {
        #expect(PhotoInfoFormat.shutter(nil) == nil)
        #expect(PhotoInfoFormat.shutter(0) == nil)
        #expect(PhotoInfoFormat.shutter(-1) == nil)
        #expect(PhotoInfoFormat.shutter(.nan) == nil)
        #expect(PhotoInfoFormat.shutter(.infinity) == nil)
    }

    // MARK: Aperture, ISO

    @Test func apertureHasOneDecimalWithoutATrailingZero() {
        #expect(PhotoInfoFormat.aperture(4) == "f/4")
        #expect(PhotoInfoFormat.aperture(2.8) == "f/2.8")
        #expect(PhotoInfoFormat.aperture(1.779999971) == "f/1.8")
        #expect(PhotoInfoFormat.aperture(5.6) == "f/5.6")
        #expect(PhotoInfoFormat.aperture(22) == "f/22")
        #expect(PhotoInfoFormat.aperture(nil) == nil)
        #expect(PhotoInfoFormat.aperture(0) == nil)
    }

    @Test func isoIsGroupedFromTenThousandUp() {
        #expect(PhotoInfoFormat.iso(100, locale: english) == "ISO 100")
        #expect(PhotoInfoFormat.iso(1600, locale: english) == "ISO 1600")
        #expect(PhotoInfoFormat.iso(9999, locale: english) == "ISO 9999")
        #expect(PhotoInfoFormat.iso(10_000, locale: english) == "ISO 10,000")
        #expect(PhotoInfoFormat.iso(12_800, locale: english) == "ISO 12,800")
        #expect(PhotoInfoFormat.iso(102_400, locale: english) == "ISO 102,400")
        #expect(PhotoInfoFormat.iso(nil, locale: english) == nil)
        #expect(PhotoInfoFormat.iso(0, locale: english) == nil)
    }

    @Test func theISORowHasTheNumberAlone() {
        #expect(PhotoInfoFormat.isoNumber(800, locale: english) == "800")
        #expect(PhotoInfoFormat.isoNumber(12_800, locale: english) == "12,800")
        #expect(PhotoInfoFormat.isoNumber(nil, locale: english) == nil)
    }

    // MARK: Focal length

    @Test func focalLengthIsWholeMillimetresFromTenUp() {
        #expect(PhotoInfoFormat.focalLength(40.4) == "40 mm")
        #expect(PhotoInfoFormat.focalLength(40.4, equivalent: 40) == "40 mm")
        #expect(PhotoInfoFormat.focalLength(70) == "70 mm")
        #expect(PhotoInfoFormat.focalLength(9.96) == "10 mm")
        #expect(PhotoInfoFormat.focalLength(10) == "10 mm")
        #expect(PhotoInfoFormat.focalLength(200.4, equivalent: 200) == "200 mm")
    }

    @Test func focalLengthIsOneDecimalBelowTen() {
        #expect(PhotoInfoFormat.focalLength(6.764999866) == "6.8 mm")
        #expect(PhotoInfoFormat.focalLength(8) == "8 mm")
        #expect(PhotoInfoFormat.focalLength(2.2) == "2.2 mm")
    }

    @Test func theFullFrameViewIsAddedWhenItIsAMillimetreOrMoreAway() {
        #expect(PhotoInfoFormat.focalLength(6.764999866, equivalent: 24) == "6.8 mm (24 mm full-frame)")
        #expect(PhotoInfoFormat.focalLength(55, equivalent: 88) == "55 mm (88 mm full-frame)")
        #expect(PhotoInfoFormat.focalLength(40.4, equivalent: 41) == "40 mm (41 mm full-frame)")
        #expect(PhotoInfoFormat.focalLength(40.4, equivalent: 40.9) == "40 mm")
        #expect(PhotoInfoFormat.focalLength(55, equivalent: 55) == "55 mm")
        #expect(PhotoInfoFormat.focalLength(55, equivalent: nil) == "55 mm")
        #expect(PhotoInfoFormat.focalLength(55, equivalent: 0) == "55 mm")
    }

    @Test func aMissingFocalLengthIsLeftOutWhateverTheEquivalent() {
        #expect(PhotoInfoFormat.focalLength(nil, equivalent: 24) == nil)
        #expect(PhotoInfoFormat.focalLength(0) == nil)
    }

    // MARK: Exposure compensation

    @Test func exposureCompUsesARealMinusAndASignForPlus() {
        #expect(PhotoInfoFormat.exposureComp(-0.7) == "\u{2212}0.7 EV")
        #expect(PhotoInfoFormat.exposureComp(0.3) == "+0.3 EV")
        #expect(PhotoInfoFormat.exposureComp(0) == "0 EV")
        #expect(PhotoInfoFormat.exposureComp(1) == "+1 EV")
        #expect(PhotoInfoFormat.exposureComp(-2) == "\u{2212}2 EV")
        #expect(PhotoInfoFormat.exposureComp(-0.66666) == "\u{2212}0.7 EV")
        #expect(PhotoInfoFormat.exposureComp(0.33333) == "+0.3 EV")
    }

    @Test func exposureCompThatRoundsToZeroIsZeroWithNoSign() {
        #expect(PhotoInfoFormat.exposureComp(-0.01) == "0 EV")
        #expect(PhotoInfoFormat.exposureComp(0.04) == "0 EV")
        #expect(PhotoInfoFormat.exposureComp(-0.0) == "0 EV")
        #expect(PhotoInfoFormat.exposureComp(nil) == nil)
        #expect(PhotoInfoFormat.exposureComp(.nan) == nil)
    }

    // MARK: Size, resolution

    @Test func sizeIsDecimalUnitsLikeTheFilesApp() {
        #expect(PhotoInfoFormat.size(43_198_976) == "43.2 MB")
        #expect(PhotoInfoFormat.size(79_971_644) == "80 MB")
        #expect(PhotoInfoFormat.size(6_863_601) == "6.9 MB")
        #expect(PhotoInfoFormat.size(1_416_909) == "1.4 MB")
        #expect(PhotoInfoFormat.size(123_460_000) == "123.5 MB")
        #expect(PhotoInfoFormat.size(2_500_000_000) == "2.5 GB")
        #expect(PhotoInfoFormat.size(48_300) == "48.3 KB")
        #expect(PhotoInfoFormat.size(1000) == "1 KB")
        #expect(PhotoInfoFormat.size(512) == "512 bytes")
        #expect(PhotoInfoFormat.size(1) == "1 byte")
    }

    @Test func sizeMovesUpAUnitWhenRoundingReachesAThousand() {
        #expect(PhotoInfoFormat.size(999_940) == "999.9 KB")
        #expect(PhotoInfoFormat.size(999_960) == "1 MB")
        #expect(PhotoInfoFormat.size(999_960_000) == "1 GB")
    }

    @Test func aMissingSizeIsLeftOut() {
        #expect(PhotoInfoFormat.size(nil) == nil)
        #expect(PhotoInfoFormat.size(0) == nil)
        #expect(PhotoInfoFormat.size(-5) == nil)
    }

    @Test func resolutionIsPixelsAndMegapixels() {
        #expect(PhotoInfoFormat.resolution(width: 8000, height: 5320, megapixels: 42.56) == "8000 × 5320 · 42.6 MP")
        #expect(PhotoInfoFormat.resolution(width: 8064, height: 6048, megapixels: 48.771072) == "8064 × 6048 · 48.8 MP")
        #expect(PhotoInfoFormat.resolution(width: 4000, height: 6000, megapixels: 24) == "4000 × 6000 · 24 MP")
    }

    @Test func megapixelsAreWorkedOutWhenTheServerLeavesThemOut() {
        #expect(PhotoInfoFormat.resolution(width: 8000, height: 5320, megapixels: nil) == "8000 × 5320 · 42.6 MP")
        #expect(PhotoInfoFormat.resolution(width: 4032, height: 3024, megapixels: 0) == "4032 × 3024 · 12.2 MP")
    }

    @Test func resolutionLeavesOutWhatIsNotKnown() {
        #expect(PhotoInfoFormat.resolution(width: nil, height: nil, megapixels: 12.2) == "12.2 MP")
        #expect(PhotoInfoFormat.resolution(width: 4000, height: nil, megapixels: 12.2) == "12.2 MP")
        #expect(PhotoInfoFormat.resolution(width: 4000, height: nil, megapixels: nil) == nil)
        #expect(PhotoInfoFormat.resolution(width: nil, height: nil, megapixels: nil) == nil)
        #expect(PhotoInfoFormat.resolution(width: 0, height: 0, megapixels: nil) == nil)
    }

    // MARK: When it was taken

    @Test func takenIsTheCamerasTimeInTheAppsDateStyleWithSeconds() {
        let text = PhotoInfoFormat.taken("2026:09:29 15:35:35", offset: "-07:00", locale: english)
        #expect(normalizeSpaces(text ?? "") == "Tue, Sep 29 2026 · 3:35:35 PM UTC\u{2212}7")
    }

    @Test func takenIgnoresTheFractionAndAddsNoShiftWhateverThePhonesZone() {
        let withFraction = PhotoInfoFormat.taken("2026:02:07 18:59:18.174", offset: "-06:00", locale: english)
        #expect(normalizeSpaces(withFraction ?? "") == "Sat, Feb 7 2026 · 6:59:18 PM UTC\u{2212}6")
        let midnight = PhotoInfoFormat.taken("2024:04:02 00:00:00", locale: english)
        #expect(normalizeSpaces(midnight ?? "") == "Tue, Apr 2 2024 · 12:00:00 AM")
        let late = PhotoInfoFormat.taken("2024:04:02 23:59:59.99", locale: english)
        #expect(normalizeSpaces(late ?? "") == "Tue, Apr 2 2024 · 11:59:59 PM")
    }

    @Test func takenFollowsThePhonesClockStyle() {
        let british = PhotoInfoFormat.taken("2026:09:29 15:35:35", locale: Locale(identifier: "en_GB"))
        #expect((british ?? "").hasSuffix("15:35:35"))
    }

    @Test func takenWithoutAnOffsetHasNoZone() {
        for offset in [nil, "", "nonsense", "-7", "+25:00", "+05:75", "-07:0", "UTC"] as [String?] {
            let text = PhotoInfoFormat.taken("2026:09:29 15:35:35", offset: offset, locale: english)
            #expect(normalizeSpaces(text ?? "") == "Tue, Sep 29 2026 · 3:35:35 PM", "offset \(offset ?? "nil")")
        }
    }

    @Test func theZoneIsWrittenAsHoursAndMinutesOnlyWhenThereAreMinutes() {
        func zone(_ offset: String) -> String {
            let text = normalizeSpaces(PhotoInfoFormat.taken("2026:09:29 15:35:35", offset: offset, locale: english) ?? "")
            return String(text.split(separator: " ").last ?? "")
        }
        #expect(zone("-07:00") == "UTC\u{2212}7")
        #expect(zone("+05:30") == "UTC+5:30")
        #expect(zone("-09:30") == "UTC\u{2212}9:30")
        #expect(zone("+12:00") == "UTC+12")
        #expect(zone("+00:00") == "UTC")
        #expect(zone("Z") == "UTC")
    }

    @Test func aTimeThatCannotBeReadShowsNothingRatherThanTheRawText() {
        for text in [
            nil, "", "garbage", "0000:00:00 00:00:00", "2026:13:01 10:00:00", "2026:02:30 10:00:00",
            "2026:09:29", "2026:09:29 25:00:00", "2026:09:29 10:61:00", "2026:09:29 10:00:61",
            "2026:09:29 10:00", "2026-09-29 10:00:00", "2026:09:29T10:00:00", "2026:09:29 10:00:00.",
            "2026:09:29 10:00:00.x", "2026:09:29 10:00:00-07:00", "2026:09:29  10:00:00",
        ] as [String?] {
            #expect(PhotoInfoFormat.taken(text, offset: "-07:00", locale: english) == nil, "\(text ?? "nil")")
        }
    }

    // MARK: Coordinates

    @Test func coordinatesAreFiveDecimalsWithRealMinusSigns() {
        let mexico = PhotoInfo.Coordinates(latitude: 19.4286305555556, longitude: -99.1660472222222)
        #expect(PhotoInfoFormat.coordinates(mexico) == "19.42863, \u{2212}99.16605")
        let mammoth = PhotoInfo.Coordinates(latitude: 37.633027, longitude: -118.964577777778)
        #expect(PhotoInfoFormat.coordinates(mammoth) == "37.63303, \u{2212}118.96458")
        let sydney = PhotoInfo.Coordinates(latitude: -33.8688, longitude: 151.2093)
        #expect(PhotoInfoFormat.coordinates(sydney) == "\u{2212}33.86880, 151.20930")
        #expect(PhotoInfoFormat.coordinates(nil) == nil)
    }

    @Test func aPositionThatRoundsToZeroHasNoSign() {
        let origin = PhotoInfo.Coordinates(latitude: -0.000001, longitude: 0)
        #expect(PhotoInfoFormat.coordinates(origin) == "0.00000, 0.00000")
    }

    // MARK: The summary and the rows

    @Test func theSummaryLineIsShutterApertureISOAndFocalLength() throws {
        #expect(PhotoInfoFormat.summary(try info(infoSonyARWJSON), locale: english) == "1/2500 s · f/4 · ISO 100 · 40 mm")
        // The phone's full-frame note is in the rows, not the headline.
        #expect(PhotoInfoFormat.summary(try info(infoIPhoneDNGJSON), locale: english)
            == "1/17 s · f/1.8 · ISO 800 · 6.8 mm")
    }

    @Test func theSummaryLeavesOutWhatIsMissing() throws {
        #expect(PhotoInfoFormat.summary(try info(infoCanonCR2JSON), locale: english) == "1/1600 s")
        #expect(PhotoInfoFormat.summary(PhotoInfo(id: 1, file: "A.JPG", iso: 12_800, focalMM: 35), locale: english)
            == "ISO 12,800 · 35 mm")
        #expect(PhotoInfoFormat.summary(PhotoInfo(id: 1, file: "A.JPG"), locale: english) == nil)
    }

    @Test func theSheetHasSectionsInOrderWithRowsInOrder() throws {
        let sections = PhotoInfoFormat.sections(try info(infoSonyARWJSON), locale: english)
        #expect(sections.map(\.title) == ["Exposure", "Camera", "File", "Taken"])    // no position: no Place
        #expect(sections[0].rows.map(\.label) == [
            "Shutter", "Aperture", "ISO", "Exposure comp.", "Focal length", "Mode", "Metering", "Flash",
            "White balance", "Focus",
        ])
        #expect(sections[0].rows.map(\.value) == [
            "1/2500 s", "f/4", "100", "\u{2212}0.7 EV", "40 mm", "Aperture-priority AE", "Multi-segment",
            "Off, Did not fire", "Auto", "AF-C",
        ])
        #expect(sections[1].rows == [
            PhotoInfoRow("Camera", "Sony ILCE-7RM3"), PhotoInfoRow("Lens", "24-70mm F2.8 DG DN | Art 019"),
        ])
        #expect(sections[2].rows == [
            PhotoInfoRow("Name", "DSC04912.ARW"), PhotoInfoRow("Format", "ARW"), PhotoInfoRow("Size", "43.2 MB"),
            PhotoInfoRow("Resolution", "8000 × 5320 · 42.6 MP"),
        ])
        #expect(sections[3].rows.map(\.label) == ["Date"])
        #expect(normalizeSpaces(sections[3].rows[0].value) == "Tue, Sep 29 2026 · 3:35:35 PM UTC\u{2212}7")
    }

    @Test func thePlaceSectionHasThePlaceAndTheCoordinates() throws {
        let sections = PhotoInfoFormat.sections(try info(infoIPhoneDNGJSON), locale: english)
        let place = try #require(sections.last)
        #expect(place.title == "Place")
        #expect(place.rows == [
            PhotoInfoRow("Place", "Cuauhtémoc, Mexico City, Mexico"),
            PhotoInfoRow("Coordinates", "19.42863, \u{2212}99.16605"),
        ])
        // The phone's lens reads 6.8 mm here but 24 mm to a full-frame camera; the Focus row is missing.
        let exposure = try #require(sections.first)
        #expect(exposure.rows.first { $0.label == "Focal length" }?.value == "6.8 mm (24 mm full-frame)")
        #expect(exposure.rows.contains { $0.label == "Focus" } == false)
        #expect(exposure.rows.first { $0.label == "Exposure comp." }?.value == "0 EV")
    }

    @Test func aRowWithNoValueIsLeftOutAndSoIsASectionWithNoRows() throws {
        let sections = PhotoInfoFormat.sections(try info(infoCanonCR2JSON), locale: english)
        #expect(sections.map(\.title) == ["Exposure", "Camera", "File", "Taken"])
        #expect(sections[0].rows == [PhotoInfoRow("Shutter", "1/1600 s")])
        #expect(sections[2].rows == [PhotoInfoRow("Name", "IMG_9154.CR2"), PhotoInfoRow("Format", "CR2")])
        #expect(normalizeSpaces(sections[3].rows[0].value) == "Tue, Apr 2 2024 · 3:51:04 AM")    // no zone: no offset

        let bare = PhotoInfoFormat.sections(PhotoInfo(id: 1, file: "A.JPG"), locale: english)
        #expect(bare.map(\.title) == ["File"])
        #expect(bare[0].rows == [PhotoInfoRow("Name", "A.JPG")])
    }

    @Test func textThatIsBlankIsTakenForMissing() {
        let blank = PhotoInfo(id: 1, file: "A.JPG", camera: "  ", lens: "", program: "\n", place: " ")
        #expect(PhotoInfoFormat.sections(blank, locale: english).map(\.title) == ["File"])
    }

    @Test func aRowIsToldApartByItsLabel() {
        #expect(PhotoInfoRow("ISO", "100").id == "ISO")
        #expect(PhotoInfoSection("Place", []).id == "Place")
    }

    // MARK: When the details cannot be had

    @Test func theFailureWordsSayWhatToDo() {
        let unreachable = "Camera details come from the PC, and it can’t be reached right now. Try again when it’s back."
        #expect(PhotoInfoFormat.failure(CullingBayError.unavailable(message: "photo storage unavailable")) == unreachable)
        #expect(PhotoInfoFormat.failure(CullingBayError.transport("The request timed out.")) == unreachable)
        #expect(PhotoInfoFormat.failure(CullingBayError.http(status: 404, message: "not found"))
            == "This photo isn’t in the library index any more.")
        #expect(PhotoInfoFormat.failure(CullingBayError.http(status: 415, message: "could not read this file's details: x"))
            == "This file’s details can’t be read.")
        // The link's own failures: the PC out of reach reads as above; Work offline says how to get them.
        #expect(PhotoInfoFormat.failure(CullingBayError.transport(ServerLink.unreachableMessage)) == unreachable)
        #expect(PhotoInfoFormat.failure(CullingBayError.transport(ServerLink.forcedMessage))
            == "Camera details come from the PC. Turn off Work offline to see them.")
    }

    @Test func anyOtherFailureIsNamedAndNeverBlank() {
        #expect(PhotoInfoFormat.failure(CullingBayError.http(status: 500, message: nil))
            == "Couldn’t load the camera details: HTTP 500")
        #expect(PhotoInfoFormat.failure(CullingBayError.http(status: 500, message: "boom"))
            == "Couldn’t load the camera details: boom")
        #expect(PhotoInfoFormat.failure(CullingBayError.decoding("Missing key id"))
            == "Couldn’t load the camera details: Missing key id")
        #expect(PhotoInfoFormat.failure(CullingBayError.conflict(message: nil, applied: nil))
            == "Couldn’t load the camera details: the server refused")
        #expect(PhotoInfoFormat.failure(TestFailure()).hasPrefix("Couldn’t load the camera details: "))
    }
}
