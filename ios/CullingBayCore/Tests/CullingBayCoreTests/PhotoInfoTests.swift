import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

/// Real answers from `GET /m/api/info/<id>` on 25 Nov 2026.
let infoSonyARWJSON = """
{"aperture":4,"bytes":43198976,"camera":"Sony ILCE-7RM3","ev":-0.7,"file":"DSC04912.ARW",
 "flash":"Off, Did not fire","focal_35mm":40,"focal_mm":40.4,"focus_mode":"AF-C","format":"ARW","gps":null,
 "height":5320,"id":43079,"iso":100,"lens":"24-70mm F2.8 DG DN | Art 019","make":"SONY",
 "megapixels":42.56,"metering":"Multi-segment","model":"ILCE-7RM3","offset":"-07:00","place":null,
 "program":"Aperture-priority AE","shutter_s":0.0004,"taken":"2026:09:29 15:35:35",
 "white_balance":"Auto","width":8000}
"""

let infoIPhoneDNGJSON = """
{"aperture":1.779999971,"bytes":79971644,"camera":"Apple iPhone 17 Pro","ev":0,"file":"IMG_6997.DNG",
 "flash":"Off, Did not fire","focal_35mm":24,"focal_mm":6.764999866,"focus_mode":null,"format":"DNG",
 "gps":[19.4286305555556,-99.1660472222222],"height":6048,"id":35172,"iso":800,
 "lens":"iPhone 17 Pro back triple camera 6.765mm f/1.78","make":"Apple","megapixels":48.771072,
 "metering":"Multi-segment","model":"iPhone 17 Pro","offset":"-06:00","place":"Cuauht\\u00e9moc, Mexico City, Mexico",
 "program":"Program AE","shutter_s":0.05882352941,"taken":"2026:02:07 18:59:18.174",
 "white_balance":"Auto","width":8064}
"""

let infoCanonCR2JSON = """
{"id":380,"file":"IMG_9154.CR2","format":"CR2","camera":"Canon EOS REBEL T5i","focal_35mm":null,"offset":null,
 "taken":"2024:04:02 03:51:04.14","shutter_s":0.000625,"aperture":null,"bytes":null,"ev":null,"flash":null,
 "focal_mm":null,"focus_mode":null,"gps":null,"height":null,"iso":null,"lens":null,"make":null,
 "megapixels":null,"metering":null,"model":null,"place":null,"program":null,"white_balance":null,"width":null}
"""

private func decodeInfo(_ json: String) throws -> PhotoInfo {
    try JSONDecoder().decode(PhotoInfo.self, from: Data(json.utf8))
}

@Suite("Photo details: decoding")
struct PhotoInfoDecodingTests {
    @Test func aSonyRawDecodesWithEveryField() throws {
        let info = try decodeInfo(infoSonyARWJSON)
        #expect(info.id == 43079)
        #expect(info.file == "DSC04912.ARW")
        #expect(info.format == "ARW")
        #expect(info.bytes == 43_198_976)
        #expect(info.width == 8000 && info.height == 5320)
        #expect(info.megapixels == 42.56)
        #expect(info.camera == "Sony ILCE-7RM3" && info.make == "SONY" && info.model == "ILCE-7RM3")
        #expect(info.lens == "24-70mm F2.8 DG DN | Art 019")
        #expect(info.iso == 100)
        #expect(info.shutterSeconds == 0.0004)
        #expect(info.aperture == 4)
        #expect(info.focalMM == 40.4 && info.focal35MM == 40)
        #expect(info.ev == -0.7)
        #expect(info.program == "Aperture-priority AE" && info.metering == "Multi-segment")
        #expect(info.flash == "Off, Did not fire" && info.whiteBalance == "Auto" && info.focusMode == "AF-C")
        #expect(info.taken == "2026:09:29 15:35:35" && info.offset == "-07:00")
        #expect(info.gps == nil && info.place == nil)
    }

    @Test func anIPhoneDNGDecodesItsPositionAndPlace() throws {
        let info = try decodeInfo(infoIPhoneDNGJSON)
        #expect(info.id == 35172 && info.format == "DNG")
        #expect(info.gps == PhotoInfo.Coordinates(latitude: 19.4286305555556, longitude: -99.1660472222222))
        #expect(info.place == "Cuauhtémoc, Mexico City, Mexico")
        #expect(info.focusMode == nil)
        #expect(info.ev == 0)
        #expect(info.shutterSeconds == 0.05882352941)
        #expect(info.taken == "2026:02:07 18:59:18.174")
    }

    @Test func aCanonRawWithMostFieldsNullDecodes() throws {
        let info = try decodeInfo(infoCanonCR2JSON)
        #expect(info.file == "IMG_9154.CR2" && info.camera == "Canon EOS REBEL T5i")
        #expect(info.shutterSeconds == 0.000625)
        #expect(info.taken == "2024:04:02 03:51:04.14")
        #expect(info.focal35MM == nil && info.offset == nil && info.iso == nil && info.bytes == nil)
        #expect(info.gps == nil)
    }

    @Test func onlyIDAndFileAreRequired() throws {
        let bare = try decodeInfo(#"{"id":5,"file":"A.JPG"}"#)
        #expect(bare == PhotoInfo(id: 5, file: "A.JPG"))
        #expect(throws: DecodingError.self) { _ = try decodeInfo(#"{"file":"A.JPG"}"#) }
        #expect(throws: DecodingError.self) { _ = try decodeInfo(#"{"id":5}"#) }
    }

    @Test func aKeyTheAppDoesNotKnowIsIgnored() throws {
        let info = try decodeInfo(#"{"id":5,"file":"A.JPG","iso":200,"serial":"123","nested":{"a":[1,2]}}"#)
        #expect(info.iso == 200)
    }

    @Test func aCountWrittenWithADecimalPointStillCounts() throws {
        let info = try decodeInfo(#"{"id":5,"file":"A.JPG","iso":200.0,"width":4000.0,"height":3000.0,"bytes":1234567.0}"#)
        #expect(info.iso == 200 && info.width == 4000 && info.height == 3000 && info.bytes == 1_234_567)
    }

    @Test func gpsThatIsNotAPairOfNumbersIsNoPositionAndNotAFailure() throws {
        for gps in ["null", "[]", "[1.5]", "[1,2,3]", #"["a","b"]"#, #"[1,"b"]"#, #""19.4,-99.1""#, "7", "{}",
                    #"{"lat":1,"lon":2}"#, "[[1,2]]"] {
            let info = try decodeInfo(#"{"id":5,"file":"A.JPG","iso":100,"gps":\#(gps)}"#)
            #expect(info.gps == nil, "gps \(gps)")
            #expect(info.iso == 100, "the rest of the answer still decodes with gps \(gps)")
        }
        let at = try decodeInfo(#"{"id":5,"file":"A.JPG","gps":[-33,151]}"#)
        #expect(at.gps == PhotoInfo.Coordinates(latitude: -33, longitude: 151))
    }

    @Test func aFieldOfTheWrongTypeIsADecodingError() {
        #expect(throws: DecodingError.self) { _ = try decodeInfo(#"{"id":5,"file":"A.JPG","iso":"fast"}"#) }
    }
}

@Suite("Photo details: the client")
struct PhotoInfoClientTests {
    private func client(
        status: Int = 200, body: String = infoSonyARWJSON, headers: [String: String] = [:]
    ) -> (CullingBayClient, FakeTransport) {
        let transport = fixedTransport(status: status, body: body, headers: headers)
        return (CullingBayClient(baseURL: testBaseURL, transport: transport), transport)
    }

    @Test func aGoodAnswerIsDecodedFromOnePlainGetWithAShortFuse() async throws {
        let (client, transport) = client()
        let info = try await client.info(id: 43079)
        #expect(info.file == "DSC04912.ARW" && info.iso == 100)
        let sent = await transport.requests
        #expect(sent.count == 1)
        #expect(sent[0].httpMethod == "GET")
        #expect(sent[0].url?.path == "/m/api/info/43079")
        #expect(sent[0].url?.query == nil)
        #expect(sent[0].timeoutInterval == 10 && CullingBayClient.infoTimeout == 10)
        #expect(sent[0].cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(sent[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(sent[0].value(forHTTPHeaderField: "X-Culling-Bay") == nil)
    }

    @Test func aPhotoAskedForAgainComesFromMemory() async throws {
        let (client, transport) = client()
        let first = try await client.info(id: 43079)
        let second = try await client.info(id: 43079)
        #expect(first == second)
        #expect(await transport.requests.count == 1)
        _ = try await client.info(id: 43080)
        #expect(await transport.requests.count == 2)
        #expect(await client.cachedInfoCount == 2)
    }

    @Test func onlyTheLastSixtyFourPhotosAreKept() async throws {
        let (client, transport) = client()
        for id in 1...64 { _ = try await client.info(id: id) }
        #expect(await client.cachedInfoCount == 64)
        _ = try await client.info(id: 1)                         // still kept, and now the newest
        #expect(await transport.requests.count == 64)
        _ = try await client.info(id: 65)                        // pushes out photo 2, the oldest
        #expect(await client.cachedInfoCount == 64)
        let before = await transport.requests.count
        _ = try await client.info(id: 1)
        #expect(await transport.requests.count == before)
        _ = try await client.info(id: 2)
        #expect(await transport.requests.count == before + 1)
    }

    @Test func aFailureIsNotKept() async throws {
        let transport = FakeTransport { request, index in
            index == 0
                ? (Data(#"{"error":"photo storage unavailable"}"#.utf8), makeResponse(for: request, status: 503))
                : (Data(infoSonyARWJSON.utf8), makeResponse(for: request))
        }
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        await #expect(throws: CullingBayError.self) { _ = try await client.info(id: 43079) }
        #expect(await client.cachedInfoCount == 0)
        let info = try await client.info(id: 43079)
        #expect(info.id == 43079)
        #expect(await transport.requests.count == 2)
    }

    @Test func a404IsToldApartWithTheServersWords() async {
        let (client, transport) = client(status: 404, body: #"{"error":"not found"}"#)
        await #expect(throws: CullingBayError.http(status: 404, message: "not found")) {
            _ = try await client.info(id: 9)
        }
        #expect(await transport.requests.count == 1)            // no retry
    }

    @Test func a415IsToldApartWithTheServersWords() async {
        let words = "could not read this file's details: no tags"
        let (client, _) = client(status: 415, body: #"{"error":"\#(words)"}"#)
        await #expect(throws: CullingBayError.http(status: 415, message: words)) {
            _ = try await client.info(id: 9)
        }
    }

    @Test func a503IsUnavailableWithTheServersWords() async {
        let (client, transport) = client(status: 503, body: #"{"error":"photo storage unavailable"}"#)
        await #expect(throws: CullingBayError.unavailable(message: "photo storage unavailable")) {
            _ = try await client.info(id: 9)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func anErrorWithNoBodyStillThrowsItsStatus() async {
        let (client, _) = client(status: 502, body: "<html>bad gateway</html>")
        await #expect(throws: CullingBayError.http(status: 502, message: nil)) { _ = try await client.info(id: 9) }
    }

    @Test func aLostConnectionIsATransportErrorAndNotKept() async {
        let lost = CullingBayClient(
            baseURL: testBaseURL,
            transport: FakeTransport { _, _ in throw CullingBayError.transport("offline") })
        await #expect(throws: CullingBayError.transport("offline")) { _ = try await lost.info(id: 9) }
        let broken = CullingBayClient(baseURL: testBaseURL, transport: FakeTransport { _, _ in throw TestFailure() })
        await #expect(throws: CullingBayError.self) { _ = try await broken.info(id: 9) }
        #expect(await lost.cachedInfoCount == 0)
        #expect(await broken.cachedInfoCount == 0)
    }

    @Test func aBodyThatIsNotDetailsIsADecodingError() async {
        let (client, _) = client(body: #"{"nope":true}"#)
        await #expect(throws: CullingBayError.self) { _ = try await client.info(id: 9) }
        #expect(await client.cachedInfoCount == 0)
    }

    @Test func anotherServersClientStartsWithNothingKept() async throws {
        let (first, _) = client()
        _ = try await first.info(id: 1)
        let (second, transport) = client()
        _ = try await second.info(id: 1)
        #expect(await transport.requests.count == 1)
    }
}
