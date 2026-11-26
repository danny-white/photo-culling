import CullingBayCore
import SwiftUI

/// "Is this Alex?": a grid of large face crops that may be one person. Every face counts as yes; a tap
/// puts a red ✕ on it (no), and "None are Alex" puts one on every face at once (then "Clear all" takes
/// them off). Confirm sends the batch and shows the next until none are left. Unnamed groups that look
/// like them come first, each with its own Yes and No. State lives in `ReviewModel`.
struct ReviewSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReviewModel
    /// Called as the sheet goes away, with the person as the server last said, so their screen shows
    /// the new counts.
    let onFinish: (Person) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    init(person: Person, services: AppServices, onFinish: @escaping (Person) -> Void) {
        self.onFinish = onFinish
        _model = State(initialValue: ReviewModel(person: person, client: services.client))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Review")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDragIndicator(.visible)
        .task { await model.load() }
        .onDisappear { onFinish(model.person) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            done
        case .reviewing:
            reviewing
        }
    }

    // MARK: Done

    private var done: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("All done").font(.title3.bold())
            if model.confirmedTotal + model.removedTotal > 0 {
                Text("\(model.confirmedTotal) confirmed as \(model.person.name), \(model.removedTotal) not.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("No suggestions for \(model.person.name) right now.").foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Reviewing

    private var reviewing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.title).font(.title2.bold())
                if !model.faces.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Every face counts as \(model.person.name). Tap the ones that are not.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        markAllButton
                    }
                }
                ForEach(model.groups) { group in
                    groupRow(group)
                }
                if !model.faces.isEmpty {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.faces) { face in
                            faceCell(face)
                        }
                    }
                }
                if !model.message.isEmpty {
                    Text(model.message).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            if !model.faces.isEmpty { confirmBar }
        }
    }

    /// "None are Alex" puts the ✕ on every face of the batch; once every face has one it reads "Clear all"
    /// and takes them off. Nothing is sent until Confirm.
    private var markAllButton: some View {
        let allNo = model.allNo
        let name = model.person.name
        let title: String = allNo ? "Clear all" : "None are \(name)"
        let spoken: String = allNo ? "Clear all, every face counts as \(name) again" : "None of these faces are \(name)"
        return Button {
            model.markAll(no: !allNo)
        } label: {
            Label(title, systemImage: allNo ? "arrow.uturn.backward" : "xmark.circle")
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(allNo ? Color.accentColor : Color.red)
        .disabled(model.isWorking)
        .accessibilityLabel(spoken)
    }

    private func groupRow(_ group: FaceGroup) -> some View {
        HStack(spacing: 10) {
            FaceCircle(face: group.cover).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Might be \(model.person.name)").font(.subheadline.weight(.semibold))
                Text(PeopleFormat.groupCaption(group)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("No") { Task { await model.answer(group: group, yes: false) } }
                .buttonStyle(.bordered)
            Button("Yes") { Task { await model.answer(group: group, yes: true) } }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .disabled(model.isWorking)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func faceCell(_ face: FaceSuggestion) -> some View {
        let isNo = model.isNo(face.id)
        return Button { model.toggle(face.id) } label: {
            FaceCircle(face: face.id, size: .large)
                .opacity(isNo ? 0.45 : 1)
                .overlay {
                    if isNo {
                        Image(systemName: "xmark")
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(Color.red, in: Circle())
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Face \(face.id)")
        .accessibilityValue(isNo ? "Not \(model.person.name)" : model.person.name)
        .accessibilityHint("Double tap to switch")
    }

    private var confirmBar: some View {
        VStack(spacing: 6) {
            if model.moreAfterThis > 0 {
                Text("\(model.moreAfterThis) more after these").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await model.confirm() }
            } label: {
                Text(PeopleFormat.reviewConfirm(yes: model.yesCount, no: model.noCount, name: model.person.name))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
