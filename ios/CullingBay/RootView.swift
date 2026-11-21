import SwiftUI

/// Three tabs in one app: Gallery and Cull (decision N15), and Practice.
struct RootView: View {
    private enum Tab {
        case gallery, cull, practice
    }

    @Environment(AppServices.self) private var services
    @State private var tab = LaunchOptions.startsOnPractice
        ? Tab.practice : LaunchOptions.startsOnCull ? Tab.cull : Tab.gallery

    var body: some View {
        @Bindable var services = services
        TabView(selection: $tab) {
            GalleryTab()
                .id(services.generation)
                .tabItem { Label("Gallery", systemImage: "photo.on.rectangle") }
                .tag(Tab.gallery)
            CullTabView()
                .id(services.generation)
                .tabItem { Label("Cull", systemImage: "rectangle.stack") }
                .tag(Tab.cull)
            PracticeTab()
                .id(services.generation)
                .tabItem { Label("Practice", systemImage: "slider.horizontal.3") }
                .tag(Tab.practice)
        }
        .sheet(isPresented: $services.showsSettings) {
            SettingsView(url: services.serverURL)
        }
    }
}
