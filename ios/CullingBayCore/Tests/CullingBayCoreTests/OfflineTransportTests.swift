import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import CullingBayCore

@Suite("Offline: transport")
struct OfflineTransportTests {
    let day = "2026/2026-09-29"

    /// A transport that answers with `status` and `body`, or fails, and counts what reached it.
    private func network(
        status: Int = 200, body: String = "network", headers: [String: String] = [:], fails: Bool = false
    ) -> FakeTransport {
        FakeTransport { request, _ in
            if fails { throw CullingBayError.transport("The Internet connection appears to be offline.") }
            return (Data(body.utf8), makeResponse(for: request, status: status, headers: headers))
        }
    }

    private func transport(
        _ base: FakeTransport, _ store: OfflineStore, enabled: Bool = true
    ) -> OfflineTransport {
        OfflineTransport(base: base, store: store, isEnabled: { enabled })
    }

    // MARK: Pictures: local first

    @Test func aSavedPictureComesFromThePhoneWithoutTheNetwork() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeImage(Data("jpeg-bytes".utf8), kind: .thumb, id: 5)
        let base = network()
        let (data, response) = try await transport(base, store).send(getRequest("/m/api/img/5?s=thumb&warm=0"))
        #expect(data == Data("jpeg-bytes".utf8))
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(await base.requests.isEmpty)
    }

    @Test func aPictureTheStoreLacksGoesToTheNetwork() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeImage(Data("thumb".utf8), kind: .thumb, id: 5)
        let base = network(body: "from the PC")
        let offline = transport(base, store)
        // The view of photo 5, and anything of photo 6, are not saved.
        let (view, _) = try await offline.send(getRequest("/m/api/img/5?s=view"))
        let (other, _) = try await offline.send(getRequest("/m/api/img/6?s=thumb"))
        #expect(view == Data("from the PC".utf8))
        #expect(other == Data("from the PC".utf8))
        #expect(await base.requests.count == 2)
    }

    @Test func aMissingPictureIsNotSavedByLookingAtIt() async throws {
        let root = TempRoot()
        let store = root.store()
        let base = network()
        _ = try await transport(base, store).send(getRequest("/m/api/img/5?s=view"))
        #expect(!store.hasImage(.view, id: 5))
    }

    @Test func aMissPassesAnErrorStatusThrough() async throws {
        let base = network(status: 415, body: #"{"error":"cannot decode"}"#)
        let (_, response) = try await transport(base, TempRoot().store()).send(getRequest("/m/api/img/5?s=view"))
        #expect(response.statusCode == 415)
    }

    // MARK: Days and a day: network first

    @Test func aGoodDaysAnswerIsSavedAndPassedOn() async throws {
        let root = TempRoot()
        let store = root.store()
        let base = network(body: #"{"days":[]}"#, headers: ["ETag": "\"e1\""])
        let (data, response) = try await transport(base, store).send(getRequest("/m/api/days"))
        #expect(String(decoding: data, as: UTF8.self) == #"{"days":[]}"#)
        #expect(response.value(forHTTPHeaderField: "ETag") == "\"e1\"")
        #expect(response.value(forHTTPHeaderField: OfflineTransport.offlineHeader) == nil)
        #expect(store.readDays() == Data(#"{"days":[]}"#.utf8))
    }

    @Test func daysAndADayAskTheNetworkWithAShortTimeout() async throws {
        let root = TempRoot()
        let store = root.store()
        let base = network()
        let offline = transport(base, store)
        var days = getRequest("/m/api/days")
        days.timeoutInterval = 60
        _ = try await offline.send(days)
        _ = try await offline.send(getRequest("/m/api/day/\(day)"))
        let sent = await base.requests
        #expect(sent.map(\.timeoutInterval) == [6, 6])
        #expect(days.timeoutInterval == 60)                 // the caller's own request is untouched
    }

    @Test func whenTheNetworkFailsTheSavedDaysListIsServedAndSaysSo() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeDays(Data(#"{"days":[1]}"#.utf8))
        let (data, response) = try await transport(network(fails: true), store).send(getRequest("/m/api/days"))
        #expect(String(decoding: data, as: UTF8.self) == #"{"days":[1]}"#)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: OfflineTransport.offlineHeader) == "1")
        #expect(response.value(forHTTPHeaderField: "ETag") == nil)
    }

    @Test func withNoSavedCopyAFailureIsThrownAsItWas() async throws {
        let root = TempRoot()
        let offline = transport(network(fails: true), root.store())
        await #expect(throws: CullingBayError.transport("The Internet connection appears to be offline.")) {
            _ = try await offline.send(getRequest("/m/api/days"))
        }
    }

    @Test func anHTTPErrorIsPassedThroughNotAnsweredFromTheSavedCopy() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeDays(Data(#"{"days":[1]}"#.utf8))
        let base = network(status: 500, body: #"{"error":"boom"}"#)
        let (data, response) = try await transport(base, store).send(getRequest("/m/api/days"))
        #expect(response.statusCode == 500)
        #expect(String(decoding: data, as: UTF8.self) == #"{"error":"boom"}"#)
        #expect(response.value(forHTTPHeaderField: OfflineTransport.offlineHeader) == nil)
        #expect(store.readDays() == Data(#"{"days":[1]}"#.utf8))      // and the copy is left alone
    }

    @Test func aCancelledRequestIsNotAnsweredFromTheSavedCopy() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeDays(Data("saved".utf8))
        let base = FakeTransport { _, _ in throw CancellationError() }
        let offline = transport(base, store)
        await #expect(throws: CancellationError.self) {
            _ = try await offline.send(getRequest("/m/api/days"))
        }
    }

    @Test func aSavedDayIsRefreshedByAGoodAnswerAndServedWhenTheNetworkFails() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.begin(day: day, frames: 1, photos: [1])
        try store.writeDay(day, Data("old".utf8))
        try store.finish(day: day)
        let online = transport(network(body: "new"), store)
        let (fresh, _) = try await online.send(getRequest("/m/api/day/\(day)"))
        #expect(fresh == Data("new".utf8))
        #expect(store.readDay(day) == Data("new".utf8))

        let (copy, response) = try await transport(network(fails: true), store).send(getRequest("/m/api/day/\(day)"))
        #expect(copy == Data("new".utf8))
        #expect(response.value(forHTTPHeaderField: OfflineTransport.offlineHeader) == "1")
    }

    @Test func aDayThatIsNotSavedIsNeitherKeptNorServed() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.begin(day: day, frames: 1, photos: [1])           // started, not finished
        try store.writeDay(day, Data("partial".utf8))
        _ = try await transport(network(body: "new"), store).send(getRequest("/m/api/day/\(day)"))
        #expect(store.readDay(day) == Data("partial".utf8))         // not refreshed
        let offline = transport(network(fails: true), store)
        await #expect(throws: CullingBayError.self) {
            _ = try await offline.send(getRequest("/m/api/day/\(day)"))
        }
    }

    @Test func aNotModifiedAnswerKeepsTheOldCopy() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeDays(Data("saved".utf8))
        let base = network(status: 304, body: "")
        var request = getRequest("/m/api/days")
        request.setValue("\"e1\"", forHTTPHeaderField: "If-None-Match")
        let (data, response) = try await transport(base, store).send(request)
        #expect(response.statusCode == 304)
        #expect(data.isEmpty)
        #expect(store.readDays() == Data("saved".utf8))
        #expect(await base.requests[0].value(forHTTPHeaderField: "If-None-Match") == "\"e1\"")
    }

    @Test func withNoCopyToKeepTheTagIsDroppedSoABodyComesToSave() async throws {
        let root = TempRoot()
        let store = root.store()
        let base = network(body: "full body")
        var request = getRequest("/m/api/days")
        request.setValue("\"e1\"", forHTTPHeaderField: "If-None-Match")
        _ = try await transport(base, store).send(request)
        #expect(await base.requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(store.readDays() == Data("full body".utf8))

        // A day that is not saved keeps no copy, so its tag stays and a 304 still works for the client.
        var dayRequest = getRequest("/m/api/day/\(day)")
        dayRequest.setValue("\"e2\"", forHTTPHeaderField: "If-None-Match")
        _ = try await transport(base, store).send(dayRequest)
        #expect(await base.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"e2\"")
    }

    // MARK: Everything else

    @Test func writesCropsSearchAndTheGalleryPassStraightThrough() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeImage(Data("saved".utf8), kind: .view, id: 5)
        let base = network(fails: true)
        let offline = transport(base, store)

        var write = getRequest("/m/api/decide")
        write.httpMethod = "POST"
        write.httpBody = Data("{}".utf8)
        write.setValue("1", forHTTPHeaderField: "X-Culling-Bay")
        write.timeoutInterval = 60
        let routes = [
            write, getRequest("/m/api/crop/5?x=0.5&y=0.5&w=1200&h=1200&keep=0"),
            getRequest("/m/api/gallery/search?q=x"), getRequest("/m/api/gallery/day/\(day)"),
            getRequest("/m/api/search?q=x"), getRequest("/m/api/export/5?s=large"),
            getRequest("/m/api/img/5?s=large"),
        ]
        for request in routes {
            await #expect(throws: CullingBayError.self) { _ = try await offline.send(request) }
        }
        let sent = await base.requests
        #expect(sent.count == routes.count)
        #expect(sent[0].httpMethod == "POST")
        #expect(sent[0].httpBody == Data("{}".utf8))
        #expect(sent[0].value(forHTTPHeaderField: "X-Culling-Bay") == "1")
        #expect(sent[0].timeoutInterval == 60)
        #expect(sent.dropFirst().allSatisfy { $0.timeoutInterval == 60 })   // URLRequest's default
        #expect(sent.map { $0.url?.absoluteString } == routes.map { $0.url?.absoluteString })
    }

    @Test func aPutIsNotAGetEvenOnADayRoute() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.begin(day: day, frames: 1, photos: [])
        try store.writeDay(day, Data("old".utf8))
        try store.finish(day: day)
        let base = network(body: #"{"ok":true}"#)
        var request = getRequest("/m/api/day/\(day)/progress")
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        _ = try await transport(base, store).send(request)
        #expect(await base.requests[0].timeoutInterval == 60)
        #expect(store.readDay(day) == Data("old".utf8))
    }

    @Test func withOfflineOffEveryRequestPassesStraightThrough() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeImage(Data("saved".utf8), kind: .thumb, id: 5)
        try store.writeDays(Data("saved days".utf8))
        let base = network(body: "network")
        let off = transport(base, store, enabled: false)

        let (image, _) = try await off.send(getRequest("/m/api/img/5?s=thumb"))
        #expect(image == Data("network".utf8))              // the saved one is not used
        var days = getRequest("/m/api/days")
        days.timeoutInterval = 60
        _ = try await off.send(days)
        #expect(await base.requests.count == 2)
        #expect(await base.requests[1].timeoutInterval == 60)
        #expect(store.readDays() == Data("saved days".utf8))          // and nothing is saved

        let failing = transport(network(fails: true), store, enabled: false)
        await #expect(throws: CullingBayError.self) { _ = try await failing.send(getRequest("/m/api/days")) }
    }

    @Test func theSwitchIsReadOnEveryRequest() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeImage(Data("saved".utf8), kind: .thumb, id: 5)
        let enabled = Mutex(true)
        let base = network(body: "network")
        let offline = OfflineTransport(base: base, store: store, isEnabled: { enabled.withLock { $0 } })
        #expect(try await offline.send(getRequest("/m/api/img/5?s=thumb")).0 == Data("saved".utf8))
        enabled.withLock { $0 = false }
        #expect(try await offline.send(getRequest("/m/api/img/5?s=thumb")).0 == Data("network".utf8))
    }
}
