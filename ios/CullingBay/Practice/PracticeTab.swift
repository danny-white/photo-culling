import CullingBayCore
import SwiftUI

/// One challenge pushed on the Practice tab's navigation stack. The detail looks the challenge
/// up by id, so it shows the list as it is after a save or a reload.
private struct PracticeRoute: Hashable {
    let id: String
}

/// The Practice tab: the editing challenges in Waiting, Done and Skipped, and the challenge
/// pushed from a row. The state lives in `PracticeModel`; this mirrors `listView` in
/// `practice.js`.
struct PracticeTab: View {
    @Environment(AppServices.self) private var services
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
                openLaunchChallenge()
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
            section("Waiting", model.waiting)
            section("Done", model.done)
            section("Skipped", model.skipped)
        }
    }

    private var missingText: String {
        let count = model.missing
        let subject = count == 1 ? "1 challenge photo is" : "\(count) challenge photos are"
        return "\(subject) no longer in the library."
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [PracticeChallenge]) -> some View {
        if !items.isEmpty {
            sectionLabel("\(title) · \(items.count)")
            ForEach(items) { challenge in
                NavigationLink(value: PracticeRoute(id: challenge.id)) {
                    PracticeRowView(challenge: challenge)
                }
                .buttonStyle(.plain)
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

/// One challenge in the list (`challengeCard` in `practice.js`): a square thumbnail, the title,
/// the level and time, and the tools as chips.
private struct PracticeRowView: View {
    @Environment(AppServices.self) private var services
    let challenge: PracticeChallenge

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
                    if challenge.wasDownloaded {
                        PracticeTag(text: "Downloaded")
                    }
                }
                HStack(spacing: 0) {
                    Text(challenge.level.title).foregroundStyle(challenge.level.color)
                    Text(" · " + PracticeFormat.minutesText(challenge)).foregroundStyle(.secondary)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
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

/// `Downloaded`, on a row and on the detail.
struct PracticeTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
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
