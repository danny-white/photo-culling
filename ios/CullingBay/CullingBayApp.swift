import CullingBayCore
import SwiftUI

@main
struct CullingBayApp: App {
    @State private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .onChange(of: scenePhase) { _, phase in
                    // Timing marks are queued in memory; send them when the app is put away.
                    if phase == .background {
                        let perf = services.perf
                        Task { await perf.flush() }
                    }
                }
        }
    }
}
