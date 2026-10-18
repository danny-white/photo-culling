import CullingBayCore
import SwiftUI

/// What the viewer opens on.
struct ViewerLaunch: Identifiable {
    let id = UUID()
    let photos: [Photo]
    let index: Int
}

/// One results screen: a search, a "like", or a day. State lives in `FeedModel`; this lays it out.
/// Mirrors `renderGrid` in `gallery.js`.
@MainActor
struct ResultsView: View {
    @Environment(AppServices.self) private var services
    @Environment(GalleryRouter.self) private var router
    @State private var feed: FeedModel
    @State private var viewer: ViewerLaunch?
    @State private var export: ExportLaunch?
    @State private var loadStart = ContinuousClock.now
    @State private var reportedReady = false

    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 3)]

    init(source: FeedModel.Source, services: AppServices) {
        _feed = State(initialValue: FeedModel(
            source: source, client: services.client, settings: services.settings))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                content
            }
            .padding(.horizontal, 3)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { filterButtons }
        .safeAreaInset(edge: .bottom) {
            if feed.isSelecting { selectionBar }
        }
        .task {
            // Coming back from the viewer or a pushed screen must not reload and lose the place.
            guard feed.phase == .idle else { return }
            startTiming()
            await feed.load()
        }
        .fullScreenCover(item: $viewer) { launch in
            ViewerView(
                photos: launch.photos, index: launch.index, source: feed.source,
                onOpen: { router.push($0) })
        }
        .sheet(item: $export) { launch in
            ExportSheet(launch: launch)
        }
        .sensoryFeedback(trigger: feed.selected) { _, _ in .selection }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(feed.title).font(.title2.bold())
            if !feed.subtitle.isEmpty {
                Text(feed.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            if !feed.note.isEmpty {
                Text(feed.note).font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = feed.phase {
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try again") {
                    startTiming()
                    Task { await feed.load() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else if feed.photos.isEmpty {
            if feed.phase == .loaded {
                Text(feed.emptyMessage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                    .padding(.horizontal, 24)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(Array(feed.photos.enumerated()), id: \.element.id) { index, photo in
                Button { tapped(index, photo) } label: {
                    PhotoTile(
                        photo: photo, showsDate: feed.showsDates, isSelecting: feed.isSelecting,
                        isSelected: feed.selected.contains(photo.id),
                        onLoad: index == 0 ? { firstTileLoaded() } : nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ToolbarContentBuilder
    private var filterButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            FilterChip(title: "★ Best", isOn: feed.best) {
                startTiming()
                let on = !feed.best
                Task { await feed.setBest(on) }
            }
            FilterChip(title: "1 per burst", isOn: feed.bursts) {
                startTiming()
                let on = !feed.bursts
                Task { await feed.setBursts(on) }
            }
            Button(feed.isSelecting ? "Done" : "Select") {
                if feed.isSelecting { feed.endSelection() } else { feed.beginSelection() }
            }
            .disabled(feed.photos.isEmpty)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(feed.selected.count) selected").font(.subheadline)
            Spacer()
            Button("Clear") { feed.clearSelection() }
                .buttonStyle(.bordered)
                .disabled(feed.selected.isEmpty)
            Button("Save to phone") {
                export = services.makeExport(feed.selectedPhotos, action: .save)
            }
            .buttonStyle(.borderedProminent)
            .disabled(feed.selected.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Actions

    private func tapped(_ index: Int, _ photo: Photo) {
        if feed.isSelecting {
            feed.toggleSelect(photo.id)
        } else {
            viewer = ViewerLaunch(photos: feed.photos, index: index)
        }
    }

    // MARK: results_ready

    private func startTiming() {
        loadStart = .now
        reportedReady = false
    }

    private func firstTileLoaded() {
        guard !reportedReady else { return }
        reportedReady = true
        let ms = (ContinuousClock.now - loadStart).inMilliseconds
        let item = PerfMarks.resultsReady(ms: ms, source: feed.source, count: feed.photos.count)
        let perf = services.perf
        Task { await perf.mark(item) }
    }
}

/// A small on/off button for the toolbar.
private struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(isOn ? .bold : .regular))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isOn ? Color.accentColor : Color.gray)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
