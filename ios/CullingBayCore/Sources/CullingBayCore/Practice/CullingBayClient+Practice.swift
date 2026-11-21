import Foundation

/// The Practice tab's routes. The list is an ordinary read, so it revalidates by the ETag of its
/// body like the others, and a write needs no cached read dropped.
extension CullingBayClient {
    /// Every challenge with its photo and where Danny has got with it.
    public func practice() async throws -> PracticeList {
        let fetched: Fetched<PracticeList> = try await fetch(path: "/m/api/practice")
        return fetched.value
    }

    /// Changes a challenge's status, its note, or both; a nil one is left out of the request and
    /// stays as it is. The answer is the challenge's state afterwards, which the server decides
    /// (`downloaded` never moves a done challenge back). `id` is percent-encoded into the path,
    /// so spaces and `&` survive; a `/` in it stays a separator, which the route accepts.
    public func updatePractice(
        id: String, status: PracticeStatus? = nil, note: String? = nil
    ) async throws -> PracticeState {
        try await writeJSON(
            method: "POST", path: "/m/api/practice/\(id)",
            body: PracticeBody(status: status, note: note), staling: .nothing)
    }
}

private struct PracticeBody: Encodable, Sendable {
    let status: PracticeStatus?
    let note: String?
}
