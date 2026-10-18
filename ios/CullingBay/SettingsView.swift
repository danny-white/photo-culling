import CullingBayCore
import SwiftUI

/// Edits the server address, checks that it is a plausible URL, and asks it for `/m/api/days`.
@MainActor
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var model: ServerSettingsModel

    init(url: URL) {
        _model = State(initialValue: ServerSettingsModel(url: url))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.82.57.4:8000", text: $model.text)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use the default") { model.text = GalleryDefaults.serverURL.absoluteString }
                } header: {
                    Text("Server address")
                } footer: {
                    Text("The photo server on your PC, reached over Tailscale. The PC must be on and in Ubuntu.")
                }
                Section {
                    Button("Check connection") { Task { await model.check() } }
                        .disabled(model.validURL == nil || model.isChecking)
                    if model.isChecking { ProgressView() }
                    if !model.status.isEmpty { Text(model.status) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let url = model.validURL { services.setServer(url) }
                        dismiss()
                    }
                    .disabled(model.validURL == nil)
                }
            }
        }
    }
}
