import CullingBayCore
import Observation

/// One day pushed on the Cull tab's navigation stack, with the session that goes with it.
struct CullDayRoute: Hashable {
    let session: CullSessionModel

    static func == (lhs: CullDayRoute, rhs: CullDayRoute) -> Bool { lhs.session === rhs.session }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(session)) }
}

/// What the Cull tab's navigation stack has pushed. A day's session is made when the day is
/// pushed and closed when it leaves the stack, however it leaves (the Days button, a Back swipe,
/// the server changing). Views can disappear without the day closing, as when the tab bar
/// switches tabs, so the stack is what says the day is over.
@MainActor
@Observable
final class CullRouter {
    var path: [CullDayRoute] = [] {
        didSet {
            for route in oldValue where !path.contains(route) { route.session.close() }
        }
    }

    var isDayOpen: Bool { !path.isEmpty }

    /// Opens a day. A second tap on the same row while it is opening does nothing.
    func open(_ day: String, match: CullMatch? = nil, services: AppServices) {
        guard path.last?.session.dayID != day else { return }
        path.append(CullDayRoute(session: services.makeCullSession(day: day, match: match)))
    }
}
