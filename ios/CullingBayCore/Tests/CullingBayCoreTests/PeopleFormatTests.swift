import Foundation
import Testing
@testable import CullingBayCore

@Suite("People format")
struct PeopleFormatTests {
    private let us = Locale(identifier: "en_US")

    @Test func aNameIsTrimmedAndOneToEightyCharacters() {
        #expect(PeopleFormat.cleanName("  Alex \n") == "Alex")
        #expect(PeopleFormat.cleanName("A") == "A")
        #expect(PeopleFormat.cleanName("") == nil)
        #expect(PeopleFormat.cleanName("   ") == nil)
        #expect(PeopleFormat.cleanName(String(repeating: "x", count: 80)) != nil)
        #expect(PeopleFormat.cleanName(String(repeating: "x", count: 81)) == nil)
        #expect(PeopleFormat.cleanName("  " + String(repeating: "x", count: 80) + "  ") != nil)
    }

    @Test func aGroupIsCaptionedWithPhotosAndDays() {
        #expect(PeopleFormat.groupCaption(makeGroup(1, photos: 37, days: 5), locale: us) == "37 photos · 5 days")
        #expect(PeopleFormat.groupCaption(makeGroup(1, photos: 1, days: 1), locale: us) == "1 photo · 1 day")
        #expect(PeopleFormat.groupCaption(makeGroup(1, photos: 1039, days: 61), locale: us) == "1,039 photos · 61 days")
    }

    @Test func aGroupThatLooksLikeSomeoneIsLabelledWithAQuestionMark() {
        let maybe = makeGroup(1, photos: 10, days: 2, maybe: PersonRef(id: 2, name: "Alex"))
        #expect(PeopleFormat.groupLabel(maybe, locale: us) == "Alex?")
        #expect(PeopleFormat.groupLabel(makeGroup(2, photos: 10, days: 2), locale: us) == "10 photos · 2 days")
    }

    @Test func theProgressLineGroupsDigitsAndStopsWhenDone() {
        #expect(PeopleFormat.progress(checked: 8609, of: 43195, locale: us) == "Finding faces… 8,609 of 43,195 photos")
        #expect(PeopleFormat.progress(checked: 0, of: 12, locale: us) == "Finding faces… 0 of 12 photos")
        #expect(PeopleFormat.progress(checked: 12, of: 12, locale: us) == nil)
        #expect(PeopleFormat.progress(checked: 0, of: 0, locale: us) == nil)
    }

    @Test func theReviewTitleIsSingularForOne() {
        #expect(PeopleFormat.reviewTitle(1) == "Review 1 suggestion")
        #expect(PeopleFormat.reviewTitle(12) == "Review 12 suggestions")
    }

    @Test func aPersonIsCaptionedWithTheirPhotos() {
        #expect(PeopleFormat.personCaption(makePerson(1, photos: 31), locale: us) == "31 photos")
        #expect(PeopleFormat.personCaption(makePerson(1, photos: 1), locale: us) == "1 photo")
    }

    @Test func aFailedWriteSaysWhatWentWrong() {
        #expect(PeopleMessages.failure(CullingBayError.transport("x")) == "Can’t reach the photo server. Is the PC on and in Ubuntu?")
        #expect(PeopleMessages.failure(CullingBayError.transport(ServerLink.forcedMessage))
            == "Work offline is on. Turn it off to change people.")
        #expect(PeopleMessages.failure(CullingBayError.http(status: 404, message: "no such person"))
            == "That person or face isn’t there any more.")
        #expect(PeopleMessages.failure(CullingBayError.http(status: 400, message: "faces must not be empty"))
            == "Couldn’t save that: faces must not be empty")
        #expect(PeopleMessages.failure(CullingBayError.http(status: 500, message: nil)) == "Couldn’t save that: HTTP 500")
        #expect(PeopleMessages.failure(CullingBayError.unavailable(message: nil)) == "Couldn’t save that: the server refused")
        #expect(PeopleMessages.failure(PersonNameTaken(existing: makePerson(2, "Alex"))) == "“Alex” is already someone.")
    }
}
