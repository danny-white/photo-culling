import SwiftUI

/// Two tabs in one app (decision N15).
struct RootView: View {
    private enum Tab {
        case gallery, cull
    }

    @Environment(AppServices.self) private var services
    @State private var tab = LaunchOptions.startsOnCull ? Tab.cull : Tab.gallery

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
        }
        .sheet(isPresented: $services.showsSettings) {
            SettingsView(url: services.serverURL)
        }
    }
}
