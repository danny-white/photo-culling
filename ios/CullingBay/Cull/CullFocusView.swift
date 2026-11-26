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
    @AppStorage(CullPreferences.showAFPoint) private var showAF = false

    private let viewURL: URL
    private let thumbURL: URL
    @State private var thumb: UIImage?
    @State private var sharp: UIImage?
    @State private var tiles: [String: UIImage] = [:]
    @State private var haveImage = false
    @State private var failure: String?
    /// The 1:1 crop the phone saved at the AF point, shown when the PC cannot make one now.
    @State private var savedCrop: UIImage?
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
            // The saved crop has its own gestures; these would move a picture that is not shown.
            .allowsHitTesting(savedCrop == nil)
            .onAppear { resize(geometry.size) }
            .onChange(of: geometry.size) { _, size in resize(size) }
        }
        .overlay {
            if let savedCrop {
                CullSavedCropView(image: savedCrop, onClose: onClose)
            }
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
        if showAF, let af = frame.afPoint, haveImage {
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
        if savedCrop != nil {
            EmptyView()
        } else if let failure {
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
        // While the PC cannot be reached (or Work offline is on), at once: the saved 1:1 if the
        // phone has one, or why there is none. With a saved 1:1 and the queue offline, straight to
        // it too; otherwise a short wait for the PC (over Tailscale a PC that has gone away may not
        // refuse the connection, and the default wait is a minute).
        let hasSaved = services.offline.hasSavedCrop(for: frame.id)
        if pcIsAway || (hasSaved && services.cullQueue.isOffline) {
            await useSavedCropOrFail()
            return
        }
        let url = services.client.probeCropURL(id: frame.id, center: Point(x: 0.5, y: 0.5))
        let timeout: TimeInterval = hasSaved ? 8 : 60
        let network = services.network
        do {
            let box = try await services.cropGate.run(urgent: true) {
                try await CropProbe.load(url: url, timeout: timeout, transport: network)
            }
            focus.setSourceSize(box.sourceSize, for: frame.id)
            zoom.setSourceSize(box.sourceSize)
            placeIfReady()
        } catch {
            if !Task.isCancelled { await useSavedCropOrFail() }
        }
    }

    /// The PC cannot be reached, or Work offline is on: the 1:1 cannot come from it.
    private var pcIsAway: Bool {
        services.link.state == .unreachable || services.link.isWorkingOffline
    }

    /// The 1:1 cannot come from the PC (it cannot be reached, or will not decode this frame). If
    /// the phone saved one at the AF point, that stands in for it; if not, the page says why.
    private func useSavedCropOrFail() async {
        if let data = await services.offline.savedCrop(for: frame.id) {
            let decoded = await Task.detached(priority: .userInitiated) {
                ImagePipeline.decode(data, maxPixel: ImagePixels.tile)
            }.value
            if let decoded, !Task.isCancelled {
                savedCrop = decoded.image
                return
            }
        }
        guard !Task.isCancelled else { return }
        if services.link.isWorkingOffline {
            failure = "The 1:1 needs the PC. Turn off Work offline to see the 1:1."
        } else if services.link.state == .unreachable {
            failure = "The 1:1 needs the PC, which can't be reached right now."
        } else {
            failure = "Could not decode this frame."
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
        if tiles.isEmpty && !wanted.isEmpty { await useSavedCropOrFail() }
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
            let network = services.network
            guard let box = try? await gate.run({ try await CropProbe.load(url: url, transport: network) }),
                  !Task.isCancelled
            else { return }
            focus.setSourceSize(box.sourceSize, for: other)
        }
    }
}

/// The 1:1 crop the phone saved at the frame's AF point, standing in for the full-resolution tiles
/// while the PC cannot make them. It fits the page (1200 px across is about one source pixel to a
/// device pixel on an iPhone), pinch zooms it, a drag pans it and a double tap goes back.
@MainActor
private struct CullSavedCropView: View {
    private static let maxScale: CGFloat = 6

    let image: UIImage
    let onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var settledOffset = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                Text("Saved 1:1 at the AF point")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { onClose() })
            .gesture(drag(in: geometry.size).simultaneously(with: magnify(in: geometry.size)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved 1:1 view at the AF point")
        .accessibilityHint("Drag to look around, pinch to zoom, double-tap to go back")
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: "Back") { onClose() }
    }

    private func drag(in area: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                offset = limited(
                    CGSize(
                        width: settledOffset.width + value.translation.width,
                        height: settledOffset.height + value.translation.height),
                    scale: scale, in: area)
            }
            .onEnded { _ in settledOffset = offset }
    }

    private func magnify(in area: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), Self.maxScale)
                offset = limited(offset, scale: scale, in: area)
            }
            .onEnded { _ in
                settledScale = scale
                settledOffset = offset
            }
    }

    /// Keeps the picture from being dragged off the page: no further than its own edge.
    private func limited(_ offset: CGSize, scale: CGFloat, in area: CGSize) -> CGSize {
        let ratio = image.size.width / max(image.size.height, 1)
        let width = min(area.width, area.height * ratio)
        let height = width / max(ratio, 0.001)
        let slackX = max(0, (width * scale - area.width) / 2)
        let slackY = max(0, (height * scale - area.height) / 2)
        return CGSize(
            width: min(max(offset.width, -slackX), slackX), height: min(max(offset.height, -slackY), slackY))
    }
}
