import CullingBayCore
import SwiftUI
import UIKit

/// One photo in the viewer: the thumbnail at once, then the 1616 px picture, then the 3000 px
/// picture once zoomed past that, then full-resolution tiles from `/m/api/crop` (decision N14).
/// The gesture maths is `ViewerZoomModel`; this draws it.
@MainActor
struct ViewerPage: View {
    @Environment(AppServices.self) private var services
    @Environment(\.displayScale) private var displayScale
    let photo: Photo
    let viewer: ViewerModel
    @Binding var loadingHD: Bool
    /// Asks the viewer to move by one photo (1 is the next one).
    let onPage: (Int) -> Void
    let onClose: () -> Void
    let onTap: () -> Void

    @State private var zoom = ViewerZoomModel()
    @State private var thumb: UIImage?
    @State private var sharp: UIImage?
    @State private var large: UIImage?
    @State private var tiles: [String: UIImage] = [:]
    @State private var pageOffset = CGSize.zero
    @State private var isDragging = false
    @State private var isPinching = false
    @State private var started = ContinuousClock.now

    private var plan: TilePlan { zoom.plan(screenScale: Double(displayScale)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                pictureStack
                    .scaleEffect(zoom.scale)
                    .offset(x: zoom.offset.x, y: zoom.offset.y)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .offset(pageOffset)
            .opacity(1 - min(max(pageOffset.height, 0) / 500, 0.7))
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
                if abs(value.translation.width) >= abs(value.translation.height) {
                    pageOffset = CGSize(width: value.translation.width, height: 0)
                } else {
                    pageOffset = CGSize(width: 0, height: max(0, value.translation.height))
                }
            }
            .onEnded { value in
                isDragging = false
                let wasZoomed = zoom.isZoomed
                let delta = zoom.endPan(Point(x: value.translation.width, y: value.translation.height))
                withAnimation(.spring(duration: 0.25)) { pageOffset = .zero }
                if delta != 0 {
                    onPage(delta)
                } else if !wasZoomed, value.translation.height > 110,
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
        let missing = wanted.filter { tiles[$0.id] == nil }
        await withTaskGroup(of: (String, LoadedImage?).self) { group in
            for tile in missing {
                let url = client.cropURL(
                    id: id, centerX: tile.centerX, centerY: tile.centerY,
                    width: Double(tile.width), height: Double(tile.height))
                let key = tile.id
                group.addTask {
                    let loaded = await ImagePipeline.load(url, maxPixel: ImagePixels.tile, loader: loader)
                    return (key, loaded)
                }
            }
            for await (key, loaded) in group {
                if let loaded { tiles[key] = loaded.image }
            }
        }
    }

    private func probeSourceSize() async {
        let url = services.client.probeCropURL(id: photo.id, center: Point(x: 0.5, y: 0.5))
        guard let box = try? await CropProbe.load(url: url) else { return }
        viewer.setSourceSize(box.sourceSize, for: photo.id)
        zoom.setSourceSize(box.sourceSize)
    }
}
