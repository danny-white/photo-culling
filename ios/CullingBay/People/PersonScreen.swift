import CullingBayCore
import SwiftUI

/// One person: a big circle, their name and photo count, a banner to review suggestions (and, when the
/// PC has doubts about faces it filed as them, a quieter one to check those), and their
/// photos as a results screen (so the viewer and Save work as they do anywhere). The menu renames
/// them, merges them into someone, opens Manage faces or removes the name. State lives in
/// `PersonModel`; the photos in `FeedModel` over `.person`.
///
/// A long press on a photo offers "Not <name>" (they come off that photo at once, and a toast with Undo
/// stays a few seconds) and "Show faces in this photo" (the (i) sheet, to pick when it holds several
/// people). Select puts a "Not <first name>" button in the selection bar that does the same for every
/// selected photo in one go: one toast, with one Undo for all of them, saying how many photos it was and
/// how many of the selected ones didn't have their face (those stay).
struct PersonScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(PeopleRouter.self) private var router
    let id: Int
    @State private var model: PersonModel
    /// Which review sheet is open: "Is this Alex?" or "Maybe not Alex?".
    @State private var reviewing: ReviewTarget?
    @State private var merging = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmsRemove = false
    /// The person who already has the name Danny tried to give.
    @State private var nameTakenBy: Person?
    /// The photo whose faces the (i) sheet is open for, from a tile's long-press menu.
    @State private var detailsFor: PhotoInfoTarget?
    @State private var toast: PersonToast?
    @State private var toastCount = 0

    init(id: Int, services: AppServices) {
        self.id = id
        _model = State(initialValue: PersonModel(
            id: id, person: services.people.person(id: id), client: services.client))
    }

    var body: some View {
        ResultsView(
            source: .person(id, name: model.name), services: services, showsHeader: false,
            reloadKey: model.feedKey,
            tileMenu: { photo, feed in AnyView(tileMenu(photo, feed)) },
            selectionActions: { feed in AnyView(notThemButton(feed)) },
            onOpen: { router.push(.results($0)) }
        ) {
            header
        }
        .overlay(alignment: .bottom) {
            PersonToastView(toast: toast) { toast = nil }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
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
        // Faces fixed in the sheet may have taken them off the photo: read the person again, and the grid
        // reads itself again if their count moved.
        .sheet(item: $detailsFor, onDismiss: { Task { await model.load() } }) { PhotoInfoSheet(target: $0) }
        .sheet(item: $reviewing, onDismiss: { Task { await model.load() } }) { target in
            ReviewSheet(person: target.person, kind: target.kind, services: services) { model.update($0) }
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
                if let person = model.person {
                    if let banner = model.reviewBanner {
                        reviewBannerButton(
                            banner, icon: "questionmark.circle.fill", fill: Color.orange.opacity(0.18),
                            ink: Color.orange, target: ReviewTarget(person: person, kind: .suggestions),
                            hint: "Answers “Is this \(person.name)?” for faces that may be them")
                    }
                    if let banner = model.checkBanner {
                        reviewBannerButton(
                            banner, icon: "person.crop.circle.badge.questionmark",
                            fill: Color(.secondarySystemFill), ink: Color.primary,
                            target: ReviewTarget(person: person, kind: .doubts),
                            hint: "Checks the faces filed as \(person.name) that the PC is least sure of")
                    }
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

    /// A full-width banner that opens the review sheet: orange for suggestions, quieter for the faces the PC
    /// filed as them but is least sure of.
    private func reviewBannerButton(
        _ text: String, icon: String, fill: Color, ink: Color, target: ReviewTarget, hint: String
    ) -> some View {
        Button { reviewing = target } label: {
            HStack {
                Image(systemName: icon)
                Text(text).fontWeight(.semibold)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(ink)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityHint(hint)
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

    // MARK: A photo's long-press menu

    private func tileMenu(_ photo: Photo, _ feed: FeedModel) -> some View {
        Group {
            Button("Not \(model.name)", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                notThem(photo, in: feed)
            }
            .disabled(model.isWorking)
            Button("Show faces in this photo", systemImage: "info.circle") {
                detailsFor = PhotoInfoTarget(id: photo.id, file: photo.file)
            }
        }
    }

    /// Takes them off this photo (or the burst the tile stands for). There is no confirm: the toast's
    /// Undo is the way back.
    private func notThem(_ photo: Photo, in feed: FeedModel) {
        let name = model.name
        Task {
            switch await model.removeFromPhoto(photo, in: feed) {
            case .removed(let removal):
                show(PeopleFormat.removedFromPhoto(name)) { undo(removal, in: feed) }
            case .notInPhoto:
                show(PeopleFormat.notInPhoto(name))
            case .failed:
                if !model.message.isEmpty { show(model.message) }
            }
        }
    }

    // MARK: The selection bar's button

    /// "Not Alex" for every selected photo. The label is short, the first word of the name, so it fits the
    /// bar beside Clear and Save to phone; VoiceOver says the full name.
    private func notThemButton(_ feed: FeedModel) -> some View {
        let firstWord = model.name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? model.name
        return Button(role: .destructive) {
            notThemSelected(in: feed)
        } label: {
            Label("Not \(firstWord)", systemImage: "person.crop.circle.badge.xmark").lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(Color.red)
        .disabled(feed.selected.isEmpty || model.isWorking)
        .accessibilityLabel("Not \(model.name)")
    }

    /// Takes them off every selected photo (or the bursts the tiles stand for). There is no confirm: the
    /// toast's Undo is the way back. When it worked the selection ends; when none of the photos had their
    /// face it stays, so the choice can be changed.
    private func notThemSelected(in feed: FeedModel) {
        let name = model.name
        let photos = feed.selectedPhotos
        Task {
            switch await model.removeFromPhotos(photos, in: feed) {
            case .removed(let removal):
                feed.endSelection()
                let text = PeopleFormat.removedFromPhotos(
                    name, photos: removal.photos.count, skipped: removal.skippedTiles)
                show(text) { undo(removal, in: feed) }
            case .notInPhoto:
                show(PeopleFormat.notInPhotos(name))
            case .failed:
                if !model.message.isEmpty { show(model.message) }
            }
        }
    }

    private func undo(_ removal: PersonModel.PhotoRemoval, in feed: FeedModel) {
        Task {
            if !(await model.undoRemoval(removal, in: feed)), !model.message.isEmpty { show(model.message) }
        }
    }

    private func show(_ text: String, undo: (() -> Void)? = nil) {
        toastCount += 1
        toast = PersonToast(id: toastCount, text: text, undo: undo)
    }

    private func rename() {
        let text = renameText
        Task {
            if case .taken(let existing) = await model.rename(to: text) { nameTakenBy = existing }
        }
    }
}

/// What the review sheet is open for: the person, and whether it asks about faces that may be them or about
/// faces already filed as them.
private struct ReviewTarget: Identifiable {
    let person: Person
    let kind: ReviewModel.Kind

    var id: Int { person.id * 2 + (kind == .doubts ? 1 : 0) }
}
