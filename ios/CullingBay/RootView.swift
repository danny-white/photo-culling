import SwiftUI

/// Four tabs in one app: Gallery and Cull (decision N15), Practice, and People.
struct RootView: View {
    private enum Tab {
        case gallery, cull, practice, people
    }

    @Environment(AppServices.self) private var services
    @State private var tab = LaunchOptions.startsOnPeople
        ? Tab.people : LaunchOptions.startsOnPractice
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
            PeopleTab()
                .id(services.generation)
                .tabItem { Label("People", systemImage: "person.2") }
                .tag(Tab.people)
        }
        .sheet(isPresented: $services.showsSettings) {
            SettingsView()
        }
    }
}
