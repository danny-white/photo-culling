import CullingBayCore
import SwiftUI

/// One challenge pushed on the Practice tab's navigation stack. The detail looks the challenge
/// up by id, so it shows the list as it is after a save or a reload. The detail pushes its pair's
/// other half with the same route.
struct PracticeRoute: Hashable {
    let id: String
}

/// The Practice tab: the editing challenges in Waiting, Done and Skipped, and the challenge
/// pushed from a row. The state lives in `PracticeModel`; this mirrors `listView` in
/// `practice.js`.
struct PracticeTab: View {
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [PracticeRoute] = []
    @State private var openedLaunchChallenge = false

    private var model: PracticeModel { services.practice }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 12)
            }
            .refreshable { await model.load() }
            .navigationTitle("Practice")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { services.showsSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(for: PracticeRoute.self) { route in
                PracticeDetailView(id: route.id, note: model.draft(for: route.id))
            }
            .task {
                await model.load()
                await model.sendUnsavedNotes()
                openLaunchChallenge()
            }
            // Back from the background: a note typed with no connection goes now, if it can.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.sendUnsavedNotes() }
            }
        }
    }

    /// `-CBOpenChallenge`, for looking at a challenge in the simulator.
    private func openLaunchChallenge() {
        guard !openedLaunchChallenge, model.hasLoaded, let id = LaunchOptions.openChallenge else { return }
        openedLaunchChallenge = true
        if model.challenge(id: id) != nil { path.append(PracticeRoute(id: id)) }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.message.isEmpty {
            PracticeMessageView(text: model.message)
                .padding(.top, 8)
        }
        if model.missing > 0 {
            Text(missingText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.horizontal, 4)
        }
        if !model.hasLoaded {
            if model.message.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        } else if model.challenges.isEmpty {
            Text("No practice challenges yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else {
            section("Waiting", model.waitingGroups)
            section("Done", model.doneGroups)
            section("Skipped", model.skippedGroups)
        }
    }

    private var missingText: String {
        let count = model.missing
        let subject = count == 1 ? "1 challenge photo is" : "\(count) challenge photos are"
        return "\(subject) no longer in the library."
    }

    /// The count is the challenges listed, so a pair counts two.
    @ViewBuilder
    private func section(_ title: String, _ groups: [PracticeGroup]) -> some View {
        if !groups.isEmpty {
            sectionLabel("\(title) · \(groups.reduce(0) { $0 + $1.count })")
            ForEach(groups) { group in
                PracticeGroupView(group: group)
                    .padding(.bottom, 8)
            }
        }
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

// MARK: Row

/// A challenge and the on-the-go versions joined under it, in one card. Tapping a row opens that
/// challenge. A challenge with no companion is a card of one row.
private struct PracticeGroupView: View {
    let group: PracticeGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: PracticeRoute(id: group.parent.id)) {
                PracticeRowView(challenge: group.parent, inPair: !group.companions.isEmpty)
            }
            .buttonStyle(.plain)
            ForEach(group.companions) { companion in
                Divider().padding(.leading, 94)
                NavigationLink(value: PracticeRoute(id: companion.id)) {
                    PracticeCompanionRowView(challenge: companion)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// One challenge in the list (`challengeCard` in `practice.js`): a square thumbnail, the title,
/// the level and time, and the tools as chips. A Needs Desktop one says so. In a pair it also
/// shows Done or Skipped, since the two rows can differ.
private struct PracticeRowView: View {
    @Environment(AppServices.self) private var services
    let challenge: PracticeChallenge
    let inPair: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: services.client.imageURL(id: challenge.photo.id, size: .thumb))
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(challenge.title)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if inPair, let finished = PracticeFormat.finishedTag(challenge) {
                        PracticeTag(text: finished)
                    }
                    if challenge.wasDownloaded {
                        PracticeTag(text: "Downloaded")
                    }
                }
                HStack(spacing: 6) {
                    HStack(spacing: 0) {
                        Text(challenge.level.title).foregroundStyle(challenge.level.color)
                        Text(" · " + PracticeFormat.minutesText(challenge)).foregroundStyle(.secondary)
                    }
                    .font(.caption.weight(.semibold))
                    if challenge.needsDesktop {
                        PracticeTag(text: PracticeFormat.needsDesktopTag, accent: true)
                    }
                }
                if !challenge.tools.isEmpty {
                    PracticeFlowLayout(spacing: 4) {
                        ForEach(Array(challenge.tools.enumerated()), id: \.offset) { _, tool in
                            PracticeChip(text: tool)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A challenge's on-the-go version under its parent: no thumbnail, since it is the same photo.
/// It has its own status, so it shows Done, Skipped or Downloaded.
private struct PracticeCompanionRowView: View {
    let challenge: PracticeChallenge

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(PracticeFormat.onTheGoLabel)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let status = PracticeFormat.statusTag(challenge) {
                    PracticeTag(text: status)
                }
            }
            HStack(spacing: 0) {
                Text(challenge.level.title).foregroundStyle(challenge.level.color)
                Text(" · " + PracticeFormat.companionMinutesText(challenge)).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            if !challenge.tools.isEmpty {
                PracticeFlowLayout(spacing: 4) {
                    ForEach(Array(challenge.tools.enumerated()), id: \.offset) { _, tool in
                        PracticeChip(text: tool)
                    }
                }
            }
        }
        .padding(.leading, 94)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private extension PracticeLevel {
    /// Easy green, medium yellow, hard red, as on the web page.
    var color: Color {
        switch self {
        case .easy: .green
        case .medium: .yellow
        case .hard: .red
        }
    }
}

// MARK: Small parts

/// A tool the challenge allows.
private struct PracticeChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

/// `Downloaded`, `Done` and the like, on a row and on the detail. `Needs Desktop` is the accent
/// one, in blue.
struct PracticeTag: View {
    let text: String
    var accent = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(accent ? Color.blue : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(accent ? Color.blue.opacity(0.15) : Color(.tertiarySystemFill), in: Capsule())
    }
}

/// The model's `message`: a failed load, the server's error, or a write that did not save.
struct PracticeMessageView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Puts its views in rows left to right and starts a new row when one does not fit, for the
/// tool chips.
private struct PracticeFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let placed = arrange(proposal: proposal, subviews: subviews)
        for (subview, frame) in zip(subviews, placed.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(
        proposal: ProposedViewSize, subviews: Subviews
    ) -> (size: CGSize, frames: [CGRect]) {
        let limit = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            if x > 0, x + size.width > limit {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: widest, height: y + rowHeight), frames)
    }
}
