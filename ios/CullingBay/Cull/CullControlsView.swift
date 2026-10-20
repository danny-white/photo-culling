import CullingBayCore
import SwiftUI

/// Under the card: one row that is the star row on a single and the strip of frames on a burst
/// (so the buttons below never move between the two), then Reject, Undo, Keep all and Keep, which
/// on a burst is Choose and opens the picker.
struct CullControlsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: CullSessionModel
    let card: CullCard

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if card.isBurst { strip } else { starRow }
            }
            .frame(height: 44)
            buttons
        }
        .padding(.horizontal, 12)
        // The labels grow with the text size, but not so far that the row breaks.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    // MARK: Stars

    /// One tap keeps the photo with that rating.
    private var starRow: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { stars in
                Button { session.keep(stars: stars) } label: {
                    Image(systemName: "star.fill")
                        .font(.body)
                        .foregroundStyle(stars <= card.stars ? Color.yellow : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(CullStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(stars == 1 ? "1 star" : "\(stars) stars")
                .accessibilityHint("Keeps this photo with \(stars == 1 ? "1 star" : "\(stars) stars")")
                .accessibilityAddTraits(stars <= card.stars ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keep with stars")
    }

    // MARK: Burst strip

    /// The first six frames of the burst, the kept ones outlined and the rejected ones dimmed.
    /// A tap opens the picker on the frame the card shows.
    private var strip: some View {
        Button { session.openPicker(fromStart: false) } label: { stripContent }
            .buttonStyle(.plain)
            .accessibilityLabel("Burst of \(card.stack.frames.count) frames")
            .accessibilityHint("Opens the burst to choose the frames to keep")
    }

    private var stripContent: some View {
        HStack(spacing: 4) {
            ForEach(card.strip) { item in
                RemoteImage(url: services.client.imageURL(id: item.frame.id, size: .thumb))
                    .frame(width: 40, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .opacity(item.mark == .reject ? 0.3 : 1)
                    .overlay {
                        if item.mark == .pick {
                            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.green, lineWidth: 2)
                        }
                    }
            }
            if card.stripMore > 0 {
                Text("+\(card.stripMore)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("Choose")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(CullStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        if typeSize.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                controlButtons
            }
        } else {
            HStack(spacing: 8) {
                controlButtons
            }
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        CullControlButton(
            title: "Reject", systemImage: "xmark", tint: .red, isOn: card.pressed.reject
        ) { session.reject() }
        CullControlButton(title: "Undo", systemImage: "arrow.uturn.backward", tint: .secondary, isOn: false) {
            session.undo()
        }
        .disabled(!session.canUndo)
        if card.isBurst {
            CullControlButton(
                title: card.keepAllLabel, systemImage: "rectangle.stack", tint: .accentColor,
                isOn: card.pressed.keepAll, isSuggested: card.suggestsKeepAll
            ) { session.keepAll() }
        }
        CullControlButton(
            title: card.keepLabel, systemImage: card.isBurst ? "rectangle.stack" : "checkmark", tint: .green,
            isOn: card.pressed.keep
        ) {
            if card.isBurst { session.openPicker() } else { session.keep() }
        }
    }
}

/// An icon over a short label. Pressed in the colour of its action once that is what was decided.
struct CullControlButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isOn: Bool
    var isSuggested = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    // The same height for every icon, so the labels line up.
                    .frame(minHeight: 28)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(CullControlStyle(tint: tint, isOn: isOn, isSuggested: isSuggested))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct CullControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let tint: Color
    let isOn: Bool
    let isSuggested: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        configuration.label
            .foregroundStyle(tint)
            .background {
                shape.fill(isOn ? tint.opacity(0.22) : isSuggested ? tint.opacity(0.16) : CullStyle.panel)
                if configuration.isPressed { shape.fill(Color.white.opacity(0.12)) }
            }
            .overlay {
                if isOn || isSuggested { shape.strokeBorder(tint, lineWidth: 1.5) }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.35)
    }
}
