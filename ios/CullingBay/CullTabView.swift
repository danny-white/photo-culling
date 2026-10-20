import SwiftUI
import UIKit

/// The Cull tab: the days list, and the day pushed from it. The state lives in `CullDaysModel`
/// and `CullSessionModel`; the views here bind to them (decision N15).
struct CullTabView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = CullRouter()
    @State private var openedLaunchDay = false

    var body: some View {
        NavigationStack(path: $router.path) {
            CullDaysView()
                .navigationDestination(for: CullDayRoute.self) { route in
                    CullDayView(session: route.session)
                }
        }
        .environment(router)
        .task {
            // `-CBOpenDay`, for looking at a day in the simulator.
            guard !openedLaunchDay, let day = LaunchOptions.openDay else { return }
            openedLaunchDay = true
            router.open(day, services: services)
        }
        .onAppear(perform: updateScreenAwake)
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: router.isDayOpen) { updateScreenAwake() }
        .onChange(of: scenePhase) { updateScreenAwake() }
    }

    /// The screen stays on while a day is open, so the phone does not lock between taps.
    private func updateScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = router.isDayOpen && scenePhase == .active
    }
}
