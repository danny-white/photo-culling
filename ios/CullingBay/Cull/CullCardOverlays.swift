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

/// The chip at the bottom right: how many frames a burst has, or `RAW + JPG`. Opening the burst
/// comes with the burst picker in phase 3, so for now it only says.
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

/// KEEP or REJECT, fading in as the card is dragged towards it. `note` says what a keep does to
/// the rest of a burst.
struct CullStampView: View {
    let action: CullAction
    let strength: Double
    let note: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(action == .keep ? "KEEP" : "REJECT")
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
        .foregroundStyle(action == .keep ? Color.green : Color.red)
        .rotationEffect(.degrees(-8))
        .opacity(strength)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// What a swipe or a tap on Keep or Reject asks for.
enum CullAction {
    case keep, reject
}
