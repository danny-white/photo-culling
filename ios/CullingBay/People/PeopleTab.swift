import CullingBayCore
import Observation
import SwiftUI

/// What the People tab's navigation stack can hold.
enum PeopleRoute: Hashable {
    case person(Int)
    /// An unnamed group, by its key.
    case group(Int)
    /// A person's faces, for fixing. Carries the person so its title and counts are there at once.
    case manage(Person)
    /// A results screen a viewer button asked for (Similar, Whole day).
    case results(FeedModel.Source)
}

/// The People tab's path. A screen that ends by becoming another (a named group becomes its person)
/// swaps itself with `replaceTop`.
@MainActor
@Observable
final class PeopleRouter {
    var path: [PeopleRoute] = []

    func push(_ route: PeopleRoute) {
        path.append(route)
    }

    func pop() {
        if !path.isEmpty { path.removeLast() }
    }

    func replaceTop(with route: PeopleRoute) {
        pop()
        path.append(route)
    }
}

/// The People tab: the named people and the groups still to name, and the screens pushed from them.
/// The state lives in `PeopleHomeModel` and the screen models of `CullingBayCore`; the views bind to
/// them. People needs the PC and keeps nothing on the phone.
struct PeopleTab: View {
    @Environment(AppServices.self) private var services
    @State private var router = PeopleRouter()
    @State private var openedLaunchPerson = false

    var body: some View {
        NavigationStack(path: $router.path) {
            PeopleHomeView()
                .navigationDestination(for: PeopleRoute.self) { route in
                    switch route {
                    case .person(let id):
                        PersonScreen(id: id, services: services)
                    case .group(let key):
                        GroupScreen(key: key, services: services)
                    case .manage(let person):
                        ManageFacesView(person: person, services: services)
                    case .results(let source):
                        ResultsView(source: source, services: services, onOpen: { router.push(.results($0)) })
                    }
                }
        }
        .environment(router)
        .task {
            // `-CBOpenPerson`, for looking at a person in the simulator.
            guard !openedLaunchPerson, let id = LaunchOptions.openPerson else { return }
            openedLaunchPerson = true
            router.push(.person(id))
        }
    }
}
