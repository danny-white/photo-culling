import CullingBayCore
import SwiftUI
import UIKit

/// The card for one stack: the picture fitted inside the space it is given, never cropped, with
/// its status line, badges and chip over it, and the swipes of `bindStage` in `app.js`.
///
/// - Drag up past 80 pt keeps a single, with a KEEP stamp fading in; on a burst it chooses
///   (CHOOSE) and the card springs back while the picker opens. Drag down rejects.
/// - Drag sideways 70 pt or more browses to the next (left) or previous (right) stack.
/// - A shorter drag springs back. A single tap hides or shows the controls. A double tap opens
///   the 1:1 focus check, at the camera's AF point or where you tapped.
///
/// The drag state lives here, so a new card starts at rest. The card is made with `.id` of its
/// frame, so the next stack gets a new page.
struct CullCardPage: View {
    private static let decideDistance: CGFloat = 80
    private static let browseDistance: CGFloat = 70

    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: CullCard
    let chrome: Bool
    let onToggleChrome: () -> Void
    let onDecide: (CullAction) -> Void
    let onBrowse: (Int) -> Void
    /// A double tap, as fractions of the photo.
    let onFocus: (Point) -> Void

    private let viewURL: URL
    private let thumbURL: URL
    @State private var image: UIImage?
    @State private var hasFullSize: Bool
    @State private var loadFailed = false

    @GestureState private var isTouching = false
    @State private var dragOffset = CGSize.zero
    @State private var lockedAxis: Axis?
    /// The card is leaving after a swipe, so no other gesture counts.
    @State private var flying: CullAction?
    @State private var flightFade = 1.0

    init(
        card: CullCard, viewURL: URL, thumbURL: URL, chrome: Bool,
        onToggleChrome: @escaping () -> Void, onDecide: @escaping (CullAction) -> Void,
        onBrowse: @escaping (Int) -> Void, onFocus: @escaping (Point) -> Void
    ) {
        self.card = card
        self.viewURL = viewURL
        self.thumbURL = thumbURL
        self.chrome = chrome
        self.onToggleChrome = onToggleChrome
        self.onDecide = onDecide
        self.onBrowse = onBrowse
        self.onFocus = onFocus
        // What swiping to a card prefetched is on screen in the first frame.
        let full = DecodedImageCache.shared.image(for: viewURL, maxPixel: ImagePixels.view)
        _hasFullSize = State(initialValue: full != nil)
        _image = State(
            initialValue: full ?? DecodedImageCache.shared.image(for: thumbURL, maxPixel: ImagePixels.thumb))
    }

    var body: some View {
        GeometryReader { geometry in
            // A burst has its two stacked edges above the photo, so it leaves room for them.
            let edge: CGFloat = card.isBurst ? 14 : 0
            let fit = fitted(in: CGSize(width: geometry.size.width, height: geometry.size.height - edge))
            ZStack {
                Color.clear.contentShape(Rectangle())
                cardBody(fit)
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: dragOffset.width, y: dragOffset.height + edge / 2)
                    .opacity(flightFade)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .gesture(taps(photo: photoRect(fit: fit, in: geometry.size, edge: edge)))
            .gesture(drag(stageHeight: geometry.size.height))
        }
        .onChange(of: isTouching) { _, touching in
            // A drag the system cut short never calls `onEnded`; the card still has to come back.
            if !touching && flying == nil { settle() }
        }
        .task(id: viewURL) { await loadFullSize() }
        .task(id: thumbURL) { await loadThumb() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.fileLine)
        .accessibilityValue(card.statusLine?.text ?? "Not decided")
        .accessibilityAddTraits(.isImage)
        .accessibilityHint("Swipe up or down with one finger to go to the next or previous photo")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onBrowse(1)
            case .decrement: onBrowse(-1)
            @unknown default: break
            }
        }
    }

    // MARK: Drawing

    /// The picture's own shape inside `size`; 3:2 until the picture is known.
    private func fitted(in size: CGSize) -> CGSize {
        let ratio = image.map { $0.size.width / max($0.size.height, 1) } ?? 1.5
        guard size.width > 0, size.height > 0 else { return .zero }
        let width = min(size.width, size.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    private func cardBody(_ fit: CGSize) -> some View {
        let verdict = card.status.verdict
        // A rejected photo is greyed, except when the controls are hidden and you want to see it.
        let greyed = verdict == .reject && chrome
        return ZStack {
            if card.isBurst {
                stackEdges(width: fit.width)
            }
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .grayscale(greyed ? 1 : 0)
                        .brightness(greyed ? -0.28 : 0)
                } else if loadFailed {
                    Text("Couldn’t load this photo. Tap to try again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                } else {
                    ProgressView().tint(.white)
                }
                if let action = stampAction {
                    action.tint
                        .opacity(0.25 * stampStrength)
                        .allowsHitTesting(false)
                    CullStampView(action: action, strength: stampStrength, note: stampNote(action))
                }
                if let verdict {
                    Rectangle()
                        .strokeBorder(CullStyle.color(verdict), lineWidth: 3)
                        .allowsHitTesting(false)
                }
                overlays
            }
            .frame(width: fit.width, height: fit.height)
            .clipped()
        }
    }

    /// The badges, the chip and the status line. They go when the controls do.
    private var overlays: some View {
        ZStack {
            if let line = card.statusLine {
                CullStatusLineView(line: line)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            if !card.badges.isEmpty {
                CullBadgesView(badges: card.badges)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            if let af = card.frame.afPoint {
                CullAFBoxView(point: af)
            }
            if let chip = card.chip {
                CullChipView(chip: chip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    // Over the status line when there is one.
                    .padding(.bottom, card.statusLine == nil ? 8 : 40)
                    .padding(.trailing, 8)
            }
        }
        // Labels on a photo stay a size that leaves the photo to look at.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .opacity(chrome ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// The two edges peeking over the top of a burst.
    private func stackEdges(width: CGFloat) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(white: 0.15))
                .frame(width: max(0, width - 52), height: 6)
                .offset(y: -13)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(white: 0.23))
                .frame(width: max(0, width - 24), height: 7)
                .offset(y: -7)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(chrome ? 1 : 0)
        .accessibilityHidden(true)
    }

    // MARK: Stamp

    /// What the drag so far would do.
    private var stampAction: CullAction? {
        if let flying { return flying }
        guard lockedAxis == .vertical, dragOffset.height != 0 else { return nil }
        return dragOffset.height < 0 ? (card.isBurst ? .choose : .keep) : .reject
    }

    private var stampStrength: Double {
        flying != nil ? 1 : min(1, Double(abs(dragOffset.height) / Self.decideDistance))
    }

    /// On a burst, a swipe up chooses: the line says what opens before you let go.
    private func stampNote(_ action: CullAction) -> String? {
        action == .choose ? "pick the keepers" : nil
    }

    // MARK: Gestures

    private func drag(stageHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { value in
                guard flying == nil else { return }
                let dx = value.translation.width, dy = value.translation.height
                if lockedAxis == nil {
                    lockedAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
                }
                // The card follows the finger along the axis the drag started on.
                dragOffset = lockedAxis == .vertical
                    ? CGSize(width: 0, height: dy) : CGSize(width: dx * 0.7, height: 0)
            }
            .onEnded { value in
                guard flying == nil else { return }
                let dx = value.translation.width, dy = value.translation.height
                let axis = lockedAxis
                lockedAxis = nil
                switch axis {
                case .vertical where dy <= -Self.decideDistance && card.isBurst:
                    // A burst is chosen, not kept: the picker opens and the card comes back.
                    settle()
                    onDecide(.choose)
                case .vertical where dy <= -Self.decideDistance:
                    fly(.keep, from: stageHeight)
                case .vertical where dy >= Self.decideDistance:
                    fly(.reject, from: stageHeight)
                case .horizontal where abs(dx) >= Self.browseDistance:
                    onBrowse(dx < 0 ? 1 : -1)
                    settle()
                default:
                    settle()
                }
            }
    }

    /// A single tap hides or shows the controls; a double tap opens the focus check, where the
    /// camera focused or, with no AF point, where you tapped (`photo` is where the picture is).
    private func taps(photo: CGRect) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard flying == nil else { return }
                let rect = Rect(
                    x: Double(photo.minX), y: Double(photo.minY), width: Double(photo.width), height: Double(photo.height))
                onFocus(CullFocusModel.imagePoint(x: Double(value.location.x), y: Double(value.location.y), in: rect))
            }
            .exclusively(before: TapGesture().onEnded {
                guard flying == nil else { return }
                if loadFailed { retry() } else { onToggleChrome() }
            })
    }

    /// Where the picture sits in the stage: centred, a burst's edges above it pushing it down.
    private func photoRect(fit: CGSize, in stage: CGSize, edge: CGFloat) -> CGRect {
        CGRect(
            x: (stage.width - fit.width) / 2, y: (stage.height - fit.height) / 2 + edge / 2,
            width: fit.width, height: fit.height)
    }

    /// Sends the card off the top or bottom (the web version takes 0.1 s), then decides.
    private func fly(_ action: CullAction, from stageHeight: CGFloat) {
        guard !reduceMotion else {
            onDecide(action)
            settle()
            return
        }
        flying = action
        withAnimation(.easeIn(duration: 0.1), completionCriteria: .logicallyComplete) {
            dragOffset = CGSize(width: 0, height: (action == .keep ? -1 : 1) * stageHeight * 1.15)
            flightFade = 0
        } completion: {
            onDecide(action)
            // The card is normally gone by now. If the decision was refused, bring it back.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                dragOffset = .zero
                flightFade = 1
                flying = nil
            }
        }
    }

    private func settle() {
        lockedAxis = nil
        withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { dragOffset = .zero }
    }

    // MARK: Loading

    private func loadFullSize() async {
        guard !hasFullSize else { return }
        loadFailed = false
        if let loaded = await ImagePipeline.load(viewURL, maxPixel: ImagePixels.view, loader: services.loader) {
            image = loaded.image
            hasFullSize = true
        } else if !Task.isCancelled {
            loadFailed = true
        }
    }

    /// The thumbnail is small, so it fills the card while the full picture comes.
    private func loadThumb() async {
        guard image == nil else { return }
        if let loaded = await ImagePipeline.load(thumbURL, maxPixel: ImagePixels.thumb, loader: services.loader),
           !hasFullSize {
            image = loaded.image
        }
    }

    private func retry() {
        loadFailed = false
        Task { await loadFullSize() }
    }
}
