import CullingBayCore
import SwiftUI

/// What the viewer opens on.
struct ViewerLaunch: Identifiable {
    let id = UUID()
    let photos: [Photo]
    let index: Int
}

/// One results screen: a search, a "like", a day, a person or an unnamed group. State lives in
/// `FeedModel`; this lays it out. Mirrors `renderGrid` in `gallery.js`.
///
/// `onOpen` pushes the screen a viewer button asks for (Similar, Whole day) onto whichever tab's
/// stack this is in. A person or a group puts its own header in `accessory` and turns off the title
/// (`showsHeader`); `reloadKey` loads the photos again when it changes, as when a review adds some.
///
/// `tileMenu` gives each tile a long-press menu (and the same items as VoiceOver actions); it gets
/// the photo and the feed, so an item can take the tile out of the grid. Only the person's screen
/// passes one. A grid that is selecting photos has no menu, so a long press can't get in the way of
/// Select. `selectionActions` adds a button of its own to the selection bar, before Save to phone; it
/// gets the feed, so it can act on `selectedPhotos`. Only the person's screen passes one.
@MainActor
struct ResultsView<Accessory: View>: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var feed: FeedModel
    @State private var viewer: ViewerLaunch?
    @State private var export: ExportLaunch?
    @State private var loadStart = ContinuousClock.now
    @State private var reportedReady = false
    private let onOpen: (FeedModel.Source) -> Void
    private let showsHeader: Bool
    private let reloadKey: [Int]
    private let tileMenu: ((Photo, FeedModel) -> AnyView)?
    private let selectionActions: ((FeedModel) -> AnyView)?
    private let accessory: Accessory

    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 3)]

    init(
        source: FeedModel.Source, services: AppServices, showsHeader: Bool = true, reloadKey: [Int] = [],
        tileMenu: ((Photo, FeedModel) -> AnyView)? = nil,
        selectionActions: ((FeedModel) -> AnyView)? = nil,
        onOpen: @escaping (FeedModel.Source) -> Void, @ViewBuilder accessory: () -> Accessory
    ) {
        _feed = State(initialValue: FeedModel(
            source: source, client: services.client, settings: services.settings))
        self.onOpen = onOpen
        self.showsHeader = showsHeader
        self.reloadKey = reloadKey
        self.tileMenu = tileMenu
        self.selectionActions = selectionActions
        self.accessory = accessory()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if showsHeader { header }
                accessory
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
                photos: launch.photos, index: launch.index, source: feed.source, onOpen: onOpen)
        }
        .sheet(item: $export) { launch in
            ExportSheet(launch: launch)
        }
        .sensoryFeedback(trigger: feed.selected) { _, _ in .selection }
        // A screen that failed for want of the PC loads again once the PC can be reached.
        .onChange(of: services.link.recoveries) {
            guard case .failed = feed.phase else { return }
            startTiming()
            Task { await feed.load() }
        }
        .onChange(of: reloadKey) {
            guard feed.phase != .idle else { return }
            Task { await feed.load() }
        }
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
                .modifier(TileMenu(photo: photo, feed: feed, menu: tileMenu))
            }
        }
        // A tile taken out or put back slides; a load replacing the photos doesn't.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: feed.edits)
    }

    @ToolbarContentBuilder
    private var filterButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            FilterChip(title: "★ Best", isOn: feed.best) {
                startTiming()
                let on = !feed.best
                Task { await feed.setBest(on) }
            }
            FilterChip(title: "1/burst", spoken: "1 per burst", isOn: feed.bursts) {
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
        Group {
            if selectionActions == nil {
                selectionRow(saveIsIcon: false)
            } else {
                // One more button and a long name can leave no room for every label (402 pt on an iPhone 17):
                // the controls are small, and if they still don't fit Save to phone is just its icon.
                ViewThatFits(in: .horizontal) {
                    selectionRow(saveIsIcon: false)
                    selectionRow(saveIsIcon: true)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func selectionRow(saveIsIcon: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(feed.selected.count) selected")
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button("Clear") { feed.clearSelection() }
                .buttonStyle(.bordered)
                .disabled(feed.selected.isEmpty)
            if let selectionActions { selectionActions(feed) }
            Button {
                export = services.makeExport(feed.selectedPhotos, action: .save)
            } label: {
                if saveIsIcon {
                    Image(systemName: "square.and.arrow.down")
                } else {
                    Text("Save to phone").lineLimit(1)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(feed.selected.isEmpty)
            .accessibilityLabel("Save to phone")
        }
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

extension ResultsView where Accessory == EmptyView {
    init(source: FeedModel.Source, services: AppServices, onOpen: @escaping (FeedModel.Source) -> Void) {
        self.init(source: source, services: services, onOpen: onOpen) { EmptyView() }
    }
}

/// The long-press menu of a tile, and the same items as VoiceOver actions on it. Without a `menu` the
/// tile is left as it is. While the grid is selecting there are no items, so no menu comes up.
private struct TileMenu: ViewModifier {
    let photo: Photo
    let feed: FeedModel
    let menu: ((Photo, FeedModel) -> AnyView)?

    func body(content: Content) -> some View {
        if let menu {
            content
                .contextMenu { if !feed.isSelecting { menu(photo, feed) } }
                .accessibilityActions { if !feed.isSelecting { menu(photo, feed) } }
        } else {
            content
        }
    }
}

/// A small on/off button for the toolbar.
private struct FilterChip: View {
    let title: String
    /// What VoiceOver says, when the chip is too short to spell it out.
    var spoken: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(isOn ? .bold : .regular)).lineLimit(1).fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isOn ? Color.accentColor : Color.gray)
        .accessibilityLabel(spoken ?? title)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
