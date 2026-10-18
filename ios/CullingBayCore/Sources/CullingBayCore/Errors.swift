import Foundation

public enum CullingBayError: Error, Equatable, Sendable {
    /// The server answered with a non-2xx status. `message` is the JSON `error` field when present.
    case http(status: Int, message: String?)
    /// A write was refused with 409. `applied` is how many decisions already reached Lightroom
    /// (a day reset is refused for that reason); `message` is the server's `error` text.
    case conflict(message: String?, applied: Int?)
    /// A write was refused with 503: the Lightroom inbox share is not mounted on the PC and
    /// nothing was changed. `message` is the server's `error` text.
    case unavailable(message: String?)
    /// The body was not the JSON shape we expected.
    case decoding(String)
    /// The request never produced an HTTP response (offline, timeout, bad response type).
    case transport(String)
}
