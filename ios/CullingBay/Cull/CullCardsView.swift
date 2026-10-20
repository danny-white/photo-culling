import CullingBayCore
import SwiftUI

/// How the next card arrives, so a swipe to the next one slides in from the right and a decision
/// rises into place (`enter-next`, `enter-prev` and `enter-dec` in `app.css`).
private enum CullArrival {
    case decided, next, previous
}

/// The cards: a top bar, the card with its photo, and the controls. A tap on the photo hides
/// the bars and controls so the photo fills the screen. Mirrors `vCull` in `app.js`.
struct CullCardsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: CullSessionModel
    @State private var chrome = true
    @State private var arrival = CullArrival.decided

    var body: some View {
        VStack(spacing: 0) {
            if chrome { topBar }
            stage
            if let card = session.card, chrome {
                Text(card.fileLine)
                    .font(.system(.caption2, design: .monospaced))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                CullControlsView(session: session, card: card)
                    .padding(.bottom, 4)
            }
        }
        .statusBarHidden(!chrome)
        .task(id: session.cursor) { await prefetch() }
    }

    // MARK: Top

    private var topBar: some View {
        VStack(spacing: 0) {
            CullDayHeader(title: session.title, backTitle: "Days", onBack: { dismiss() }) {
                if let chip = session.matchesChip {
                    HStack(spacing: 4) {
                        Button(chip) { session.explainMatches() }
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                        Text("· \(session.toGoText)")
                    }
                } else {
                    Text(session.toGoText)
                }
            }
            CullProgressBar(fraction: session.progressFraction)
            if let bar = session.budgetBar {
                CullBudgetBarView(bar: bar)
            }
            CullOfflineBanner(queue: session.queue)
        }
        .transition(.opacity)
    }

    // MARK: Stage

    private var stage: some View {
        ZStack {
            if let card = session.card {
                CullCardPage(
                    card: card,
                    viewURL: services.client.imageURL(id: card.frame.id, size: .view),
                    thumbURL: services.client.imageURL(id: card.frame.id, size: .thumb),
                    chrome: chrome,
                    onToggleChrome: toggleChrome,
                    onDecide: { decide(card.stack.id, $0) },
                    onBrowse: browse,
                    onFocus: { session.openFocus(tapped: $0) })
                    .id(card.frame.id)
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A card dragged or sent away is cut off at the edge of the stage, not drawn over the bars.
        .clipped()
        .overlay(alignment: .bottom) {
            CullToastView(session: session)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .identity }
        switch arrival {
        case .decided:
            return .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 16)).combined(with: .scale(scale: 0.98)),
                removal: .identity)
        case .next:
            return .asymmetric(insertion: .opacity.combined(with: .offset(x: 42)), removal: .identity)
        case .previous:
            return .asymmetric(insertion: .opacity.combined(with: .offset(x: -42)), removal: .identity)
        }
    }

    // MARK: Actions

    private func toggleChrome() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { chrome.toggle() }
    }

    /// A swipe's decision, once the card has gone. If you decided it another way meanwhile (a
    /// button while it was flying), the swipe is dropped rather than landing on the next stack.
    private func decide(_ stackID: Int, _ action: CullAction) {
        guard session.card?.stack.id == stackID else { return }
        if action == .choose {
            session.openPicker()
            return
        }
        move(.decided) {
            switch action {
            case .keep: session.keep()
            case .reject: session.reject()
            case .choose: break
            }
        }
    }

    private func browse(_ delta: Int) {
        move(delta > 0 ? .next : .previous) { session.go(delta) }
    }

    private func move(_ how: CullArrival, _ change: () -> Void) {
        arrival = how
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1), change)
    }

    // MARK: Prefetch

    /// The next two stacks' pictures, decoded and kept, so swiping to them is instant
    /// (`prefetch` in `app.js`); and the thumbnails of the strip under a burst.
    private func prefetch() async {
        // Not before the card on screen has started its own request.
        do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        let client = services.client, loader = services.loader
        var wanted: [(url: URL, pixels: Int)] = []
        for stack in session.stacks.dropFirst(session.cursor + 1).prefix(2) {
            let frame = Self.shownFrame(of: stack, decisions: session.decisions)
            wanted.append((client.imageURL(id: frame.id, size: .view), ImagePixels.view))
            if stack.frames.count > 1 {
                for member in stack.frames.prefix(6) {
                    wanted.append((client.imageURL(id: member.id, size: .thumb), ImagePixels.thumb))
                }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for item in wanted {
                group.addTask { _ = await ImagePipeline.load(item.url, maxPixel: item.pixels, loader: loader) }
            }
        }
    }

    /// The frame a card shows, as `CullBoard.shown` says: the one kept, else the lead.
    private static func shownFrame(of stack: Stack, decisions: [Int: Decision]) -> Frame {
        if stack.frames.count == 1 { return stack.frames[0] }
        return stack.frames.first { decisions[$0.id]?.flag == .pick }
            ?? stack.frames.first { $0.id == stack.lead } ?? stack.frames[0]
    }
}

/// How many stacks are decided, as a thin line under the top bar.
struct CullProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.2))
                Rectangle().fill(Color.white)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 2)
        .padding(.horizontal, 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent decided")
    }
}

/// `Kept 4 of 5`, with a bar that fills as stacks are kept and turns amber over the budget.
struct CullBudgetBarView: View {
    let bar: CullBudgetBar

    var body: some View {
        HStack(spacing: 10) {
            Text(bar.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(bar.isOver ? Color.yellow : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(bar.isOver ? Color.yellow : Color.green)
                        .frame(width: geometry.size.width * min(max(bar.fraction, 0), 1))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Budget")
        .accessibilityValue("\(bar.text). \(bar.detail)")
    }
}
