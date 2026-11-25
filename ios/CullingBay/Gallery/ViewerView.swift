import CullingBayCore
import SwiftUI
import UIKit

/// Full-screen paging over a results screen's photos. State lives in `ViewerModel`; each photo is
/// a `ViewerPage` that does the loading and zooming. Mirrors the viewer in `gallery.js`.
@MainActor
struct ViewerView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var viewer: ViewerModel
    @State private var showsInfo = true
    @State private var loadingHD = false
    @State private var export: ExportLaunch?
    /// The strip of photos (previous, current, next) is this far off centre while you swipe.
    @State private var stripOffset: CGFloat = 0
    /// A page turn is sliding the strip; the swap happens when it ends.
    @State private var turning = false
    /// Black between neighbouring photos while they slide, as in Photos.
    private static let gap: CGFloat = 16
    /// Pushes a results screen (Similar, Whole day) once the viewer has closed.
    let onOpen: (FeedModel.Source) -> Void

    init(
        photos: [Photo], index: Int, source: FeedModel.Source,
        onOpen: @escaping (FeedModel.Source) -> Void
    ) {
        _viewer = State(initialValue: ViewerModel(photos: photos, index: index, source: source))
        self.onOpen = onOpen
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            strip
            if showsInfo {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!showsInfo)
        .task(id: viewer.index) { await prefetch() }
        .sheet(item: $export) { launch in
            ExportSheet(launch: launch)
        }
    }

    // MARK: Strip

    /// The current photo with its neighbours either side, one screen width (plus the gap) apart,
    /// all moved by `stripOffset`, so the next photo slides in with the finger.
    private var strip: some View {
        GeometryReader { geometry in
            let pitch = geometry.size.width + Self.gap
            ZStack {
                ForEach([-1, 1], id: \.self) { side in
                    if let photo = neighbour(at: viewer.index + side) {
                        ViewerNeighbour(
                            photo: photo,
                            viewURL: services.client.imageURL(id: photo.id, size: .view),
                            thumbURL: services.client.imageURL(id: photo.id, size: .thumb))
                            .id(photo.id)
                            .offset(x: CGFloat(side) * pitch + stripOffset)
                    }
                }
                if let photo = viewer.current {
                    ViewerPage(
                        photo: photo, viewer: viewer, viewport: geometry.size,
                        viewURL: services.client.imageURL(id: photo.id, size: .view),
                        thumbURL: services.client.imageURL(id: photo.id, size: .thumb),
                        loadingHD: $loadingHD, stripOffset: $stripOffset,
                        canPage: { neighbour(at: viewer.index + $0) != nil },
                        onPage: { turn($0, pitch: pitch) }, onClose: { dismiss() }, onTap: toggleInfo)
                        .id(photo.id)
                        .allowsHitTesting(!turning)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }

    private func neighbour(at index: Int) -> Photo? {
        viewer.photos.indices.contains(index) ? viewer.photos[index] : nil
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
            Text(viewer.counter).font(.subheadline.monospacedDigit())
            Spacer()
            Text("HD…")
                .font(.caption.weight(.semibold))
                .frame(width: 44, height: 44)
                .opacity(loadingHD ? 1 : 0)
                .accessibilityHidden(!loadingHD)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false))
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewer.whenText).font(.subheadline.weight(.bold))
            if !viewer.whereText.isEmpty {
                Text(viewer.whereText).font(.footnote).opacity(0.85)
            }
            if !viewer.caption.isEmpty {
                Text(viewer.caption).font(.footnote).opacity(0.7)
            }
            HStack(spacing: 8) {
                ViewerButton(title: "Save", systemImage: "square.and.arrow.down") {
                    if let photo = viewer.current {
                        export = services.makeExport([photo], action: .save)
                    }
                }
                ViewerButton(title: "Share", systemImage: "square.and.arrow.up") {
                    if let photo = viewer.current {
                        export = services.makeExport([photo], action: .share)
                    }
                }
                ViewerButton(title: "Similar", systemImage: "photo.on.rectangle.angled") {
                    if let photo = viewer.current {
                        open(.like(photo.id, file: photo.file))
                    }
                }
                if viewer.showsDayButton {
                    ViewerButton(title: "Whole day", systemImage: "calendar") {
                        if let photo = viewer.current {
                            open(.day(photo.day))
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false))
    }

    // MARK: Actions

    private func toggleInfo() {
        withAnimation(.easeInOut(duration: 0.2)) { showsInfo.toggle() }
    }

    /// Slides the strip the rest of the way, then makes the neighbour the current photo with no
    /// animation, so it takes over where it already is.
    private func turn(_ delta: Int, pitch: CGFloat) {
        guard !turning, neighbour(at: viewer.index + delta) != nil else {
            withAnimation(.spring(duration: 0.25)) { stripOffset = 0 }
            return
        }
        turning = true
        withAnimation(.easeOut(duration: 0.18), completionCriteria: .logicallyComplete) {
            stripOffset = -CGFloat(delta) * pitch
        } completion: {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                _ = viewer.step(delta)
                stripOffset = 0
            }
            turning = false
        }
    }

    private func open(_ source: FeedModel.Source) {
        onOpen(source)
        dismiss()
    }

    /// Two ahead in the direction of travel and one behind, as `ViewerModel` says.
    private func prefetch() async {
        let client = services.client
        let loader = services.loader
        let urls = viewer.prefetchIDs.map { client.imageURL(id: $0, size: .view) }
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { _ = try? await loader.data(for: url) }
            }
        }
    }
}

/// A photo beside the current one in the strip: just the picture at fit size, the 1616 px one
/// when it is decoded (the viewer prefetches it), else the thumbnail. It takes no touches.
private struct ViewerNeighbour: View {
    @Environment(AppServices.self) private var services
    let photo: Photo
    let viewURL: URL
    let thumbURL: URL
    @State private var image: UIImage?
    @State private var isSharp: Bool

    init(photo: Photo, viewURL: URL, thumbURL: URL) {
        self.photo = photo
        self.viewURL = viewURL
        self.thumbURL = thumbURL
        let sharp = DecodedImageCache.shared.image(for: viewURL, maxPixel: ImagePixels.view)
        _image = State(initialValue: sharp ?? DecodedImageCache.shared.image(for: thumbURL, maxPixel: ImagePixels.thumb))
        _isSharp = State(initialValue: sharp != nil)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: photo.id) {
            guard !isSharp else { return }
            if image == nil, let thumb = await ImagePipeline.load(
                thumbURL, maxPixel: ImagePixels.thumb, loader: services.loader) {
                if !isSharp { image = thumb.image }
            }
            if let sharp = await ImagePipeline.load(viewURL, maxPixel: ImagePixels.view, loader: services.loader) {
                image = sharp.image
                isSharp = true
            }
        }
    }
}

/// An icon over a short label, for the viewer's bottom row.
private struct ViewerButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                // One size for the whole row: scaling each label to fit made the same word a
                // different size from one photo to the next, as the row gained or lost a button.
                Text(title).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
