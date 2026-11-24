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
                // Taps left unsent by an earlier run go out now, and days kept on the phone are brought up to date.
                .task {
                    services.cullQueue.start()
                    services.offline.sync()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Timing marks are queued in memory; send them when the app is put away.
                    if phase == .background {
                        let perf = services.perf
                        Task { await perf.flush() }
                        // Downloads run only while the app is open.
                        services.offline.cancel()
                    }
                    // A tap that failed while the app was away is tried at once, not after the 4 s wait.
                    if phase == .active {
                        services.cullQueue.resume()
                        services.offline.sync()
                    }
                }
        }
    }
}
