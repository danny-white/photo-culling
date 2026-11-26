import CullingBayCore
import SwiftUI

/// One group nobody has named: its picture, how many photos and days, a question when it looks like
/// a named person ("Is this Alex?"), a way to name it, a way to say it is no one Danny knows, and its
/// photos as a results screen. State lives in `GroupModel`; the photos in `FeedModel` over `.group`.
struct GroupScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(PeopleRouter.self) private var router
    let key: Int
    @State private var model: GroupModel
    @State private var naming = false
    @State private var confirmsHide = false
    /// The person who already has the name Danny typed: offered "Add to …?".
    @State private var nameTakenBy: Person?

    init(key: Int, services: AppServices) {
        self.key = key
        let people = services.people
        _model = State(initialValue: GroupModel(
            key: key, group: people.group(key: key), maybeDeclined: people.isMaybeDeclined(forGroup: key),
            client: services.client, onDecline: { [people] in people.declineMaybe(forGroup: $0) }))
    }

    var body: some View {
        ResultsView(
            source: .group(key), services: services, showsHeader: false,
            onOpen: { router.push(.results($0)) }
        ) {
            header
        }
        .task { await model.load() }
        .onChange(of: model.ending) { _, ending in
            switch ending {
            case .named(let person): router.replaceTop(with: .person(person.id))
            case .hidden: router.pop()
            case nil: break
            }
        }
        .sheet(isPresented: $naming) {
            PersonPickerSheet(title: "Who is this?", allowsNew: true, services: services) { choice in
                switch choice {
                case .person(let person):
                    Task { await model.add(to: PersonRef(id: person.id, name: person.name)) }
                case .new(let name):
                    Task {
                        if case .taken(let existing) = await model.name(name) { nameTakenBy = existing }
                    }
                }
            }
        }
        .alert(
            "“\(nameTakenBy?.name ?? "")” is already someone",
            isPresented: Binding(get: { nameTakenBy != nil }, set: { if !$0 { nameTakenBy = nil } }),
            presenting: nameTakenBy
        ) { existing in
            Button("Add to \(existing.name)") {
                Task { await model.add(to: PersonRef(id: existing.id, name: existing.name)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { existing in
            Text("Add these photos to \(existing.name)?")
        }
        .confirmationDialog("Hide this group?", isPresented: $confirmsHide, titleVisibility: .visible) {
            Button("Not someone I know", role: .destructive) { Task { await model.hide() } }
        } message: {
            Text("Its faces are hidden everywhere in the app. The photos stay in the library.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            WorkingOfflineBar()
            if case .failed(let message) = model.phase {
                VStack(spacing: 12) {
                    Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 24)
            } else {
                FaceCircle(face: model.cover, size: .large)
                    .frame(width: 120, height: 120)
                    .padding(.top, 8)
                Text("Not named yet").font(.title2.bold())
                if !model.caption.isEmpty {
                    Text(model.caption).font(.subheadline).foregroundStyle(.secondary)
                }
                if let question = model.question { questionRow(question) }
                Button { naming = true } label: {
                    Label("Add name", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isWorking)
                .padding(.top, 4)
                Button("Not someone I know", role: .destructive) { confirmsHide = true }
                    .font(.subheadline)
                    .disabled(model.isWorking)
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
        .padding(.bottom, 12)
    }

    private func questionRow(_ question: String) -> some View {
        HStack(spacing: 10) {
            Text(question).font(.headline)
            Spacer(minLength: 0)
            Button("No") { Task { await model.declineMaybe() } }
                .buttonStyle(.bordered)
            Button("Yes") { Task { await model.confirmMaybe() } }
                .buttonStyle(.borderedProminent)
        }
        .disabled(model.isWorking)
        .padding(12)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 4)
    }
}
