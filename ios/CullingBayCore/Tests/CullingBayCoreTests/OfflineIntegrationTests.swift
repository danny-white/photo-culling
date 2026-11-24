import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

/// The saved days seen from the client, the days list and an opened day, with the PC unreachable.
@MainActor
@Suite("Offline: through the app's models")
struct OfflineIntegrationTests {
    let dayID = "2026/2026-10-01"

    private func unreachable() -> FakeTransport {
        FakeTransport { _, _ in throw CullingBayError.transport("The Internet connection appears to be offline.") }
    }

    private func online(_ days: [Day]) -> FakeTransport {
        let list = daysJSON(days)
        return FakeTransport { request, _ in jsonResponse(list, for: request) }
    }

    private func offline(_ base: any HTTPTransport, _ store: OfflineStore) -> CullingBayClient {
        CullingBayClient(
            baseURL: testBaseURL,
            transport: OfflineTransport(base: base, store: store, isEnabled: { true }))
    }

    // MARK: The days list

    @Test func theClientSaysWhenTheListCameFromThePhone() async throws {
        let root = TempRoot()
        let store = root.store()
        try store.writeDays(Data(daysJSON([listDay("2026-10-01")]).utf8))

        let fetched = try await offline(unreachable(), store).fetchDays()
        #expect(fetched.servedOffline)
        #expect(fetched.value.map(\.day) == [dayID])
        #expect(try await offline(unreachable(), store).days().count == 1)

        let live = try await offline(online([listDay("2026-10-01")]), store).fetchDays()
        #expect(!live.servedOffline)
    }

    @Test func theDaysModelKnowsItsListIsTheSavedOne() async throws {
        let root = TempRoot()
        let store = root.store()
        // A first, online load saves the list.
        let first = CullDaysModel(client: offline(online([listDay("2026-10-01", decided: 5)]), store))
        await first.load()
        #expect(first.phase == .loaded)
        #expect(!first.isServedOffline)

        // Later the PC is gone: the list still loads, from the phone, and says so.
        let second = CullDaysModel(client: offline(unreachable(), store))
        await second.load()
        #expect(second.phase == .loaded)
        #expect(second.isServedOffline)
        #expect(second.inProgress.map(\.day.day) == [dayID])
        #expect(second.refreshError == nil)
    }

    @Test func withNoSavedListAnUnreachablePCIsStillAnError() async {
        let model = CullDaysModel(client: offline(unreachable(), TempRoot().store()))
        await model.load()
        #expect(model.phase == .failed("Can’t reach the photo server. Is the PC on and in Ubuntu?"))
        #expect(!model.isServedOffline)
    }

    // MARK: An opened day

    private func session(_ client: CullingBayClient, keeps: Bool) -> CullSessionModel {
        CullSessionModel(
            day: dayID, client: client,
            queue: CullWriteQueue(client: client, store: InMemoryCullWriteStore(), sleep: ManualSleeper().sleep),
            keepsDaysOffline: { keeps })
    }

    @Test func aDayThatIsNotSavedSaysSoWhenTheBaseIsUnreachable() async {
        let client = offline(unreachable(), TempRoot().store())
        let kept = session(client, keeps: true)
        await kept.load()
        #expect(kept.phase == .failed("This day isn't saved on the phone."))
        #expect(kept.phase == .failed(CullSessionModel.notSavedMessage))

        // With offline off it is the ordinary words.
        let plain = session(client, keeps: false)
        await plain.load()
        #expect(plain.phase == .failed("Can’t reach the photo server. Is the PC on and in Ubuntu?"))
    }

    @Test func otherFailuresKeepTheirOwnWordsEvenWithOfflineOn() async {
        let rig = CullRig(day: cullDay([cullStack(0, .single, [cullFrame(1)])]))
        rig.server.on("GET /m/api/day") { _ in Reply(status: 404, body: #"{"error":"no such day"}"#) }
        let model = CullSessionModel(
            day: dayID, client: rig.client, queue: rig.queue, keepsDaysOffline: { true })
        await model.load()
        #expect(model.phase == .failed("That isn’t in the library any more."))
    }

    @Test func aSavedDayOpensAndShowsItsPicturesWithNoConnection() async throws {
        let root = TempRoot()
        let store = root.store()
        let body = cullJSON(cullDay([
            cullStack(0, .single, [cullFrame(1, af: [0.5, 0.5])]), cullStack(1, .single, [cullFrame(2)]),
        ]))
        let pc = FakeTransport { request, _ in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/m/api/day/") { return jsonResponse(body, for: request) }
            return (Data("jpeg \(path) \(queryItems(request)["s"] ?? "crop")".utf8), makeResponse(for: request))
        }
        try await OfflineDownloader(baseURL: testBaseURL, transport: pc, store: store)
            .download(planDay("2026-10-01", frames: 2, decided: 1), includeCrops: true)

        // Now the PC is unreachable.
        let transport = OfflineTransport(base: unreachable(), store: store, isEnabled: { true })
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let opened = session(client, keeps: true)
        await opened.load()
        #expect(opened.phase == .loaded)
        #expect(opened.stacks.count == 2)

        let loader = ImageDataLoader(transport: transport)
        let view = try await loader.data(for: client.imageURL(id: 2, size: .view))
        #expect(String(decoding: view, as: UTF8.self) == "jpeg /m/api/img/2 view")
        let thumb = try await loader.data(for: client.imageURL(id: 1, size: .thumb))
        #expect(String(decoding: thumb, as: UTF8.self) == "jpeg /m/api/img/1 thumb")
        #expect(store.readImage(.af, id: 1) != nil)         // the 1:1 for the focus check is there too
    }
}
