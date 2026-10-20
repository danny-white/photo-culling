import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import CullingBayCore

// MARK: Fixtures

func cullFrame(
    _ id: Int, file: String? = nil, lr: LightroomState? = nil, decision: Decision? = nil,
    badges: [String] = [], partners: [String] = [], sharpness: Double? = nil, af: [Double]? = nil
) -> Frame {
    Frame(
        id: id, file: file ?? "DSC\(String(format: "%05d", id)).ARW", partners: partners,
        partnerIDs: partners.indices.map { 90_000 + id + $0 }, sharpness: sharpness, af: af, badges: badges,
        lr: lr, decision: decision)
}

func cullStack(_ id: Int, _ kind: StackKind = .single, _ frames: [Frame], lead: Int? = nil) -> Stack {
    Stack(id: id, kind: kind, lead: lead ?? frames[0].id, frames: frames)
}

func cullDay(
    _ stacks: [Stack], budget: Int = 0, progress: CullingBayCore.Progress? = nil, summary: String? = nil,
    date: String? = "2026-10-01"
) -> CullDay {
    CullDay(
        day: "2026/2026-10-01", folder: "2026-10-01", date: date, summary: summary,
        budget: Budget(stacks: budget, perHour: 10, hours: 0.5), stacks: stacks, progress: progress)
}

/// A flag or stars set in Lightroom by hand.
func lrByYou(pick: Int = 0, rating: Int = 0) -> LightroomState {
    LightroomState(pick: pick, rating: rating, by: pick == 0 ? .unset : .you, starsBy: rating == 0 ? .unset : .you)
}

func draft(_ flag: CullFlag, stars: Int? = nil, note: String = "", state: DecisionState = .draft) -> Decision {
    Decision(flag: flag, stars: stars, note: note, state: state)
}

func cullJSON(_ day: CullDay) -> String {
    String(decoding: (try? JSONEncoder().encode(day)) ?? Data(), as: UTF8.self)
}

// MARK: A fake server for the Cull routes

/// What a route answers. Throw `CullingBayError.transport` from a responder to go offline.
struct Reply: Sendable {
    var status = 200
    var body = #"{"ok":true}"#
}

struct RecordedCall: Sendable {
    let method: String
    let path: String
    let body: Data

    var json: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
    }
}

/// Answers the Cull routes and records every request, in order. A route answers `{"ok":true}`
/// unless a test gives it a responder, which gets how many times the route was called before.
final class CullServer: Sendable {
    typealias Responder = @Sendable (Int) throws -> Reply

    private struct State: Sendable {
        var day: String
        var calls: [RecordedCall] = []
        var responders: [String: Responder] = [:]
        var counts: [String: Int] = [:]
    }

    private let state: Mutex<State>

    init(day: CullDay) {
        state = Mutex(State(day: cullJSON(day)))
    }

    func setDay(_ day: CullDay) {
        state.withLock { $0.day = cullJSON(day) }
    }

    /// `route` is `"POST /m/api/decide"`; a day GET is `"GET /m/api/day"`.
    func on(_ route: String, _ responder: @escaping Responder) {
        state.withLock { $0.responders[route] = responder }
    }

    func calls(_ path: String) -> [RecordedCall] {
        state.withLock { $0.calls.filter { $0.path == path || $0.path.hasSuffix(path) } }
    }

    var allCalls: [RecordedCall] { state.withLock { $0.calls } }

    func transport() -> FakeTransport {
        FakeTransport { [self] request, _ in try respond(request) }
    }

    private func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let key: String
        if path.hasPrefix("/m/api/day/") && !path.hasSuffix("/progress") && !path.hasSuffix("/send")
            && !path.hasSuffix("/reset") {
            key = "GET /m/api/day"
        } else if path.hasSuffix("/progress") {
            key = "PUT progress"
        } else if path.hasSuffix("/send") {
            key = "POST send"
        } else {
            key = method + " " + path
        }
        let (responder, count, day) = state.withLock { state in
            state.calls.append(RecordedCall(method: method, path: path, body: request.httpBody ?? Data()))
            let count = state.counts[key, default: 0]
            state.counts[key] = count + 1
            return (state.responders[key], count, state.day)
        }
        let reply: Reply
        if let responder {
            reply = try responder(count)
        } else if key == "GET /m/api/day" {
            reply = Reply(body: day)
        } else if key == "POST send" {
            reply = Reply(body: #"{"ok":true,"queued":0,"file_rows":0}"#)
        } else {
            reply = Reply()
        }
        return (Data(reply.body.utf8), makeResponse(for: request, status: reply.status))
    }
}

// MARK: A sleeper the test releases by hand

/// Stands in for `Task.sleep`: every sleep waits until the test releases it, or throws if its
/// task is cancelled. Nothing waits in real time.
actor ManualSleeper {
    private struct Waiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Int: Waiter] = [:]
    private var next = 0
    /// Every duration asked for, in order, released or not.
    private(set) var requested: [Duration] = []

    nonisolated var sleep: CullSleep {
        { [self] duration in try await self.wait(duration) }
    }

    private func wait(_ duration: Duration) async throws {
        let id = next
        next += 1
        requested.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(duration: duration, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    /// Durations of the sleeps still waiting, oldest first.
    var waiting: [Duration] {
        waiters.keys.sorted().compactMap { waiters[$0]?.duration }
    }

    /// Lets every waiting sleep of this length return.
    func release(_ duration: Duration) {
        for id in waiters.keys.sorted() where waiters[id]?.duration == duration {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    /// Returns once `count` sleeps of this length are waiting (a few seconds at most).
    func waitFor(_ duration: Duration, count: Int = 1) async -> Bool {
        for _ in 0..<5000 {
            if waiters.values.filter({ $0.duration == duration }).count >= count { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

// MARK: A queue, a server and a session wired together

@MainActor
struct CullRig {
    let server: CullServer
    let sleeper = ManualSleeper()
    let store = InMemoryCullWriteStore()
    let client: CullingBayClient
    let queue: CullWriteQueue
    let ids = ActionIDs()

    init(day: CullDay) {
        server = CullServer(day: day)
        client = CullingBayClient(baseURL: testBaseURL, transport: server.transport())
        queue = CullWriteQueue(client: client, store: store, sleep: sleeper.sleep)
    }

    func session(match: CullMatch? = nil) -> CullSessionModel {
        let ids = self.ids
        return CullSessionModel(
            day: "2026/2026-10-01", client: client, queue: queue, match: match,
            sleep: sleeper.sleep, newActionID: { ids.next() })
    }

    /// Waits until the queue has nothing left (the server answers at once).
    func settle() async {
        #expect(await eventually { await queue.pending == 0 })
    }
}

/// Action ids `A-1`, `A-2`, ... so a test can name the tap it means.
final class ActionIDs: Sendable {
    private let counter = Mutex(0)

    func next() -> String {
        counter.withLock { value in
            value += 1
            return "A-\(value)"
        }
    }
}
