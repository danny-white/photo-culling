import Foundation

public enum CullingBayError: Error, Equatable, Sendable {
    /// The server answered with a non-2xx status. `message` is the JSON `error` field when present.
    case http(status: Int, message: String?)
    /// The body was not the JSON shape we expected.
    case decoding(String)
    /// The request never produced an HTTP response (offline, timeout, bad response type).
    case transport(String)
}
