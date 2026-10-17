import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one place the package touches the network, so tests can substitute a fake.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CullingBayError.transport("Response was not an HTTP response")
        }
        return (data, http)
    }
}
