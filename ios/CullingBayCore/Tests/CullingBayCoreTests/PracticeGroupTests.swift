import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Practice: Needs Desktop groups")
struct PracticeGroupTests {
    private func make(_ items: [String]) -> PracticeModel {
        PracticeModel(
            client: CullingBayClient(
                baseURL: testBaseURL, transport: practiceTransport(list: practiceListJSON(items))))
    }

    /// A pair in the file: the Needs Desktop parent, then its phone version.
    private func pair(
        _ id: String, desktop: String = "todo", phone: String = "todo"
    ) -> [String] {
        [
            practiceJSON(id, status: desktop, needsDesktop: true, reason: "Needs Enhance.", companions: ["\(id)-phone"]),
            practiceJSON("\(id)-phone", status: phone, needsDesktop: false, companionOf: id, companions: []),
        ]
    }

    private func challenge(
        _ id: String, status: PracticeStatus = .todo, of parent: String? = nil
    ) -> PracticeChallenge {
        PracticeChallenge(
            id: id, title: id, photo: galleryPhoto(1), status: status, companionOf: parent)
    }

    // MARK: Grouping

    @Test func aCompanionJoinsItsParentAndGroupsKeepTheFilesOrder() async {
        let model = make(
            [practiceJSON("a")] + pair("b") + [practiceJSON("c"), practiceJSON("d", needsDesktop: true)])
        await model.load()
        #expect(model.groups.map(\.id) == ["a", "b", "c", "d"])
        #expect(model.groups.map { $0.companions.map(\.id) } == [[], ["b-phone"], [], []])
        #expect(model.groups.map(\.count) == [1, 2, 1, 1])
        #expect(model.groups[1].members.map(\.id) == ["b", "b-phone"])
        #expect(model.groups[1].parent.needsDesktop)
    }

    @Test func aCompanionWithNoParentStandsAlone() {
        let groups = PracticeGroup.groups(of: [
            challenge("a"), challenge("a-phone"), challenge("lost-phone", of: "not-in-the-list"),
        ])
        #expect(groups.map(\.id) == ["a", "a-phone", "lost-phone"])
        #expect(groups.allSatisfy { $0.companions.isEmpty && $0.count == 1 })
    }

    @Test func aCompanionOfACompanionStandsAlone() {
        let groups = PracticeGroup.groups(of: [
            challenge("a"), challenge("a-phone", of: "a"), challenge("odd", of: "a-phone"),
        ])
        #expect(groups.map(\.id) == ["a", "odd"])
        #expect(groups[0].companions.map(\.id) == ["a-phone"])
    }

    @Test func severalCompanionsFollowTheFilesOrder() {
        let groups = PracticeGroup.groups(of: [
            challenge("a"), challenge("a-two", of: "a"), challenge("b"), challenge("a-one", of: "a"),
        ])
        #expect(groups.map(\.id) == ["a", "b"])
        #expect(groups[0].companions.map(\.id) == ["a-two", "a-one"])
    }

    // MARK: Sections

    @Test func aPairGoesToTheSectionItsMembersCallFor() {
        // (desktop, phone, section)
        let cases: [(PracticeStatus, PracticeStatus, PracticeSection)] = [
            (.todo, .todo, .waiting),
            (.todo, .done, .waiting),
            (.downloaded, .done, .waiting),
            (.done, .todo, .waiting),
            (.done, .downloaded, .waiting),
            (.skipped, .downloaded, .waiting),
            (.done, .done, .done),
            (.done, .skipped, .done),
            (.skipped, .done, .done),
            (.skipped, .skipped, .skipped),
        ]
        for (desktop, phone, section) in cases {
            let group = PracticeGroup(
                parent: challenge("a", status: desktop),
                companions: [challenge("a-phone", status: phone, of: "a")])
            #expect(group.section == section, "desktop \(desktop), phone \(phone)")
        }
    }

    @Test func aGroupOfOneFollowsItsOwnStatus() {
        let statuses: [PracticeStatus] = [.todo, .downloaded, .done, .skipped]
        let sections = statuses.map { PracticeGroup(parent: challenge("a", status: $0)).section }
        #expect(sections == [.waiting, .waiting, .done, .skipped])
    }

    @Test func theModelListsEachGroupInItsSectionInTheFilesOrder() async {
        let items =
            pair("p1", desktop: "todo", phone: "done")            // waiting: the desktop half is
            + pair("p2", desktop: "done", phone: "done")          // done
            + [practiceJSON("solo-skipped", status: "skipped")]   // skipped
            + pair("p3", desktop: "done", phone: "skipped")       // done
            + pair("p4", desktop: "skipped", phone: "skipped")    // skipped
            + [practiceJSON("solo-downloaded", status: "downloaded")]
        let model = make(items)
        await model.load()
        #expect(model.waitingGroups.map(\.id) == ["p1", "solo-downloaded"])
        #expect(model.doneGroups.map(\.id) == ["p2", "p3"])
        #expect(model.skippedGroups.map(\.id) == ["solo-skipped", "p4"])
        // The count a section shows is its rows.
        #expect(model.waitingGroups.map(\.count).reduce(0, +) == 3)
        #expect(model.doneGroups.map(\.count).reduce(0, +) == 4)
        #expect(model.skippedGroups.map(\.count).reduce(0, +) == 3)
        // The flat lists still sort each challenge by its own status.
        #expect(model.waiting.map(\.id) == ["p1", "solo-downloaded"])
        #expect(model.done.map(\.id) == ["p1-phone", "p2", "p2-phone", "p3"])
    }

    @Test func finishingTheLastWaitingMemberMovesTheGroup() async {
        let transport = practiceTransport(list: practiceListJSON(pair("a", desktop: "todo", phone: "done"))) { request in
            (200, practiceStateJSON(request.url?.lastPathComponent ?? "", status: "done", doneAt: "2026-11-22T10:00:00"))
        }
        let model = PracticeModel(client: CullingBayClient(baseURL: testBaseURL, transport: transport))
        await model.load()
        #expect(model.waitingGroups.map(\.id) == ["a"] && model.doneGroups.isEmpty)
        await model.setStatus(.done, for: "a")
        #expect(model.waitingGroups.isEmpty && model.doneGroups.map(\.id) == ["a"])
    }

    // MARK: Lookups

    @Test func theParentAndCompanionsAreLookedUpByID() async {
        let model = make([practiceJSON("a")] + pair("b"))
        await model.load()
        #expect(model.parent(of: "b-phone")?.id == "b")
        #expect(model.parent(of: "b") == nil && model.parent(of: "a") == nil && model.parent(of: "zzz") == nil)
        #expect(model.companions(of: "b").map(\.id) == ["b-phone"])
        #expect(model.companions(of: "a").isEmpty && model.companions(of: "b-phone").isEmpty)
        #expect(model.companions(of: "zzz").isEmpty)
    }

    @Test func aCompanionWhoseParentIsGoneHasNoParent() async {
        let model = make([practiceJSON("x-phone", needsDesktop: false)])
        await model.load()
        #expect(model.parent(of: "x-phone") == nil)
        #expect(model.groups.map(\.id) == ["x-phone"])
    }
}
