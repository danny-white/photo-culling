import CullingBayCore
import SwiftUI

/// What the (i) sheet is asked about: one photo, by id, and its file name for the title.
struct PhotoInfoTarget: Identifiable, Equatable {
    let id: Int
    let file: String
}

/// The (i) button of the Cull card and the burst picker. It only opens the sheet, so it decides,
/// swipes and zooms nothing. Its tap target is 44 pt square whatever it sits beside, and `iconAlignment`
/// says where in that square the icon is drawn, so a caller can keep the icon level with a line of
/// text while the target reaches away from what it must not cover.
struct PhotoInfoButton: View {
    var iconAlignment = Alignment.center
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.body)
                .frame(width: 44, height: 44, alignment: iconAlignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo details")
    }
}

/// A photo's camera details: ISO, shutter, aperture, lens, size, when and where. They come from
/// the PC when the sheet opens (`CullingBayClient.info`) and are never saved on the phone. It opens
/// at the medium detent and can be pulled up to large. Nothing leaves the phone but that one
/// request, the faces in the photo (the People section, which can put a wrong name right) and Open
/// in Maps, which only happens on a tap.
@MainActor
struct PhotoInfoSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let target: PhotoInfoTarget
    @State private var phase = Phase.loading
    /// Counts Try again, so the load starts over.
    @State private var attempt = 0
    /// The faces in the photo, for the People section. Made when the sheet opens.
    @State private var faces: PhotoFacesModel?
    /// The face "This is…" was chosen for, and the person who already has the name typed for it.
    @State private var assigning: PhotoFace?
    @State private var assigningTaken: (face: PhotoFace, existing: Person)?

    private enum Phase {
        case loading
        case loaded(PhotoInfo)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(target.file)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: attempt) { await load() }
        .task {
            let model = PhotoFacesModel(photoID: target.id, client: services.client)
            faces = model
            await model.load()
        }
        .sheet(item: $assigning) { face in
            PersonPickerSheet(title: "Who is this?", allowsNew: true, services: services) { choice in
                assign(face, choice)
            }
        }
        .alert(
            "“\(assigningTaken?.existing.name ?? "")” is already someone",
            isPresented: Binding(get: { assigningTaken != nil }, set: { if !$0 { assigningTaken = nil } }),
            presenting: assigningTaken
        ) { taken in
            Button("This is \(taken.existing.name)") {
                Task { await faces?.isThis(taken.face, person: taken.existing) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let info):
            details(info)
        }
    }

    // MARK: Loaded

    private func details(_ info: PhotoInfo) -> some View {
        Form {
            if let summary = PhotoInfoFormat.summary(info) {
                Section {
                    Text(summary)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The Exposure rows below say the same, one at a time.
                        .accessibilityHidden(true)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
            }
            if let faces {
                PhotoPeopleSection(model: faces, onChoose: { assigning = $0 })
            }
            ForEach(PhotoInfoFormat.sections(info)) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                    if section.title == "Place", let gps = info.gps {
                        Button("Open in Maps") { openURL(Self.mapsURL(gps, file: info.file)) }
                    }
                }
            }
        }
    }

    /// Apple Maps at the photo's position, with the file name as the pin's name.
    static func mapsURL(_ gps: PhotoInfo.Coordinates, file: String) -> URL {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let name = file.addingPercentEncoding(withAllowedCharacters: safe) ?? ""
        let position = String(format: "%.6f,%.6f", gps.latitude, gps.longitude)
        return URL(string: "https://maps.apple.com/?ll=\(position)&q=\(name)") ?? URL(string: "https://maps.apple.com/")!
    }

    // MARK: People

    /// Says who a face is: someone Danny picked, or a new name.
    private func assign(_ face: PhotoFace, _ choice: PersonPickerModel.Choice) {
        switch choice {
        case .person(let person):
            Task { await faces?.isThis(face, person: person) }
        case .new(let name):
            Task {
                if case .taken(let existing)? = await faces?.isThisNew(face, named: name) {
                    assigningTaken = (face, existing)
                }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        phase = .loading
        do {
            let info = try await services.client.info(id: target.id)
            guard !Task.isCancelled else { return }
            phase = .loaded(info)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(PhotoInfoFormat.failure(error))
        }
    }
}
