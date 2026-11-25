import Foundation
import Testing
@testable import CullingBayCore

/// The `lightroom` object on a challenge, and the words the "Already in Lightroom" card is built from.
@Suite("Practice: already in Lightroom on the phone")
struct PracticeLightroomTests {
    /// The example in `review/API.md`.
    private let sampleLightroom = """
    {"albums":["Sun Peaks","3+","Edited","Picked"],"find_in":"Sun Peaks",
     "captured":"2025-01-18T13:13:02","edited":true,"checked":"2026-11-25"}
    """

    private func decode(_ json: String) throws -> PracticeChallenge {
        try JSONDecoder().decode(PracticeChallenge.self, from: Data(json.utf8))
    }

    private func photo(file: String = "DSC03308.ARW", date: String? = "2025-01-18", raw: Bool = true) -> Photo {
        galleryPhoto(7, date: date, file: file, raw: raw)
    }

    private func challenge(
        _ lightroom: PracticeLightroom?, photo: Photo? = nil, needsDesktop: Bool = false
    ) -> PracticeChallenge {
        PracticeChallenge(
            id: "a", title: "A", photo: photo ?? self.photo(), needsDesktop: needsDesktop, lightroom: lightroom)
    }

    private func guide(for challenge: PracticeChallenge) throws -> PracticeLightroomGuide {
        guard case .inLightroom(let guide) = PracticeLightroomGuide.plan(for: challenge) else {
            throw GuideTestError.notInLightroom
        }
        return guide
    }

    private enum GuideTestError: Error { case notInLightroom }

    // MARK: Decoding

    @Test func decodesTheLightroomObject() throws {
        let c = try decode(practiceJSON("snow", lightroom: sampleLightroom))
        let lr = try #require(c.lightroom)
        #expect(lr.albums == ["Sun Peaks", "3+", "Edited", "Picked"])
        #expect(lr.findIn == "Sun Peaks")
        #expect(lr.captured == "2025-01-18T13:13:02")
        #expect(lr.edited)
        #expect(lr.checked == "2026-11-25")
    }

    @Test func aPhotoNotOnThePhoneHasNoAlbumsAndNoFindIn() throws {
        let c = try decode(practiceJSON(
            "stacks",
            lightroom: #"{"albums":[],"find_in":null,"captured":"2026-10-01T09:25:24","edited":false,"checked":"2026-11-25"}"#))
        let lr = try #require(c.lightroom)
        #expect(lr.albums.isEmpty && lr.findIn == nil && !lr.edited)
    }

    @Test func noLightroomKeyMeansNobodyChecked() throws {
        #expect(try decode(practiceSampleJSON).lightroom == nil)
        #expect(try decode(practiceJSON("a")).lightroom == nil)
        #expect(try decode(practiceJSON("a", lightroom: "null")).lightroom == nil)
    }

    @Test func anUnknownKeyInsideItIsIgnored() throws {
        let c = try decode(practiceJSON(
            "a", lightroom: #"{"albums":["Picked"],"find_in":"Picked","rating":3,"collections":{"x":1},"edited":true}"#))
        #expect(c.lightroom?.albums == ["Picked"] && c.lightroom?.edited == true)
    }

    @Test func onlyTheAlbumsHaveToBeThere() throws {
        let c = try decode(practiceJSON("a", lightroom: #"{"albums":["Picked"]}"#))
        let lr = try #require(c.lightroom)
        #expect(lr.findIn == nil && lr.captured == nil && !lr.edited && lr.checked == nil)
    }

    @Test func aLightroomObjectTheAppCannotReadIsNoCheckAndDoesNotFailTheList() throws {
        // Without the albums the app cannot say whether the photo is on the phone; a wrong type is no
        // better. Either way the challenge decodes with no check, and so does everything after it.
        for bad in [#"{"find_in":"Picked","edited":true}"#, #"{"albums":"Picked"}"#, #"{"albums":[1,2]}"#,
                    #"[]"#, #""Picked""#, "7"] {
            let json = practiceListJSON([
                practiceJSON("a", lightroom: bad), practiceJSON("b", lightroom: sampleLightroom),
            ])
            let list = try JSONDecoder().decode(PracticeList.self, from: Data(json.utf8))
            #expect(list.challenges.map(\.id) == ["a", "b"], "\(bad)")
            #expect(list.challenges[0].lightroom == nil, "\(bad)")
            #expect(list.challenges[1].lightroom?.albums.count == 4, "\(bad)")
            #expect(PracticeLightroomGuide.plan(for: list.challenges[0]) == .download, "\(bad)")
        }
    }

    // MARK: Wording

    @Test func theAlbumListReadsAsASentence() {
        #expect(PracticeLightroomGuide.albumList([]) == "")
        #expect(PracticeLightroomGuide.albumList(["Picked"]) == "Picked")
        #expect(PracticeLightroomGuide.albumList(["Edited", "Picked"]) == "Edited and Picked")
        #expect(PracticeLightroomGuide.albumList(["Crystal Jan 25", "3+", "Edited"]) == "Crystal Jan 25, 3+ and Edited")
        #expect(PracticeLightroomGuide.albumList(["Sun Peaks", "3+", "Edited", "Picked"])
            == "Sun Peaks, 3+, Edited and Picked")
    }

    @Test func theDateIsLightroomsOwnDayWithNoZoneShift() {
        #expect(PracticeLightroomGuide.longDay("2025-01-18T13:13:02") == "Sat, Jan 18 2025")
        // The Japan photos: Lightroom says Oct 4, Culling Bay filed the photo under Oct 3.
        #expect(PracticeLightroomGuide.longDay("2025-10-04T11:51:59") == "Sat, Oct 4 2025")
        // A time that a zone shift would move to the next or the last day stays where it is.
        #expect(PracticeLightroomGuide.longDay("2024-05-10T23:14:50") == "Fri, May 10 2024")
        #expect(PracticeLightroomGuide.longDay("2025-01-01T00:00:01") == "Wed, Jan 1 2025")
        #expect(PracticeLightroomGuide.longDay("2025-01-18") == "Sat, Jan 18 2025")
        #expect(PracticeLightroomGuide.longDay("2025-01-18 13:13:02") == "Sat, Jan 18 2025")
        #expect(PracticeLightroomGuide.longDay("2026-11-25") == "Wed, Nov 25 2026")
    }

    @Test func aDateThatIsMissingOrUnreadableIsNil() {
        #expect(PracticeLightroomGuide.longDay(nil) == nil)
        #expect(PracticeLightroomGuide.longDay("") == nil)
        #expect(PracticeLightroomGuide.longDay("yesterday") == nil)
        #expect(PracticeLightroomGuide.longDay("2025-13-40T00:00:00") == nil)
        #expect(PracticeLightroomGuide.longDay("2025-02-30") == nil)
        #expect(PracticeLightroomGuide.longDay("18/01/2025") == nil)
    }

    @Test func theFileNameComesFromTheChallengesPhoto() {
        #expect(PracticeLightroomGuide.fileName(photo(file: "DSC03308.ARW")) == "DSC03308")
        #expect(PracticeLightroomGuide.fileName(photo(file: "IMG_0001.JPG")) == "IMG_0001")
        #expect(PracticeLightroomGuide.fileName(photo(file: "NoExtension")) == "NoExtension")
    }

    @Test func thePhotoLabelUsesLightroomsDayNotTheLibrarysDate() {
        let torii = photo(file: "DSC09001.ARW", date: "2025-10-03")
        #expect(PracticeLightroomGuide.photoLabel(captured: "2025-10-04T11:51:59", photo: torii)
            == "Sat, Oct 4 2025 · DSC09001")
        // No date from Lightroom: the file name alone, not a date that may be a day off.
        #expect(PracticeLightroomGuide.photoLabel(captured: nil, photo: torii) == "DSC09001")
        #expect(PracticeLightroomGuide.photoLabel(captured: "soon", photo: torii) == "DSC09001")
    }

    @Test func theEditedWarningFollowsTheEditedFlag() {
        #expect(PracticeLightroomGuide.showsEditedWarning(PracticeLightroom(albums: ["A"], edited: true)))
        #expect(!PracticeLightroomGuide.showsEditedWarning(PracticeLightroom(albums: ["A"], edited: false)))
    }

    @Test func theCheckedFootnoteReadsLikeTheAppsOtherDates() {
        #expect(PracticeLightroomGuide.footnote(checked: "2026-11-25")
            == "Checked against Lightroom Classic on Wed, Nov 25 2026.")
        #expect(PracticeLightroomGuide.footnote(checked: nil) == nil)
        #expect(PracticeLightroomGuide.footnote(checked: "") == nil)
        #expect(PracticeLightroomGuide.footnote(checked: "later") == nil)
    }

    // MARK: The plan

    @Test func noCheckMeansTheDownloadBlockAsBefore() {
        #expect(PracticeLightroomGuide.plan(for: challenge(nil)) == .download)
    }

    @Test func aPhotoNotOnThePhoneKeepsTheDownloadsUnderOneLine() {
        let plan = PracticeLightroomGuide.plan(for: challenge(PracticeLightroom(albums: [], checked: "2026-11-25")))
        #expect(plan == .downloadWithNote(
            "This photo isn't in any of your synced Lightroom albums, so download the RAW to edit it on the phone."))
        let jpeg = challenge(PracticeLightroom(albums: []), photo: photo(file: "B.JPG", raw: false))
        #expect(PracticeLightroomGuide.plan(for: jpeg) == .downloadWithNote(
            "This photo isn't in any of your synced Lightroom albums, so download the original to edit it on the phone."))
    }

    @Test func aNeedsDesktopChallengeGetsNeitherTheCardNorTheLine() {
        let onPhone = PracticeLightroom(albums: ["Aurora", "Edited"], findIn: "Aurora", edited: true)
        #expect(PracticeLightroomGuide.plan(for: challenge(onPhone, needsDesktop: true)) == .download)
        let notOnPhone = PracticeLightroom(albums: [])
        #expect(PracticeLightroomGuide.plan(for: challenge(notOnPhone, needsDesktop: true)) == .download)
        // Its on-the-go version, the same photo, does get the card.
        if case .inLightroom = PracticeLightroomGuide.plan(for: challenge(onPhone)) {} else {
            Issue.record("the companion should get the card")
        }
    }

    @Test func albumNamesThatAreBlankDoNotCountAsAlbums() {
        let lr = PracticeLightroom(albums: ["", "  "])
        #expect(PracticeLightroomGuide.plan(for: challenge(lr)) == .downloadWithNote(
            PracticeLightroomGuide.notOnPhoneLine(photo())))
    }

    // MARK: The card

    @Test func theCardForASyncedAndEditedPhotoReadsAsBriefed() throws {
        let lr = try #require(try decode(practiceJSON("snow", lightroom: sampleLightroom)).lightroom)
        let card = try guide(for: challenge(lr))
        #expect(PracticeLightroomGuide.title == "Already in Lightroom on your phone")
        #expect(card.body == "It's in your synced albums Sun Peaks, 3+, Edited and Picked, so you can edit it there "
            + "without downloading anything. Edits you make on the phone go straight to the original in Lightroom Classic.")
        #expect(card.steps.map(\.text) == [
            "1. Open Lightroom.",
            "2. Go to Albums and open Sun Peaks.",
            "3. Find Sat, Jan 18 2025 · DSC03308, the photo at the top of this page. In a big album, sort by capture date.",
            "4. Edit with only the tools above, then come back and mark it done.",
        ])
        #expect(card.warning == "This photo already has edits. Anything you change on the phone changes it in Lightroom Classic too.")
        #expect(card.spokenWarning == "Warning. This photo already has edits. Anything you change on the phone changes it in Lightroom Classic too.")
        #expect(card.footnote == "Checked against Lightroom Classic on Wed, Nov 25 2026.")
        #expect(card.downloadTitle == "Download the RAW instead")
    }

    @Test func theAlbumAndThePhotoAreTheBoldParts() throws {
        let card = try guide(for: challenge(PracticeLightroom(
            albums: ["Sun Peaks", "Edited"], findIn: "Sun Peaks", captured: "2025-01-18T13:13:02")))
        #expect(card.steps.map { $0.pieces.filter(\.bold).map(\.text) }
            == [[], ["Sun Peaks"], ["Sat, Jan 18 2025 · DSC03308"], []])
        #expect(card.steps.map(\.number) == [1, 2, 3, 4])
    }

    @Test func aPhotoThatIsNotEditedHasNoWarning() throws {
        let card = try guide(for: challenge(PracticeLightroom(
            albums: ["Picked"], findIn: "Picked", captured: "2024-05-04T13:52:18", edited: false, checked: "2026-11-25")))
        #expect(card.warning == nil && card.spokenWarning == nil)
        #expect(card.footnote != nil)
    }

    @Test func oneAlbumNeedsNoAndAndSaysAlbum() throws {
        let card = try guide(for: challenge(PracticeLightroom(albums: ["Picked"], findIn: "Picked")))
        #expect(card.body.hasPrefix("It's in your synced album Picked, so you can edit it there"))
        let two = try guide(for: challenge(PracticeLightroom(albums: ["Edited", "Picked"], findIn: "Edited")))
        #expect(two.body.hasPrefix("It's in your synced albums Edited and Picked, so"))
    }

    @Test func theAlbumToOpenIsFindInOrElseTheFirst() throws {
        let named = try guide(for: challenge(PracticeLightroom(albums: ["Sun Peaks", "Edited"], findIn: "Edited")))
        #expect(named.steps[1].text == "2. Go to Albums and open Edited.")
        for missing in [nil, "", "  "] {
            let card = try guide(for: challenge(PracticeLightroom(albums: ["Sun Peaks", "Edited"], findIn: missing)))
            #expect(card.steps[1].text == "2. Go to Albums and open Sun Peaks.")
        }
    }

    @Test func withoutACaptureTimeTheStepNamesTheFileOnly() throws {
        let card = try guide(for: challenge(PracticeLightroom(albums: ["Picked"], captured: nil)))
        #expect(card.steps[2].text
            == "3. Find DSC03308, the photo at the top of this page. In a big album, sort by capture date.")
    }

    @Test func withoutACheckedDateThereIsNoFootnote() throws {
        let card = try guide(for: challenge(PracticeLightroom(albums: ["Picked"], checked: nil)))
        #expect(card.footnote == nil)
    }

    @Test func aPhotoThatIsNotARawSaysOriginal() throws {
        let card = try guide(for: challenge(
            PracticeLightroom(albums: ["Picked"]), photo: photo(file: "B.JPG", raw: false)))
        #expect(card.downloadTitle == "Download the original instead")
    }

    @Test func theJapanPhotoSaysOctober4WhenTheLibraryFiledItUnderOctober3() throws {
        let json = practiceJSON(
            "torii-2025-10-03",
            photo: #"{"id":9,"day":"2025/2025-10-03","date":"2025-10-03","file":"DSC09001.ARW","stars":0,"picked":false,"rejected":false,"raw":true}"#,
            lightroom: #"{"albums":["Edited","Picked"],"find_in":"Edited","captured":"2025-10-04T11:51:59","edited":true,"checked":"2026-11-25"}"#)
        let card = try guide(for: try decode(json))
        #expect(card.steps[2].text.hasPrefix("3. Find Sat, Oct 4 2025 · DSC09001,"))
    }
}
