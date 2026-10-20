import CullingBayCore
import SwiftUI

/// The colours of a decision, as the web version's keep, hero and reject.
enum CullStyle {
    static func color(_ verdict: StackStatus.Verdict) -> Color {
        switch verdict {
        case .keep: .green
        case .hero: .yellow
        case .reject: .red
        }
    }

    /// The panels the controls sit on.
    static let panel = Color(.systemGray6)
}

/// Badges at the top left of the photo: `Sharpest`, `Blown`, `Picked in Lightroom`.
struct CullBadgesView: View {
    let badges: [CullBadge]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                HStack(spacing: 5) {
                    if badge.style == .hint {
                        Circle().fill(Color.yellow).frame(width: 6, height: 6)
                    }
                    Text(badge.text)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(badge.style == .lightroom ? Color.white : Color.yellow)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.62), in: Capsule())
                .overlay {
                    if badge.style == .lightroom {
                        Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5)
                    }
                }
            }
        }
    }
}

/// The chip at the bottom right: how many frames a burst has, or `RAW + JPG`. It only says; the
/// strip under a burst card, its Choose button and a swipe up open the burst.
struct CullChipView: View {
    let chip: CullChip

    var body: some View {
        Group {
            switch chip {
            case .burst(let count):
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack")
                    Text("\(count)")
                }
                .font(.caption.weight(.bold))
                .accessibilityLabel("Burst of \(count) frames")
            case .partners(let text):
                Text(text)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.62), in: Capsule())
    }
}

/// The line along the bottom of a decided photo: `Kept all 3`, `Rejected · all 5 frames`.
struct CullStatusLineView: View {
    let line: CullStatusLine

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(CullStyle.color(line.verdict))
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(line.verdict == .reject ? Color.white : Color.black)
            }
            .frame(width: 18, height: 18)
            Text(line.text)
                .font(.caption.weight(.bold))
                .lineLimit(2)
            if line.stars > 0 {
                Text(CullFormat.starText(line.stars))
                    .font(.caption)
                    .foregroundStyle(Color.yellow)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.top, 24)
        .padding(.bottom, 9)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom))
    }

    private var symbol: String {
        switch line.verdict {
        case .keep: "checkmark"
        case .hero: "star.fill"
        case .reject: "xmark"
        }
    }
}

/// KEEP, CHOOSE or REJECT, fading in as the card is dragged towards it. `note` is a line under it.
struct CullStampView: View {
    let action: CullAction
    let strength: Double
    let note: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(action.word)
                .font(.system(size: 32, weight: .heavy))
                .tracking(2.5)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(lineWidth: 3))
            if let note {
                Text(note)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.5), in: Capsule())
            }
        }
        .foregroundStyle(action.tint)
        .rotationEffect(.degrees(-8))
        .opacity(strength)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// What a swipe on the card asks for. Up keeps a single and, on a burst, chooses: it opens the
/// burst picker instead of deciding.
enum CullAction {
    case keep, reject, choose

    var word: String {
        switch self {
        case .keep: "KEEP"
        case .reject: "REJECT"
        case .choose: "CHOOSE"
        }
    }

    var tint: Color { self == .reject ? .red : .green }
}

/// The camera's autofocus point: a small yellow box, 9% of the photo's width and three to two
/// (`.af` in `app.css`), centred on the point. Sized by the photo it sits over, so put it in an
/// overlay of the photo itself, not of a box with bars around it.
struct CullAFBoxView: View {
    /// Fractions of the photo.
    let point: Point

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * CullFocusModel.afBoxWidth
            Rectangle()
                .strokeBorder(Color.yellow, lineWidth: 2)
                .shadow(color: .black.opacity(0.45), radius: 0.6)
                .frame(width: width, height: width / CullFocusModel.afBoxAspect)
                .position(x: geometry.size.width * point.x, y: geometry.size.height * point.y)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
