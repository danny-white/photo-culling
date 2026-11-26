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
                // Taps left unsent by an earlier run go out now, the PC is probed, and days kept on
                // the phone are brought up to date once it answers.
                .task { services.launch() }
                .onChange(of: scenePhase) { _, phase in
                    // Timing marks are queued in memory; send them when the app is put away.
                    if phase == .background {
                        let perf = services.perf
                        Task { await perf.flush() }
                        // Downloads run only while the app is open, and nothing polls the PC.
                        services.offline.cancel()
                        services.link.setActive(false)
                    }
                    // Back at the front, the PC is probed again. A tap that failed while the app was
                    // away is tried at once, not after the 4 s wait.
                    if phase == .active {
                        services.link.setActive(true)
                        services.cullQueue.resume()
                        services.offline.sync()
                    }
                }
        }
    }
}
