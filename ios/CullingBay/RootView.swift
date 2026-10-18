import SwiftUI

/// Two tabs in one app (decision N15).
struct RootView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var services = services
        TabView {
            GalleryTab()
                .id(services.generation)
                .tabItem { Label("Gallery", systemImage: "photo.on.rectangle") }
            CullTabView()
                .tabItem { Label("Cull", systemImage: "rectangle.stack") }
        }
        .sheet(isPresented: $services.showsSettings) {
            SettingsView(url: services.serverURL)
        }
    }
}
