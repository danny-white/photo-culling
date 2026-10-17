import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CullingBayCore

@Suite("URL builders")
struct URLTests {
    let client = CullingBayClient(baseURL: testBaseURL, transport: fixedTransport())

    @Test func imageURLs() {
        #expect(client.imageURL(id: 43203, size: .thumb).absoluteString
                == "http://100.82.57.4:8000/m/api/img/43203?s=thumb")
        #expect(client.imageURL(id: 43203, size: .view).absoluteString
                == "http://100.82.57.4:8000/m/api/img/43203?s=view")
        #expect(client.imageURL(id: 43203, size: .large).absoluteString
                == "http://100.82.57.4:8000/m/api/export/43203?s=large")
    }

    @Test func cropURLFormatsAndRounds() {
        let url = client.cropURL(id: 9, centerX: 0.5, centerY: 0.25, width: 1200, height: 800)
        #expect(url.absoluteString == "http://100.82.57.4:8000/m/api/crop/9?x=0.5&y=0.25&w=1200&h=800")

        let rounded = client.cropURL(id: 9, centerX: 1.0 / 3.0, centerY: 0, width: 1199.6, height: 100.4)
        #expect(rounded.absoluteString
                == "http://100.82.57.4:8000/m/api/crop/9?x=0.333333&y=0&w=1200&h=100")
    }

    @Test func cropURLClampsEverything() {
        let low = client.cropURL(id: 1, centerX: -0.5, centerY: -3, width: 10, height: 0)
        #expect(low.absoluteString == "http://100.82.57.4:8000/m/api/crop/1?x=0&y=0&w=64&h=64")

        let high = client.cropURL(id: 1, centerX: 1.5, centerY: 99, width: 5000, height: 2400.4)
        #expect(high.absoluteString == "http://100.82.57.4:8000/m/api/crop/1?x=1&y=1&w=2400&h=2400")

        let edges = client.cropURL(id: 1, centerX: 1, centerY: 0, width: 64, height: 2400)
        #expect(edges.absoluteString == "http://100.82.57.4:8000/m/api/crop/1?x=1&y=0&w=64&h=2400")

        let junk = client.cropURL(
            id: 1, centerX: .nan, centerY: .infinity, width: .nan, height: -.infinity)
        #expect(junk.absoluteString == "http://100.82.57.4:8000/m/api/crop/1?x=0&y=1&w=64&h=64")
    }

    @Test func saveURLs() {
        let raw = makePhoto(id: 43203, file: "DSC05040.ARW", raw: true)
        #expect(client.saveURL(for: raw, kind: .picture).absoluteString
                == "http://100.82.57.4:8000/m/api/export/43203")
        #expect(client.saveURL(for: raw, kind: .raw).absoluteString
                == "http://100.82.57.4:8000/m/api/export/43203?s=original")

        let jpeg = makePhoto(id: 12, file: "IMG_0001.JPG", raw: false)
        #expect(client.saveURL(for: jpeg, kind: .picture).absoluteString
                == "http://100.82.57.4:8000/m/api/export/12")
    }

    @Test func baseURLWithTrailingSlashOrPathPrefix() {
        let slash = CullingBayClient(baseURL: URL(string: "http://host:8000/")!, transport: fixedTransport())
        #expect(slash.imageURL(id: 1, size: .thumb).absoluteString == "http://host:8000/m/api/img/1?s=thumb")

        let prefixed = CullingBayClient(baseURL: URL(string: "http://host/culling/")!, transport: fixedTransport())
        #expect(prefixed.imageURL(id: 1, size: .thumb).absoluteString == "http://host/culling/m/api/img/1?s=thumb")
    }

    // MARK: JSON route URLs, observed on the wire

    /// The URL a call asked for, via a fake transport that answers `body` with 200.
    private func requestedURL(
        body: String, _ call: (CullingBayClient) async throws -> Void
    ) async throws -> String {
        let transport = fixedTransport(body: body)
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        try await call(client)
        let requests = await transport.requests
        #expect(requests.count == 1)
        return try #require(requests.first?.url?.absoluteString)
    }

    private let emptyList = #"{"query":"","total":0,"signals":[],"notes":[],"photos":[]}"#

    @Test func daysURL() async throws {
        let url = try await requestedURL(body: #"{"days":[]}"#) { _ = try await $0.days() }
        #expect(url == "http://100.82.57.4:8000/m/api/days")
    }

    @Test func searchURLEncodesPlus() async throws {
        let url = try await requestedURL(body: emptyList) { _ = try await $0.search("c++") }
        #expect(url == "http://100.82.57.4:8000/m/api/gallery/search?q=c%2B%2B&best=0&bursts=1")
    }

    @Test func searchURLEncodesAmpersandAndSpaces() async throws {
        let url = try await requestedURL(body: emptyList) { _ = try await $0.search("fish & chips") }
        #expect(url == "http://100.82.57.4:8000/m/api/gallery/search?q=fish%20%26%20chips&best=0&bursts=1")
    }

    @Test func searchURLEncodesUnicode() async throws {
        let url = try await requestedURL(body: emptyList) { _ = try await $0.search("Gruyère") }
        #expect(url == "http://100.82.57.4:8000/m/api/gallery/search?q=Gruy%C3%A8re&best=0&bursts=1")
    }

    @Test func searchURLEncodesEqualsHashQuestionAndPercent() async throws {
        let url = try await requestedURL(body: emptyList) { _ = try await $0.search("a=b#c?d%e") }
        #expect(url == "http://100.82.57.4:8000/m/api/gallery/search?q=a%3Db%23c%3Fd%25e&best=0&bursts=1")
    }

    @Test func searchURLCarriesBestAndBurstsFlags() async throws {
        let url = try await requestedURL(body: emptyList) {
            _ = try await $0.search("owl", best: true, bursts: false)
        }
        #expect(url == "http://100.82.57.4:8000/m/api/gallery/search?q=owl&best=1&bursts=0")
    }

    @Test func searchQueryRoundTripsThroughPercentDecoding() async throws {
        let original = "c++ & \"fish\" = chips #1 Gruyère 日本"
        let url = try await requestedURL(body: emptyList) { _ = try await $0.search(original) }
        let query = try #require(URLComponents(string: url)?.percentEncodedQuery)
        let value = try #require(query.split(separator: "&").first { $0.hasPrefix("q=") })
        // Flask decodes `+` as a space, so there must be no literal `+` left to misread.
        #expect(!value.contains("+"))
        #expect(String(value.dropFirst(2)).removingPercentEncoding == original)
    }

    @Test func likeURL() async throws {
        let url = try await requestedURL(body: emptyList) {
            _ = try await $0.like(43203, best: true, bursts: true)
        }
        #expect(url == "http://100.82.57.4:8000/m/api/gallery/like/43203?best=1&bursts=1")
    }

    @Test func galleryDayURLKeepsTheSlash() async throws {
        let url = try await requestedURL(body: galleryDayJSON()) {
            _ = try await $0.galleryDay("2026/2026-10-01", bursts: true)
        }
        #expect(url == "http://100.82.57.4:8000/m/api/gallery/day/2026/2026-10-01?best=0&bursts=1")
    }

    @Test func galleryDayURLEncodesEachSegment() async throws {
        let url = try await requestedURL(body: galleryDayJSON()) {
            _ = try await $0.galleryDay("trip 1/a+b#c", best: true, bursts: false)
        }
        #expect(url == "http://100.82.57.4:8000/m/api/gallery/day/trip%201/a%2Bb%23c?best=1&bursts=0")
    }

    @Test func fetchEncodesQueryNamesAndValues() async throws {
        let transport = fixedTransport(body: "{}")
        let client = CullingBayClient(baseURL: testBaseURL, transport: transport)
        let _: Fetched<[String: String]> = try await client.fetch(
            path: "/m/api/x y", query: [("a b", "c&d"), ("e", "")])
        let url = try #require(await transport.requests.first?.url?.absoluteString)
        #expect(url == "http://100.82.57.4:8000/m/api/x%20y?a%20b=c%26d&e=")
    }
}
