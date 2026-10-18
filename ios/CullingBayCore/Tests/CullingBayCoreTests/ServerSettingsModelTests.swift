import Foundation
import Testing
@testable import CullingBayCore

@MainActor
@Suite("Server settings model")
struct ServerSettingsModelTests {
    private func days(_ count: Int) -> FakeTransport {
        let list = (0..<count).map { libraryDay("2026-10-0\($0 + 1)") }
        return FakeTransport { request, _ in jsonResponse(daysJSON(list), for: request) }
    }

    @Test func startsWithTheCurrentAddress() {
        #expect(ServerSettingsModel(url: testBaseURL).text == "http://100.82.57.4:8000")
    }

    @Test func acceptsHttpAndHttpsAddressesAndTrimsThem() {
        #expect(ServerSettingsModel.validatedURL(" http://100.82.57.4:8000/ \n")?.absoluteString == "http://100.82.57.4:8000")
        #expect(ServerSettingsModel.validatedURL("HTTPS://photos.example.com")?.absoluteString == "https://photos.example.com")
        #expect(ServerSettingsModel.validatedURL("http://pc.local:8000/prefix//")?.absoluteString == "http://pc.local:8000/prefix")
    }

    @Test func rejectsAddressesThatAreNotAServer() {
        for bad in ["", "   ", "100.82.57.4:8000", "localhost:8000", "ftp://pc", "http://", "http:///x",
                    "http://user:pw@pc", "http://pc/?q=1", "http://pc/#top", "http://pc:99999",
                    "http://a b", "sunset"] {
            #expect(ServerSettingsModel.validatedURL(bad) == nil, "\(bad)")
        }
    }

    @Test func checkingReportsTheDayCount() async {
        let model = ServerSettingsModel(url: testBaseURL)
        await model.check(transport: days(2))
        #expect(model.status == "Connected · 2 days")
        #expect(!model.isChecking)
    }

    @Test func aBadAddressIsNotChecked() async {
        let model = ServerSettingsModel(url: testBaseURL)
        model.text = "nonsense"
        let transport = days(1)
        await model.check(transport: transport)
        #expect(model.status == "Enter an http:// or https:// server address.")
        #expect(await transport.requests.isEmpty)
    }

    @Test func aFailureIsSaidInWords() async {
        let model = ServerSettingsModel(url: testBaseURL)
        await model.check(transport: FakeTransport { _, _ in throw URLError(.cannotConnectToHost) })
        #expect(model.status == "Can’t reach the photo server. Is the PC on and in Ubuntu?")
        #expect(!model.isChecking)
    }

    @Test func editingTheAddressClearsAnOldAnswer() async {
        let model = ServerSettingsModel(url: testBaseURL)
        await model.check(transport: days(1))
        model.text = "http://other:8000"
        #expect(model.status == "")
    }

    @Test func anAnswerForAnOldAddressIsDropped() async {
        let gate = GatedTransport { request, _ in jsonResponse(daysJSON([libraryDay("2026-10-01")]), for: request) }
        let model = ServerSettingsModel(url: testBaseURL)
        let check = Task { await model.check(transport: gate) }
        await gate.waitForRequests(1)
        #expect(model.isChecking)
        model.text = "http://other:8000"
        await gate.release(0)
        await check.value
        #expect(model.status == "")
        #expect(!model.isChecking)
        #expect(model.validURL?.absoluteString == "http://other:8000")
    }
}
