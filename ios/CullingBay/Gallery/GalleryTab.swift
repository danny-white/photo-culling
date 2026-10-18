import CullingBayCore
import Observation
import SwiftUI

/// What the Gallery's navigation stack has pushed. The viewer's Similar and Day buttons push
/// onto it too.
@MainActor
@Observable
final class GalleryRouter {
    var path: [FeedModel.Source] = []

    func push(_ source: FeedModel.Source) {
        path.append(source)
    }
}

struct GalleryTab: View {
    @Environment(AppServices.self) private var services
    @State private var router = GalleryRouter()

    var body: some View {
        NavigationStack(path: $router.path) {
            GalleryHomeView()
                .navigationDestination(for: FeedModel.Source.self) { source in
                    ResultsView(source: source, services: services)
                }
        }
        .environment(router)
    }
}
