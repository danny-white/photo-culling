import CullingBayCore
import SwiftUI

/// One opened day: the cards while stacks are open, the review when they are done, the burst
/// picker over a card, and the 1:1 focus check over a card or the picker. Which one shows is
/// `session.screen`; the screens are `CullCardsView`, `CullReviewView`, `CullPickerView` and
/// `CullFocusView`. A darkroom in every theme, as the web version is: a neutral surround to judge
/// photos against.
struct CullDayView: View {
    @Environment(\.dismiss) private var dismiss
    let session: CullSessionModel
    @State private var appliedLaunchOptions = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch session.phase {
            case .idle, .loading:
                placeholder {
                    ProgressView().tint(.white)
                }
            case .failed(let message):
                placeholder {
                    VStack(spacing: 12) {
                        Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Try again") { Task { await session.load() } }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 24)
                }
            case .loaded:
                // The focus check sits over the screen it was opened from, which stays as it was.
                switch session.baseScreen {
                case .cards, .focus: CullCardsView(session: session)
                case .summary: CullReviewView(session: session)
                case .picker: CullPickerView(session: session)
                }
                if let focus = session.focus {
                    CullFocusView(session: session, focus: focus)
                }
            }
        }
        .preferredColorScheme(.dark)
        // The Days button goes back. Hiding the system back button also turns off the swipe from
        // the screen's edge, which a swipe to browse the previous photo would otherwise start.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // A load the tab bar cut short starts again when the day comes back.
        .task { if session.phase == .idle { await session.load() } }
        // The simulator's launch arguments look at a screen; they read and decide nothing.
        .task(id: session.phase) {
            guard session.phase == .loaded, !appliedLaunchOptions else { return }
            appliedLaunchOptions = true
            LaunchOptions.apply(to: session)
        }
        .sensoryFeedback(trigger: session.feedback) { _, new in
            switch new?.kind {
            case .kept: .impact(weight: .light)
            case .hero: .success
            case .rejected: .impact(flexibility: .rigid, intensity: 0.8)
            case .undone: .warning
            case nil: nil
            }
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            CullDayHeader(title: session.title, backTitle: "Days") { dismiss() }
            Spacer()
            content()
            Spacer()
        }
    }
}

/// The bar across the top of a day: a back button, the day's title and a line under it.
struct CullDayHeader<Subtitle: View>: View {
    let title: String
    /// Nil for no back button.
    let backTitle: String?
    /// The symbol before the back button's words; nil for none (Cancel).
    let backIcon: String?
    let onBack: () -> Void
    let subtitle: Subtitle

    init(
        title: String, backTitle: String?, backIcon: String? = "chevron.left", onBack: @escaping () -> Void,
        @ViewBuilder subtitle: () -> Subtitle
    ) {
        self.title = title
        self.backTitle = backTitle
        self.backIcon = backIcon
        self.onBack = onBack
        self.subtitle = subtitle()
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            // No room to share a line with the title: the back button goes above it.
            VStack(alignment: .leading, spacing: 2) {
                backButton
                titles(alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        } else {
            ZStack {
                titles(alignment: .center)
                    .padding(.horizontal, 88)
                HStack {
                    backButton
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
        }
    }

    private func titles(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.headline)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.8)
            subtitle
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var backButton: some View {
        if let backTitle {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    if let backIcon {
                        Image(systemName: backIcon).font(.body.weight(.semibold))
                    }
                    Text(backTitle)
                }
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .foregroundStyle(Color.accentColor)
        }
    }
}

extension CullDayHeader where Subtitle == EmptyView {
    init(title: String, backTitle: String?, onBack: @escaping () -> Void) {
        self.init(title: title, backTitle: backTitle, onBack: onBack) { EmptyView() }
    }
}
