import SwiftUI

/// Culling arrives in phase 2. Until then the web version does it (decision N6).
struct CullTabView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL

    private var webURL: URL? {
        URL(string: services.serverURL.absoluteString + "/m/")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Culling comes to the app in phase 2. Until then the web version does all of it.")
                    if let webURL {
                        Button("Open culling in Safari") { openURL(webURL) }
                    }
                }
                Section("Server") {
                    LabeledContent("Address", value: services.serverURL.absoluteString)
                    Button("Change server…") { services.showsSettings = true }
                }
            }
            .navigationTitle("Cull")
        }
    }
}
