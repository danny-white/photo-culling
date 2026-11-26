import CullingBayCore
import SwiftUI

/// The settings sheet. Its switches apply at once, so the sheet has only Done. The server address
/// is its own screen (`ServerAddressView`) with its own Save, because saving it starts the app
/// over on another server.
@MainActor
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CullPreferences.showAFPoint) private var showAF = false
    @AppStorage(OfflinePreferences.enabled) private var offlineEnabled = false
    @AppStorage(OfflinePreferences.limitGB) private var offlineLimit = OfflinePreferences.defaultLimitGB
    @AppStorage(OfflinePreferences.crops) private var offlineCrops = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ServerAddressView(url: services.serverURL)
                    } label: {
                        LabeledContent("Server address", value: services.serverURL.absoluteString)
                    }
                } footer: {
                    Text("The photo server on your PC, reached over Tailscale. The PC must be on and in Ubuntu.")
                }
                Section {
                    Toggle("Show the AF point", isOn: $showAF)
                } header: {
                    Text("Cull")
                } footer: {
                    Text("A yellow box where the camera focused, on the card, in the burst picker and in the 1:1 check. Changes at once.")
                }
                offlineSection
                if let version = AppVersion.label(info: Bundle.main.infoDictionary) {
                    Section {
                        LabeledContent("Version", value: version)
                    } footer: {
                        Text("The same number as on the builds page, /m/ios/ on the PC.")
                    }
                }
            }
            // Offline settings apply at once, like the AF switch: each one syncs again, after a pause.
            .onChange(of: offlineEnabled) { services.offline.settingsChanged() }
            .onChange(of: offlineLimit) { services.offline.settingsChanged() }
            .onChange(of: offlineCrops) { services.offline.settingsChanged() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Offline

    /// Keep days on the phone: the switch, how much, whether to keep the 1:1 crops, what is saved
    /// now, and the list to choose days from.
    @ViewBuilder
    private var offlineSection: some View {
        Section {
            Toggle("Keep days on this phone", isOn: $offlineEnabled)
            if offlineEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Up to \(OfflineFormat.limit(gigabytes: offlineLimit))")
                    Slider(value: $offlineLimit, in: OfflinePreferences.limitRange, step: 0.5)
                        .accessibilityLabel("Space for saved days")
                        .accessibilityValue(OfflineFormat.limit(gigabytes: offlineLimit))
                }
                Toggle("Include 1:1 focus crops", isOn: $offlineCrops)
                Text(offlineStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("Choose days") { OfflineDaysView() }
            }
        } header: {
            Text("Offline")
        } footer: {
            Text("Saved days open and can be culled with no connection to the PC. Your taps are kept and go to the PC when it can be reached. Changes at once.")
        }
    }

    private var offlineStatus: String {
        let offline = services.offline
        switch offline.state {
        case .off, .idle:
            return OfflineFormat.saved(days: offline.savedDays.count, bytes: offline.totalBytes)
        case .syncing(let title, let done, let total):
            return OfflineFormat.saving(title: title, done: done, total: total)
        case .offline:
            return "Can't reach the PC · showing saved days"
        case .failed(let message):
            return message
        }
    }
}

/// The server address: edit it, check that it is a plausible URL and that the server answers, and
/// Save. Saving starts the app over on that server (`AppServices.setServer`) and goes back to the
/// settings. Going back without Save drops the edit.
@MainActor
private struct ServerAddressView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var model: ServerSettingsModel

    init(url: URL) {
        _model = State(initialValue: ServerSettingsModel(url: url))
    }

    var body: some View {
        Form {
            Section {
                TextField("http://100.82.57.4:8000", text: $model.text)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use the default") { model.text = GalleryDefaults.serverURL.absoluteString }
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
        .navigationTitle("Server address")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
