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
                // Taps left unsent by an earlier run go out now.
                .task { services.cullQueue.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Timing marks are queued in memory; send them when the app is put away.
                    if phase == .background {
                        let perf = services.perf
                        Task { await perf.flush() }
                    }
                    // A tap that failed while the app was away is tried at once, not after the 4 s wait.
                    if phase == .active { services.cullQueue.resume() }
                }
        }
    }
}
