import Foundation
import Testing
@testable import CullingBayCore

@Suite("People models")
struct PeopleModelsTests {
    let decoder = JSONDecoder()

    @Test func theListDecodesPeopleGroupsAndCoverage() throws {
        let list = try decoder.decode(PeopleList.self, from: Data(peopleListJSON.utf8))
        #expect(list.people.map(\.name) == ["Alex", "Sam Lee"])
        #expect(list.facesChecked == 8609)
        #expect(list.photosOK == 43195)
        let alex = list.people[0]
        #expect(alex == Person(id: 2, name: "Alex", photos: 31, faces: 38, cover: 412, suggestions: 12))
        #expect(alex.id == 2)
    }

    @Test func aGroupMayCarryAMaybeAndMayNot() throws {
        let list = try decoder.decode(PeopleList.self, from: Data(peopleListJSON.utf8))
        let first = list.groups[0], second = list.groups[1]
        #expect(first.key == 1 && first.id == 1)
        #expect(first.faces == 1039 && first.photos == 1039 && first.days == 61 && first.cover == 10768)
        #expect(first.maybe == PersonRef(id: 2, name: "Alex"))
        #expect(second.maybe == nil)
        #expect(first.withoutMaybe().maybe == nil)
        #expect(first.withoutMaybe().key == 1)
    }

    @Test func aPersonWithNoFacesLeftHasNoCover() throws {
        let json = #"{"id":3,"name":"Jo","photos":0,"faces":0,"cover":null,"suggestions":0}"#
        let person = try decoder.decode(Person.self, from: Data(json.utf8))
        #expect(person.cover == nil)
    }

    @Test func aPersonCarriesTheDoubtsTheServerCounts() throws {
        let json = #"{"cover":412,"doubts":250,"faces":38,"id":2,"name":"Alex","photos":31,"suggestions":12}"#
        let person = try decoder.decode(Person.self, from: Data(json.utf8))
        #expect(person.doubts == 250)
        #expect(person == Person(id: 2, name: "Alex", photos: 31, faces: 38, cover: 412, suggestions: 12, doubts: 250))
        #expect(person != Person(id: 2, name: "Alex", photos: 31, faces: 38, cover: 412, suggestions: 12))
    }

    @Test func aPersonFromAnOlderServerHasNoDoubts() throws {
        let json = #"{"cover":412,"faces":38,"id":2,"name":"Alex","photos":31,"suggestions":12}"#
        let person = try decoder.decode(Person.self, from: Data(json.utf8))
        #expect(person.doubts == 0)
        #expect(person.suggestions == 12 && person.cover == 412)
    }

    @Test func aPersonWithDoubtsSurvivesBeingWrittenAndReadAgain() throws {
        let person = makePerson(2, "Alex", photos: 31, faces: 38, suggestions: 3, doubts: 7)
        let data = try JSONEncoder().encode(person)
        #expect(try decoder.decode(Person.self, from: data) == person)
    }

    @Test func emptyListsDecodeBeforeTheFirstGroupingRun() throws {
        let json = #"{"people":[],"groups":[],"faces_checked":0,"photos_ok":43195}"#
        let list = try decoder.decode(PeopleList.self, from: Data(json.utf8))
        #expect(list.people.isEmpty && list.groups.isEmpty && list.facesChecked == 0)
    }

    @Test func aPersonsPhotosAndAGroupsPhotosDecode() throws {
        let person = try decoder.decode(PersonPhotos.self, from: Data(personPhotosJSON.utf8))
        #expect(person.id == 2 && person.name == "Alex" && person.total == 31)
        #expect(person.photos.map(\.id) == [43203])
        let group = try decoder.decode(GroupPhotos.self, from: Data(groupPhotosJSON.utf8))
        #expect(group.key == 315 && group.total == 441 && group.photos.count == 1)
    }

    @Test func facesDecodeWithTheirHow() throws {
        let faces = try decoder.decode(PersonFaces.self, from: Data(personFacesJSON.utf8))
        #expect(faces.total == 3)
        #expect(faces.faces.map(\.how) == [.auto, .auto, .confirmed])
        #expect(faces.faces[2] == PersonFace(id: 77, photo: 43100, how: .confirmed))
    }

    @Test func suggestionsDecodeFacesAndGroups() throws {
        let body = try decoder.decode(PersonSuggestions.self, from: Data(suggestionsJSON.utf8))
        #expect(body.faces == [
            FaceSuggestion(id: 501, photo: 43210, sim: 0.541), FaceSuggestion(id: 502, photo: 43211, sim: 0.488),
        ])
        #expect(body.groups.map(\.key) == [1])
        #expect(body.groups[0].maybe?.name == "Alex")
    }

    @Test func aPhotosFacesDecodeAllThreeStates() throws {
        let faces = try decoder.decode(PhotoFaces.self, from: Data(photoFacesJSON.utf8)).faces
        #expect(faces.map(\.how) == [.confirmed, .unnamed, .unnamed])
        #expect(faces[0].person == PersonRef(id: 2, name: "Alex"))
        #expect(faces[0].suggestion == nil)
        #expect(faces[0].box == [0.30623, 0.24415, 0.48228, 0.60645])
        #expect(faces[1].person == nil)
        #expect(faces[1].suggestion == PersonRef(id: 1, name: "Sam Lee"))
        #expect(faces[2].person == nil && faces[2].suggestion == nil)
    }

    @Test func anUnknownHowIsKeptNotAnError() throws {
        let json = #"{"id":9,"box":[0,0,1,1],"how":"maybe-later"}"#
        let face = try decoder.decode(PhotoFace.self, from: Data(json.utf8))
        #expect(face.how == .other("maybe-later"))
        #expect(face.how.rawValue == "maybe-later")
    }

    @Test func howRoundTripsThroughItsWireWords() throws {
        for (how, word) in [(FaceHow.confirmed, "confirmed"), (.auto, "auto"), (.unnamed, "none")] {
            #expect(how.rawValue == word)
            #expect(FaceHow(rawValue: word) == how)
            let data = try JSONEncoder().encode(PersonFace(id: 1, photo: 2, how: how))
            #expect(try decoder.decode(PersonFace.self, from: data).how == how)
        }
    }
}
