import CullingBayCore
import SwiftUI

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
            if let photo = viewer.current {
                ViewerPage(
                    photo: photo, viewer: viewer, loadingHD: $loadingHD,
                    onPage: page, onClose: { dismiss() }, onTap: toggleInfo)
                    .id(photo.id)
                    .transition(.opacity)
            }
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

    private func page(_ delta: Int) {
        withAnimation(.easeOut(duration: 0.15)) { _ = viewer.step(delta) }
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

/// An icon over a short label, for the viewer's bottom row.
private struct ViewerButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
