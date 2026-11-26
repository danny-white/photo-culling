import CullingBayCore
import SwiftUI

/// The People tab's first screen: a grid of the named people, then a grid of the groups nobody
/// has named yet, with a line while faces are still being found. State lives in `PeopleHomeModel`.
struct PeopleHomeView: View {
    @Environment(AppServices.self) private var services
    @Environment(PeopleRouter.self) private var router

    private var model: PeopleHomeModel { services.people }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    var body: some View {
        @Bindable var model = services.people
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                WorkingOfflineBar()
                if showsUnreachable {
                    UnreachableBanner(hasSavedDays: false)
                }
                content
            }
            .padding(.horizontal, 12)
        }
        .refreshable {
            await services.link.checkNow()
            await model.refresh()
        }
        .navigationTitle("People")
        .searchable(
            text: $model.filter, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search names")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { services.showsSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .task { await model.load() }
        // Back from a person or a group, whose names and counts may have changed.
        .onAppear {
            if model.phase == .loaded { Task { await model.refresh() } }
        }
        // A list that failed for want of the PC loads again once the PC can be reached.
        .onChange(of: services.link.recoveries) {
            guard case .failed = model.phase else { return }
            Task { await model.load() }
        }
    }

    /// The PC cannot be reached (and Work offline is off): the screen says so, with Try now.
    private var showsUnreachable: Bool {
        let link = services.link
        return !link.isWorkingOffline && link.state == .unreachable
    }

    // MARK: Phases

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
        if let problem = model.refreshError {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        if let progress = model.progress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
        if let empty = model.emptyMessage {
            Text(empty)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.horizontal, 24)
        } else {
            people
            groups
        }
    }

    // MARK: People

    @ViewBuilder
    private var people: some View {
        if !model.visiblePeople.isEmpty || model.noPeopleHint != nil {
            sectionLabel("People")
            if let hint = model.noPeopleHint {
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.visiblePeople) { person in
                    personCell(person)
                }
            }
        }
    }

    private func personCell(_ person: Person) -> some View {
        Button { router.push(.person(person.id)) } label: {
            VStack(spacing: 4) {
                FaceCircle(face: person.cover)
                    .overlay(alignment: .topTrailing) {
                        // Suggestions to review.
                        if person.suggestions > 0 {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        }
                    }
                Text(person.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(PeopleFormat.personCaption(person))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(person.name), \(PeopleFormat.personCaption(person))")
        .accessibilityValue(person.suggestions > 0 ? PeopleFormat.reviewTitle(person.suggestions) : "")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Not named yet

    @ViewBuilder
    private var groups: some View {
        if !model.visibleGroups.isEmpty {
            sectionLabel("Not named yet")
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.visibleGroups) { group in
                    groupCell(group)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func groupCell(_ group: FaceGroup) -> some View {
        Button { router.push(.group(group.key)) } label: {
            VStack(spacing: 4) {
                FaceCircle(face: group.cover)
                if let maybe = group.maybe {
                    Text("\(maybe.name)?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                Text(PeopleFormat.groupCaption(group))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.maybe.map { "Maybe \($0.name)" } ?? "Not named yet")
        .accessibilityValue(PeopleFormat.groupCaption(group))
        .accessibilityAddTraits(.isButton)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
