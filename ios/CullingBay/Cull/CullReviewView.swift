import CullingBayCore
import SwiftUI

/// The end-of-day review: the counts, the budget, where the decisions have got to in Lightroom,
/// the rejects, and Send. Mirrors `vSummary` in `app.js`. The big view and rescue for the
/// rejects, dropping a stack over budget, and Start over come in phase 4, so the lists only show.
struct CullReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: CullSessionModel

    var body: some View {
        let summary = session.summary
        VStack(spacing: 0) {
            // A day with no photos has no cards to go back to.
            CullDayHeader(
                title: session.title, backTitle: session.stacks.isEmpty ? nil : "Cards",
                onBack: { session.backToCards() }
            ) {
                Text(summary.subtitle)
            }
            CullOfflineBanner(queue: session.queue)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content(summary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .overlay(alignment: .bottom) {
                CullToastView(session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            footer(summary)
        }
        // The receipts: which decisions Lightroom has taken. It waits for the taps to be saved first.
        .task { await session.refresh() }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ summary: CullSummary) -> some View {
        if let problem = session.refreshError {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(Color.yellow)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
        }
        if let text = summary.daySummary {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .padding(.horizontal, 4)
        }
        counts(summary)
        if let heading = summary.budgetHeading {
            sectionLabel(heading)
        }
        if let note = summary.budgetNote {
            noteText(note)
        }
        if !summary.lightroomLines.isEmpty {
            sectionLabel("Lightroom")
            ForEach(Array(summary.lightroomLines.enumerated()), id: \.offset) { _, line in
                noteText(line)
            }
        }
        if !summary.won.isEmpty {
            sectionLabel("Your Lightroom flag won")
            grid {
                ForEach(summary.won) { won in
                    CullReviewThumb(frame: won.frame, label: won.label, style: .won)
                }
            }
            if let note = summary.wonNote {
                noteText(note)
            }
        }
        if summary.rejectsFromBursts.isEmpty && summary.rejectsOutright.isEmpty {
            noteText("No rejects today.")
        } else {
            if !summary.rejectsFromBursts.isEmpty {
                sectionLabel("From bursts · similar frame kept")
                rejectGrid(summary.rejectsFromBursts)
            }
            if !summary.rejectsOutright.isEmpty {
                sectionLabel("Rejected outright")
                rejectGrid(summary.rejectsOutright)
            }
        }
    }

    private func counts(_ summary: CullSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 140 : 72), spacing: 6)], spacing: 6) {
            CullCountTile(value: summary.kept, label: "Kept")
            CullCountTile(value: summary.hero, label: "Hero")
            CullCountTile(value: summary.rejected, label: "Rejected")
            CullCountTile(value: summary.unflagged, label: "Unflagged")
        }
        .padding(.top, 6)
    }

    private func rejectGrid(_ frames: [Frame]) -> some View {
        grid {
            ForEach(frames) { frame in
                CullReviewThumb(frame: frame, label: nil, style: .rejected)
            }
        }
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            content()
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

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
    }

    // MARK: Footer

    private func footer(_ summary: CullSummary) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button("Back to days") { dismiss() }
                .buttonStyle(CullFooterStyle(isPrimary: false))
            Button { Task { await session.send() } } label: {
                if session.isSending {
                    ProgressView().tint(.black)
                } else {
                    Text(summary.sendLabel)
                }
            }
            .buttonStyle(CullFooterStyle(isPrimary: true))
            .disabled(!summary.canSend || session.isSending)
            .accessibilityLabel(session.isSending ? "Sending" : summary.sendLabel)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color.black)
    }
}

/// A number over a word: how many frames were kept, rejected and so on.
private struct CullCountTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.title, design: .default).weight(.heavy))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(CullStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}

/// One frame in a review list. A reject is dimmed with a red cross; a frame whose Lightroom flag
/// won shows what that flag was.
private struct CullReviewThumb: View {
    enum Style {
        case rejected, won
    }

    @Environment(AppServices.self) private var services
    let frame: Frame
    let label: String?
    let style: Style

    var body: some View {
        Color.black
            .aspectRatio(3 / 2, contentMode: .fit)
            .overlay {
                RemoteImage(url: services.client.imageURL(id: frame.id, size: .thumb))
                    .opacity(style == .rejected ? 0.55 : 0.8)
            }
            .overlay(alignment: .topTrailing) {
                if style == .rejected {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 17, height: 17)
                        .background(Color.red, in: Circle())
                        .padding(3)
                }
            }
            .overlay(alignment: .bottom) {
                if let label {
                    Text(label)
                        .font(.system(size: 9.5, weight: .semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch style {
        case .rejected: "\(frame.file), rejected"
        case .won: "\(frame.file), \(label ?? "your Lightroom flag won")"
        }
    }
}

private struct CullFooterStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(isPrimary ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 10)
            .background(
                isPrimary ? Color.white : Color(.systemGray5), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.3))
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
    }
}
