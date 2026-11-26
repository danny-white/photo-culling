import CullingBayCore
import SwiftUI

/// Choosing a person, or typing a new name: the sheet for naming a group, for Move to…, for
/// Merge with… and for "This is…". State lives in `PersonPickerModel`. It tells its caller what was
/// chosen and closes; what happens next (a write, a 409 to answer) is the caller's.
struct PersonPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// Whether a name nobody has can be typed in, as a "New person" row.
    let allowsNew: Bool
    let onChoose: (PersonPickerModel.Choice) -> Void
    @State private var model: PersonPickerModel

    init(
        title: String, excluding: Set<Int> = [], allowsNew: Bool, services: AppServices,
        onChoose: @escaping (PersonPickerModel.Choice) -> Void
    ) {
        self.title = title
        self.allowsNew = allowsNew
        self.onChoose = onChoose
        _model = State(initialValue: PersonPickerModel(client: services.client, excluding: excluding))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    TextField(allowsNew ? "Type a name" : "Search names", text: $model.text)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(allowsNew ? .done : .search)
                        .onSubmit {
                            if allowsNew, let name = model.newName { choose(.new(name: name)) }
                        }
                }
                if allowsNew, let name = model.newName {
                    Section {
                        Button { choose(.new(name: name)) } label: {
                            Label("New person “\(name)”", systemImage: "plus.circle.fill")
                        }
                    }
                }
                people
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await model.load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var people: some View {
        switch model.phase {
        case .idle, .loading:
            Section { ProgressView().frame(maxWidth: .infinity) }
        case .failed(let message):
            Section {
                Text(message).foregroundStyle(.secondary)
                Button("Try again") { Task { await model.load() } }
            }
        case .loaded:
            if model.matches.isEmpty {
                // With a "New person" row showing, saying nobody is called that adds nothing.
                if !(allowsNew && model.newName != nil) {
                    Section {
                        Text(model.text.isEmpty ? "Nobody is named yet." : "No one is called that yet.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("People") {
                    ForEach(model.matches) { person in
                        Button { choose(.person(person)) } label: {
                            HStack(spacing: 12) {
                                FaceCircle(face: person.cover).frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.name).foregroundStyle(.primary)
                                    Text(PeopleFormat.personCaption(person))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
    }

    private func choose(_ choice: PersonPickerModel.Choice) {
        dismiss()
        onChoose(choice)
    }
}
