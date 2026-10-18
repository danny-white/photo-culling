import Foundation
import Testing
@testable import CullingBayCore

@Suite("Crop probe")
struct CropProbeTests {
    let client = CullingBayClient(baseURL: testBaseURL, transport: fixedTransport())

    @Test func theProbeIsTheSmallestCropAtTheGivenCentre() {
        let url = client.probeCropURL(id: 43203, center: Point(x: 0.5, y: 0.25))
        #expect(url.absoluteString == "http://100.82.57.4:8000/m/api/crop/43203?x=0.5&y=0.25&w=64&h=64")
    }

    @Test func itReadsTheSourceSizeFromTheCropBoxHeader() async throws {
        let transport = fixedTransport(headers: ["X-Crop-Box": "3944,2620,64,64 of 7952x5304"])
        let box = try await CropProbe.load(url: client.probeCropURL(id: 1, center: Point(x: 0.5, y: 0.5)), transport: transport)
        #expect(box.sourceSize == Size(width: 7952, height: 5304))
        #expect(box.box == Rect(x: 3944, y: 2620, width: 64, height: 64))
    }

    @Test func aMissingHeaderIsADecodingError() async {
        let url = client.probeCropURL(id: 1, center: Point(x: 0.5, y: 0.5))
        await #expect(throws: CullingBayError.self) {
            _ = try await CropProbe.load(url: url, transport: fixedTransport())
        }
    }

    @Test func aFailedStatusIsAnHTTPError() async {
        let url = client.probeCropURL(id: 1, center: Point(x: 0.5, y: 0.5))
        await #expect(throws: CullingBayError.http(status: 415, message: nil)) {
            _ = try await CropProbe.load(url: url, transport: fixedTransport(status: 415))
        }
    }
}
