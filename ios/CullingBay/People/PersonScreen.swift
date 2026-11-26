import CullingBayCore
import SwiftUI

/// One person: a big circle, their name and photo count, a banner to review suggestions, and their
/// photos as a results screen (so the viewer and Save work as they do anywhere). The menu renames
/// them, merges them into someone, opens Manage faces or removes the name. State lives in
/// `PersonModel`; the photos in `FeedModel` over `.person`.
struct PersonScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(PeopleRouter.self) private var router
    let id: Int
    @State private var model: PersonModel
    @State private var reviewing: Person?
    @State private var merging = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmsRemove = false
    /// The person who already has the name Danny tried to give.
    @State private var nameTakenBy: Person?

    init(id: Int, services: AppServices) {
        self.id = id
        _model = State(initialValue: PersonModel(
            id: id, person: services.people.person(id: id), client: services.client))
    }

    var body: some View {
        ResultsView(
            source: .person(id, name: model.name), services: services, showsHeader: false,
            reloadKey: [model.person?.photos ?? 0, model.person?.faces ?? 0],
            onOpen: { router.push(.results($0)) }
        ) {
            header
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .task { await model.load() }
        .onChange(of: model.ending) { _, ending in
            switch ending {
            case .merged(let into): router.replaceTop(with: .person(into.id))
            case .deleted: router.pop()
            case nil: break
            }
        }
        .sheet(item: $reviewing, onDismiss: { Task { await model.load() } }) { person in
            ReviewSheet(person: person, services: services) { model.update($0) }
        }
        .sheet(isPresented: $merging) {
            PersonPickerSheet(
                title: "Merge \(model.name) with…", excluding: [id], allowsNew: false, services: services
            ) { choice in
                if case .person(let other) = choice { Task { await model.merge(into: other) } }
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "“\(nameTakenBy?.name ?? "")” is already someone",
            isPresented: Binding(get: { nameTakenBy != nil }, set: { if !$0 { nameTakenBy = nil } }),
            presenting: nameTakenBy
        ) { existing in
            Button("Merge into \(existing.name)") { Task { await model.merge(into: existing) } }
            Button("Cancel", role: .cancel) {}
        } message: { existing in
            Text("Merge \(model.name) into \(existing.name)? Their faces and photos join \(existing.name)’s.")
        }
        .confirmationDialog(
            "Remove the name “\(model.name)”?", isPresented: $confirmsRemove, titleVisibility: .visible
        ) {
            Button("Remove name", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("Their faces go back to their groups. The photos stay in the library.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            WorkingOfflineBar()
            switch model.phase {
            case .idle, .loading:
                ProgressView().padding(.vertical, 40)
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 24)
            case .loaded:
                FaceCircle(face: model.cover, size: .large)
                    .frame(width: 120, height: 120)
                    .padding(.top, 8)
                Text(model.name).font(.title2.bold())
                Text(model.photoCaption).font(.subheadline).foregroundStyle(.secondary)
                if let banner = model.reviewBanner, let person = model.person {
                    Button { reviewing = person } label: {
                        HStack {
                            Image(systemName: "questionmark.circle.fill")
                            Text(banner).fontWeight(.semibold)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(Color.orange)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .accessibilityHint("Answers “Is this \(person.name)?” for faces that may be them")
                }
            }
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    // MARK: Menu

    private var menu: some View {
        Menu {
            Button("Rename", systemImage: "pencil") {
                renameText = model.name
                renaming = true
            }
            Button("Merge with…", systemImage: "arrow.triangle.merge") { merging = true }
            if let person = model.person {
                Button("Manage faces", systemImage: "person.crop.rectangle.stack") {
                    router.push(.manage(person))
                }
            }
            Button("Remove name", systemImage: "trash", role: .destructive) { confirmsRemove = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(model.person == nil || model.isWorking)
        .accessibilityLabel("Person options")
    }

    private func rename() {
        let text = renameText
        Task {
            if case .taken(let existing) = await model.rename(to: text) { nameTakenBy = existing }
        }
    }
}
