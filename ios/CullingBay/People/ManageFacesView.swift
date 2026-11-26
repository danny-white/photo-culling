import CullingBayCore
import SwiftUI

/// A person's faces for fixing: a grid, paged as it scrolls, with Select. The bar under a selection says
/// "Not Alex", moves the faces to someone else, or says they are not faces. A long press makes a face
/// the cover or shows its photo. Faces the PC filed by itself have a thin outline; faces Danny
/// confirmed have none. State lives in `ManageFacesModel`.
struct ManageFacesView: View {
    @Environment(AppServices.self) private var services
    @State private var model: ManageFacesModel
    @State private var moving = false
    @State private var shownPhoto: ShownPhoto?
    /// The person who already has the name Danny typed for the faces to move to.
    @State private var nameTakenBy: Person?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    init(person: Person, services: AppServices) {
        _model = State(initialValue: ManageFacesModel(person: person, client: services.client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                WorkingOfflineBar()
                content
            }
            .padding(.horizontal, 12)
        }
        .navigationTitle("Manage faces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.isSelecting ? "Done" : "Select") {
                    if model.isSelecting { model.endSelection() } else { model.beginSelection() }
                }
                .disabled(model.faces.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isSelecting { selectionBar }
        }
        .task { await model.load() }
        .sensoryFeedback(trigger: model.selected) { _, _ in .selection }
        .sheet(isPresented: $moving) {
            PersonPickerSheet(
                title: "Move to…", excluding: [model.person.id], allowsNew: true, services: services
            ) { choice in
                switch choice {
                case .person(let other):
                    Task { await model.moveSelected(to: other) }
                case .new(let name):
                    Task {
                        if case .taken(let existing) = await model.moveSelectedToNew(named: name) {
                            nameTakenBy = existing
                        }
                    }
                }
            }
        }
        .alert(
            "“\(nameTakenBy?.name ?? "")” is already someone",
            isPresented: Binding(get: { nameTakenBy != nil }, set: { if !$0 { nameTakenBy = nil } }),
            presenting: nameTakenBy
        ) { existing in
            Button("Move to \(existing.name)") { Task { await model.moveSelected(to: existing) } }
            Button("Cancel", role: .cancel) {}
        } message: { existing in
            Text("Move these faces to \(existing.name)?")
        }
        .fullScreenCover(item: $shownPhoto) { shown in
            ShownPhotoView(photo: shown.photo)
        }
    }

    // MARK: Grid

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if model.faces.isEmpty {
            Text("\(model.person.name) has no faces left.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else {
            Text("\(model.total) faces. The ones with an outline were filed by the PC, least sure first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.faces) { face in
                    cell(face)
                }
            }
            if model.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .task { await model.loadMore() }
            }
        }
        if !model.message.isEmpty {
            Text(model.message).font(.footnote).foregroundStyle(.red).padding(.horizontal, 4)
        }
    }

    private func cell(_ face: PersonFace) -> some View {
        let isSelected = model.selected.contains(face.id)
        return Button { tapped(face) } label: {
            FaceCircle(face: face.id)
                .overlay {
                    if face.how == .auto {
                        Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                    }
                }
                .overlay {
                    if isSelected {
                        ZStack {
                            Circle().fill(Color.black.opacity(0.35))
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white, Color.accentColor)
                        }
                    } else if model.isSelecting {
                        Image(systemName: "circle")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Make cover", systemImage: "person.crop.circle") {
                Task { await model.makeCover(of: face.id) }
            }
            Button("Show photo", systemImage: "photo") { shownPhoto = ShownPhoto(photo: face.photo) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(face.how == .auto ? "Face filed by the PC" : "Face you confirmed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tapped(_ face: PersonFace) {
        if model.isSelecting {
            model.toggleSelect(face.id)
        } else {
            shownPhoto = ShownPhoto(photo: face.photo)
        }
    }

    // MARK: Selection bar

    private var selectionBar: some View {
        VStack(spacing: 8) {
            Text(model.selected.isEmpty ? "Tap faces to select them" : "\(model.selected.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(model.notTitle) { Task { await model.removeSelected() } }
                Button("Move to…") { moving = true }
                Button("Not a face", role: .destructive) { Task { await model.ignoreSelected() } }
            }
            .buttonStyle(.bordered)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .disabled(model.selected.isEmpty || model.isWorking)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// A photo to show full screen from the fix screen: its id, so the cover can load it.
struct ShownPhoto: Identifiable {
    let photo: Int
    var id: Int { photo }
}

/// One photo, as big as the screen allows, to see who a face is in. Tap anywhere to close.
struct ShownPhotoView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let photo: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            RemoteImage(
                url: services.client.imageURL(id: photo, size: .view), maxPixel: ImagePixels.view, fit: true)
                .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .padding(8)
            .accessibilityLabel("Close")
        }
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }
}
