import CullingBayCore
import SwiftUI
import UIKit

/// One photo in the viewer: the thumbnail at once, then the 1616 px picture, then the 3000 px
/// picture once zoomed past that, then full-resolution tiles from `/m/api/crop` (decision N14).
/// The gesture maths is `ViewerZoomModel`; this draws it.
///
/// A sideways swipe moves the viewer's whole strip (`stripOffset`, shared with the neighbouring
/// photos `ViewerView` draws either side), so the next photo comes in with the finger. The page
/// starts from the pictures already decoded, so it takes over from its neighbour without a gap.
@MainActor
struct ViewerPage: View {
    @Environment(AppServices.self) private var services
    @Environment(\.displayScale) private var displayScale
    let photo: Photo
    let viewer: ViewerModel
    @Binding var loadingHD: Bool
    /// The strip's sideways offset while dragging; the viewer animates it on a page turn.
    @Binding var stripOffset: CGFloat
    /// There is a photo that way (1 is the next one).
    let canPage: (Int) -> Bool
    /// Asks the viewer to move by one photo (1 is the next one).
    let onPage: (Int) -> Void
    let onClose: () -> Void
    let onTap: () -> Void

    @State private var zoom: ViewerZoomModel
    @State private var thumb: UIImage?
    @State private var sharp: UIImage?
    @State private var large: UIImage?
    @State private var tiles: [String: UIImage] = [:]
    /// A drag down to close: the page follows the finger and fades.
    @State private var closeOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isPinching = false
    @State private var started = ContinuousClock.now

    private var plan: TilePlan { zoom.plan(screenScale: Double(displayScale)) }
    /// Full-resolution tiles fetched at once when zoomed in.
    private static let tilesAtOnce = 3

    init(
        photo: Photo, viewer: ViewerModel, viewport: CGSize, viewURL: URL, thumbURL: URL,
        loadingHD: Binding<Bool>, stripOffset: Binding<CGFloat>, canPage: @escaping (Int) -> Bool,
        onPage: @escaping (Int) -> Void, onClose: @escaping () -> Void, onTap: @escaping () -> Void
    ) {
        self.photo = photo
        self.viewer = viewer
        _loadingHD = loadingHD
        _stripOffset = stripOffset
        self.canPage = canPage
        self.onPage = onPage
        self.onClose = onClose
        self.onTap = onTap
        // What the strip already showed of this photo is on screen in the first frame.
        let sharp = DecodedImageCache.shared.image(for: viewURL, maxPixel: ImagePixels.view)
        let thumb = sharp == nil ? DecodedImageCache.shared.image(for: thumbURL, maxPixel: ImagePixels.thumb) : nil
        let zoom = ViewerZoomModel()
        zoom.resize(Size(width: Double(viewport.width), height: Double(viewport.height)))
        if let image = sharp ?? thumb {
            zoom.setImageSize(Size(width: Double(image.size.width), height: Double(image.size.height)))
        }
        _zoom = State(initialValue: zoom)
        _sharp = State(initialValue: sharp)
        _thumb = State(initialValue: thumb)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                pictureStack
                    .scaleEffect(zoom.scale)
                    .offset(x: zoom.offset.x, y: zoom.offset.y)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .offset(x: stripOffset, y: closeOffset)
            .opacity(1 - min(max(closeOffset, 0) / 500, 0.7))
            .gesture(taps)
            .gesture(drag.simultaneously(with: magnify))
            .onAppear { zoom.resize(Size(width: geometry.size.width, height: geometry.size.height)) }
            .onChange(of: geometry.size) { _, size in
                zoom.resize(Size(width: size.width, height: size.height))
            }
        }
        .ignoresSafeArea()
        .accessibilityLabel(photo.caption ?? "Photo")
        .accessibilityAddTraits(.isImage)
        .task { await loadThumb() }
        .task { await loadSharp() }
        .task(id: plan.level != .view) { await loadLarge() }
        .task(id: plan.level) { await loadTiles(for: plan.level) }
    }

    // MARK: Drawing

    /// The picture at its fit size, with any full-resolution tiles laid over it.
    private var pictureStack: some View {
        let fit = zoom.fitSize
        return ZStack(alignment: .topLeading) {
            if let base = large ?? sharp ?? thumb {
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

    // MARK: Gestures

    /// A double tap zooms; a single tap hides or shows the overlay.
    private var taps: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                withAnimation(.easeOut(duration: 0.2)) {
                    zoom.doubleTap(at: Point(x: value.location.x, y: value.location.y))
                }
            }
            .exclusively(before: TapGesture().onEnded { onTap() })
    }

    /// One finger pans when zoomed, and otherwise swipes: sideways to the next photo, down to close.
    private var drag: some Gesture {
        // Global, because the page moves under the finger and a local translation would chase it.
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    zoom.beginDrag()
                }
                zoom.pan(Point(x: value.translation.width, y: value.translation.height))
                guard !zoom.isZoomed, !isPinching else { return }
                let dx = value.translation.width
                if abs(dx) >= abs(value.translation.height) {
                    // Past the first or last photo the strip only gives a little.
                    stripOffset = canPage(dx < 0 ? 1 : -1) ? dx : dx * 0.3
                    closeOffset = 0
                } else {
                    stripOffset = 0
                    closeOffset = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                isDragging = false
                let wasZoomed = zoom.isZoomed
                let delta = zoom.endPan(Point(x: value.translation.width, y: value.translation.height))
                withAnimation(.spring(duration: 0.25)) { closeOffset = 0 }
                if delta != 0 && canPage(delta) {
                    onPage(delta)       // the viewer slides the strip on and swaps the photo
                    return
                }
                withAnimation(.spring(duration: 0.25)) { stripOffset = 0 }
                if !wasZoomed, value.translation.height > 110,
                          value.translation.height > abs(value.translation.width) {
                    onClose()
                }
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isPinching = true
                zoom.pinch(
                    value.magnification,
                    anchor: Point(x: value.startLocation.x, y: value.startLocation.y))
            }
            .onEnded { _ in
                isPinching = false
                withAnimation(.easeOut(duration: 0.15)) { zoom.endPinch() }
            }
    }

    // MARK: Loading

    private func adopt(_ image: UIImage) {
        zoom.setImageSize(Size(width: Double(image.size.width), height: Double(image.size.height)))
    }

    private func mark(_ item: PerfItem) {
        let perf = services.perf
        Task { await perf.mark(item) }
    }

    private func loadThumb() async {
        if let size = viewer.sourceSize(for: photo.id) { zoom.setSourceSize(size) }
        guard thumb == nil, sharp == nil else { return }
        let url = services.client.imageURL(id: photo.id, size: .thumb)
        guard let loaded = await ImagePipeline.load(url, maxPixel: ImagePixels.thumb, loader: services.loader)
        else { return }
        thumb = loaded.image
        adopt(loaded.image)
        mark(PerfMarks.viewerFirst(ms: (ContinuousClock.now - started).inMilliseconds, url: url))
    }

    private func loadSharp() async {
        let url = services.client.imageURL(id: photo.id, size: .view)
        guard let loaded = await ImagePipeline.load(url, maxPixel: ImagePixels.view, loader: services.loader)
        else { return }
        sharp = loaded.image
        adopt(loaded.image)
        mark(PerfMarks.viewerPhoto(ms: (ContinuousClock.now - started).inMilliseconds, url: url))
    }

    /// The 3000 px picture, once zoomed past what the 1616 px one can show.
    private func loadLarge() async {
        guard plan.level != .view, large == nil else { return }
        let url = services.client.imageURL(id: photo.id, size: .large)
        let begin = ContinuousClock.now
        loadingHD = true
        defer { loadingHD = false }
        guard let loaded = await ImagePipeline.load(url, maxPixel: ImagePixels.large, loader: services.loader)
        else { return }
        large = loaded.image
        adopt(loaded.image)
        mark(PerfMarks.viewerHD(ms: (ContinuousClock.now - begin).inMilliseconds, url: url))
    }

    /// Full-resolution tiles, nearest the centre of the view first. The first crop's
    /// `X-Crop-Box` gives the source size the plan needs, so it is asked for before any tile.
    private func loadTiles(for level: TilePlan.Level) async {
        guard case .tiles(let wanted) = level else { return }
        guard zoom.sourceSize != nil else {
            await probeSourceSize()    // sets the size, which changes the plan and runs this again
            return
        }
        let keep = Set(wanted.map(\.id))
        tiles = tiles.filter { keep.contains($0.key) }
        let client = services.client
        let loader = services.loader
        let id = photo.id
        // Nearest the middle of the screen first (TilePlanner's order), three at a time, so the
        // spot you are looking at sharpens before the edges instead of every tile sharing the
        // connection at once.
        let missing = wanted.filter { tiles[$0.id] == nil }
        let fetch: @Sendable (Tile) async -> (String, LoadedImage?) = { tile in
            let url = client.cropURL(
                id: id, centerX: tile.centerX, centerY: tile.centerY,
                width: Double(tile.width), height: Double(tile.height))
            return (tile.id, await ImagePipeline.load(url, maxPixel: ImagePixels.tile, loader: loader))
        }
        await withTaskGroup(of: (String, LoadedImage?).self) { group in
            var queue = missing.makeIterator()
            for _ in 0..<Self.tilesAtOnce {
                guard let tile = queue.next() else { break }
                group.addTask { await fetch(tile) }
            }
            for await (key, loaded) in group {
                if let loaded { tiles[key] = loaded.image }
                if let tile = queue.next() { group.addTask { await fetch(tile) } }
            }
        }
    }

    private func probeSourceSize() async {
        let url = services.client.probeCropURL(id: photo.id, center: Point(x: 0.5, y: 0.5))
        guard let box = try? await CropProbe.load(url: url, transport: services.network) else { return }
        viewer.setSourceSize(box.sourceSize, for: photo.id)
        zoom.setSourceSize(box.sourceSize)
    }
}
