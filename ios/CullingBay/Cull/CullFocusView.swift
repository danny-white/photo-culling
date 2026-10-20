import CullingBayCore
import SwiftUI
import UIKit

/// The 1:1 focus check (`vFocus` in `app.js`): the frame at the camera's AF point, or where you
/// tapped, one source pixel to a device pixel, to pan around. Opened from a card it has Reject and
/// Keep; opened from the burst picker it steps between the burst's frames, and with Linked on every
/// frame is shown at the same spot and zoom. The state is `CullFocusModel`; the page is
/// `CullFocusPage`. The zoom is the Gallery viewer's (`ViewerZoomModel`, tiles from `/m/api/crop`).
struct CullFocusView: View {
    @Environment(AppServices.self) private var services
    let session: CullSessionModel
    let focus: CullFocusModel
    /// The current page's zoom. A new one for each frame, so a page starts from fit, and the one
    /// being left can still be read for linked zoom as it steps.
    @State private var zoom = ViewerZoomModel()
    /// Whether the page has put itself at its start yet, so there is a zoom worth carrying.
    @State private var placed = false
    /// Frames to step on by itself once the first page is in place: `-CBFocusStep`.
    @State private var launchSteps = LaunchOptions.focusSteps

    var body: some View {
        VStack(spacing: 0) {
            CullDayHeader(title: focus.title, backTitle: "Back", onBack: { session.closeFocus() }) {
                Text(focus.subtitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            CullOfflineBanner(queue: session.queue)
            if let mark = focus.mark {
                markLine(mark)
            }
            CullFocusPage(
                focus: focus, frame: focus.frame, zoom: zoom, placed: $placed,
                viewURL: services.client.imageURL(id: focus.frame.id, size: .view),
                thumbURL: services.client.imageURL(id: focus.frame.id, size: .thumb),
                onStep: step, onClose: { session.closeFocus() }
            )
            .id(focus.frame.id)
            Text("Double-tap the photo to go back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: placed) { _, isPlaced in
            if isPlaced, launchSteps > 0, focus.canStep {
                launchSteps -= 1
                step(1)
            }
        }
    }

    // MARK: Words

    /// `✓ Kept ★★`, `✕ Rejected`: what the frame is marked as.
    private func markLine(_ mark: FrameMark) -> some View {
        let stars = mark.stars > 0 ? " " + CullFormat.starText(mark.stars) : ""
        return Text((mark.verdict == .reject ? "✕ " : "✓ ") + mark.text + stars)
            .font(.caption.weight(.bold))
            .foregroundStyle(CullStyle.color(mark.verdict))
            .padding(.bottom, 6)
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 8) {
            if focus.canStep { stepRow }
            if focus.returnScreen == .cards { decideRow }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// Back and forward through the burst, and the Linked switch.
    private var stepRow: some View {
        HStack(spacing: 10) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .disabled(focus.index == 0)
                .accessibilityLabel("Previous frame")
            Text(focus.counter)
                .font(.system(.subheadline, design: .monospaced))
                .frame(minWidth: 44)
                .accessibilityLabel("Frame \(focus.index + 1) of \(focus.frames.count)")
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(focus.index == focus.frames.count - 1)
                .accessibilityLabel("Next frame")
            Spacer(minLength: 0)
            linkedToggle
        }
        .buttonStyle(.plain)
        .font(.body.weight(.semibold))
        .foregroundStyle(Color.accentColor)
    }

    /// With it on, stepping to another frame keeps the same spot and zoom, to compare them.
    private var linkedToggle: some View {
        Button { focus.setLinked(!focus.linked) } label: {
            Label("Linked", systemImage: "link")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(focus.linked ? Color.black : Color.accentColor)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(focus.linked ? Color.accentColor : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(focus.linked ? .isSelected : [])
        .accessibilityHint("Keeps the same spot and zoom when you go to another frame")
    }

    private var decideRow: some View {
        HStack(spacing: 8) {
            Button("Reject") { session.rejectFromFocus() }
                .buttonStyle(CullFooterStyle(isPrimary: false))
            Button("Keep") { session.keepFromFocus() }
                .buttonStyle(CullFooterStyle(isPrimary: true))
        }
    }

    // MARK: Stepping

    /// Moves to another frame of the burst. The page being left says where it is looking and how
    /// far it is zoomed, for Linked to carry to the next one.
    private func step(_ delta: Int) {
        let state = placed ? CullZoomState(center: zoom.center, scale: zoom.scale, fit: zoom.fitSize) : nil
        let viewport = zoom.viewport
        guard focus.step(delta, from: state) else { return }
        let next = ViewerZoomModel()
        next.resize(viewport)
        zoom = next
        placed = false
    }
}

/// One frame at 1:1: the 1616 px picture as a base, zoomed to the start point, with full-resolution
/// tiles over it from `/m/api/crop`, as in the Gallery's viewer. The tiles go through the app's crop
/// gate, a couple at a time and nearest the middle first, and are let go when they leave the screen.
@MainActor
private struct CullFocusPage: View {
    @Environment(AppServices.self) private var services
    @Environment(\.displayScale) private var displayScale
    let focus: CullFocusModel
    let frame: Frame
    let zoom: ViewerZoomModel
    @Binding var placed: Bool
    let onStep: (Int) -> Void
    let onClose: () -> Void

    private let viewURL: URL
    private let thumbURL: URL
    @State private var thumb: UIImage?
    @State private var sharp: UIImage?
    @State private var tiles: [String: UIImage] = [:]
    @State private var haveImage = false
    @State private var failure: String?
    @State private var isDragging = false

    init(
        focus: CullFocusModel, frame: Frame, zoom: ViewerZoomModel, placed: Binding<Bool>,
        viewURL: URL, thumbURL: URL, onStep: @escaping (Int) -> Void, onClose: @escaping () -> Void
    ) {
        self.focus = focus
        self.frame = frame
        self.zoom = zoom
        _placed = placed
        self.viewURL = viewURL
        self.thumbURL = thumbURL
        self.onStep = onStep
        self.onClose = onClose
        _sharp = State(initialValue: DecodedImageCache.shared.image(for: viewURL, maxPixel: ImagePixels.view))
        _thumb = State(initialValue: DecodedImageCache.shared.image(for: thumbURL, maxPixel: ImagePixels.thumb))
    }

    private var plan: TilePlan { zoom.plan(screenScale: Double(displayScale)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                pictureStack
                    .scaleEffect(zoom.scale)
                    .offset(x: zoom.offset.x, y: zoom.offset.y)
                afBox
                status
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { onClose() })
            .gesture(drag.simultaneously(with: magnify))
            .onAppear { resize(geometry.size) }
            .onChange(of: geometry.size) { _, size in resize(size) }
        }
        .task { await loadBase() }
        .task { await loadSourceSize() }
        .task(id: plan.level) { await loadTiles(for: plan.level) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("1:1 view of \(frame.file)")
        .accessibilityHint("Drag to look around, pinch to zoom, double-tap to go back")
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: "Back") { onClose() }
    }

    // MARK: Drawing

    /// The picture at its fit size, with any full-resolution tiles laid over it.
    private var pictureStack: some View {
        let fit = zoom.fitSize
        return ZStack(alignment: .topLeading) {
            if let base = sharp ?? thumb {
                Image(uiImage: base)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
            }
            ForEach(plan.tiles) { tile in
                if let image = tiles[tile.id] {
                    Image(uiImage: image)
                        .resizable()
                        .frame(
                            width: fit.width * tile.normalizedRect.width,
                            height: fit.height * tile.normalizedRect.height)
                        .offset(x: fit.width * tile.normalizedRect.x, y: fit.height * tile.normalizedRect.y)
                }
            }
        }
        .frame(width: fit.width, height: fit.height, alignment: .topLeading)
    }

    /// The camera's AF box, at the size of the zoomed frame but with a line of its own width, so
    /// it sits outside the scaled picture.
    @ViewBuilder
    private var afBox: some View {
        if let af = frame.afPoint, haveImage {
            let fit = zoom.fitSize
            let width = fit.width * zoom.scale, height = fit.height * zoom.scale
            let box = width * CullFocusModel.afBoxWidth
            Rectangle()
                .strokeBorder(Color.yellow, lineWidth: 2)
                .shadow(color: .black.opacity(0.45), radius: 0.6)
                .frame(width: box, height: box / CullFocusModel.afBoxAspect)
                .position(
                    x: zoom.viewport.width / 2 + zoom.offset.x + (af.x - 0.5) * width,
                    y: zoom.viewport.height / 2 + zoom.offset.y + (af.y - 0.5) * height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// `Decoding the RAW…` until the first tile is in, or why there will not be one.
    @ViewBuilder
    private var status: some View {
        if let failure {
            Text(failure)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(10)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        } else if tiles.isEmpty && (!placed || !plan.tiles.isEmpty) {
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Decoding the RAW…").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(false)
        }
    }

    // MARK: Gestures

    /// One finger pans; a sideways swipe with the frame at fit size steps to the next one.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    zoom.beginDrag()
                }
                zoom.pan(Point(x: value.translation.width, y: value.translation.height))
            }
            .onEnded { value in
                isDragging = false
                let delta = zoom.endPan(Point(x: value.translation.width, y: value.translation.height))
                if delta != 0, focus.canStep { onStep(delta) }
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom.pinch(
                    value.magnification,
                    anchor: Point(x: value.startLocation.x, y: value.startLocation.y))
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.15)) { zoom.endPinch() }
            }
    }

    // MARK: Placing

    private func resize(_ size: CGSize) {
        let viewport = Size(width: Double(size.width), height: Double(size.height))
        if zoom.viewport != viewport {
            zoom.resize(viewport)       // which puts the zoom back to fit
            placed = false
        }
        placeIfReady()
    }

    /// Puts the page at its start: 1:1 on the point, or the zoom the last frame had when Linked.
    /// Waits for the picture's shape, the viewport, and (for 1:1) the full-resolution size.
    private func placeIfReady() {
        guard !placed, haveImage, zoom.viewport.width > 1,
              let start = focus.start(fit: zoom.fitSize, source: zoom.sourceSize, screenScale: Double(displayScale))
        else { return }
        zoom.show(center: start.center, scale: start.scale)
        placed = true
    }

    private func adopt(_ image: UIImage) {
        zoom.setImageSize(Size(width: Double(image.size.width), height: Double(image.size.height)))
        haveImage = true
        placeIfReady()
    }

    // MARK: Loading

    /// The thumbnail, then the 1616 px picture, which the card or the strip usually has decoded.
    private func loadBase() async {
        if let base = sharp ?? thumb { adopt(base) }
        if sharp != nil { return }
        if thumb == nil,
           let loaded = await ImagePipeline.load(thumbURL, maxPixel: ImagePixels.thumb, loader: services.loader),
           !Task.isCancelled {
            thumb = loaded.image
            if !haveImage { adopt(loaded.image) }
        }
        if let loaded = await ImagePipeline.load(viewURL, maxPixel: ImagePixels.view, loader: services.loader),
           !Task.isCancelled {
            sharp = loaded.image
            adopt(loaded.image)
        }
    }

    /// The first crop says how big the frame really is (`X-Crop-Box`), which 1:1 and the tile plan
    /// need. Frames the burst's other pages have asked about are known already.
    private func loadSourceSize() async {
        if let known = focus.sourceSize(for: frame.id) {
            zoom.setSourceSize(known)
            placeIfReady()
            return
        }
        let url = services.client.probeCropURL(id: frame.id, center: Point(x: 0.5, y: 0.5))
        do {
            let box = try await services.cropGate.run(urgent: true) { try await CropProbe.load(url: url) }
            focus.setSourceSize(box.sourceSize, for: frame.id)
            zoom.setSourceSize(box.sourceSize)
            placeIfReady()
        } catch {
            if !Task.isCancelled { failure = "Could not decode this frame." }
        }
    }

    /// Full-resolution tiles, nearest the middle first. Tiles that have left the screen are
    /// dropped, and a task for tiles no longer wanted is cancelled, which stops their requests.
    private func loadTiles(for level: TilePlan.Level) async {
        guard case .tiles(let wanted) = level, placed else { return }
        let keep = Set(wanted.map(\.id))
        tiles = tiles.filter { keep.contains($0.key) }
        let client = services.client, loader = services.loader, gate = services.cropGate
        let id = frame.id
        let missing = wanted.filter { tiles[$0.id] == nil }
        await withTaskGroup(of: (String, LoadedImage?).self) { group in
            for tile in missing {
                let url = client.cropURL(
                    id: id, centerX: tile.centerX, centerY: tile.centerY,
                    width: Double(tile.width), height: Double(tile.height))
                let key = tile.id
                group.addTask {
                    // Not kept decoded: a crop is large, and the compressed data is cached by the loader.
                    let loaded = try? await gate.run(urgent: true) {
                        await ImagePipeline.load(url, maxPixel: ImagePixels.tile, loader: loader, cacheDecoded: false)
                    }
                    return (key, loaded)
                }
            }
            for await (key, loaded) in group {
                if let loaded { tiles[key] = loaded.image }
            }
        }
        guard !Task.isCancelled else { return }
        if tiles.isEmpty && !wanted.isEmpty { failure = "Could not decode this frame." }
        await warmNeighbours()
    }

    /// Once this frame is in, asks the PC about the frames either side (a 64 px crop each), after
    /// everything that is on screen. The PC then has their RAWs decoded and their sizes are known
    /// when you step to them.
    private func warmNeighbours() async {
        guard focus.canStep else { return }
        let client = services.client, gate = services.cropGate
        for delta in [1, -1] {
            let index = focus.index + delta
            guard focus.frames.indices.contains(index) else { continue }
            let other = focus.frames[index].id
            guard focus.sourceSize(for: other) == nil else { continue }
            let url = client.probeCropURL(id: other, center: Point(x: 0.5, y: 0.5))
            guard let box = try? await gate.run({ try await CropProbe.load(url: url) }), !Task.isCancelled
            else { return }
            focus.setSourceSize(box.sourceSize, for: other)
        }
    }
}
