import Foundation

/// The sentences a gallery screen shows when a load fails.
enum GalleryMessages {
    /// `what` finishes "Couldn’t load …": `"that"` on a results screen, `"the library"` at home.
    static func failure(_ error: any Error, loading what: String) -> String {
        guard let error = error as? CullingBayError else {
            return "Couldn’t load \(what): \(error.localizedDescription)"
        }
        switch error {
        case .transport:
            return "Can’t reach the photo server. Is the PC on and in Ubuntu?"
        case .http(404, _):
            return "That isn’t in the library any more."
        case .http(let status, let message):
            return "Couldn’t load \(what): \(message ?? "HTTP \(status)")"
        case .conflict(let message, _), .unavailable(let message):
            return "Couldn’t load \(what): \(message ?? "the server refused")"
        case .decoding(let message):
            return "Couldn’t load \(what): \(message)"
        }
    }
}
