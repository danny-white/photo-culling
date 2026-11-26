import CullingBayCore
import SwiftUI

/// The Cull tab's front page: search, In progress, On this day, then years that open into
/// months of days. Mirrors `vDays` in `app.js`. A search replaces the list with its hits.
struct CullDaysView: View {
    @Environment(AppServices.self) private var services
    @Environment(CullRouter.self) private var router
    @Environment(\.openURL) private var openURL

    private var model: CullDaysModel { services.cullDays }
    @State private var sendAll: CullSendAllLaunch?
    @State private var openingSendAll = false
    /// The row a day was opened from, so the list can come back to it (see `scrollBack`).
    @State private var openedFrom: OpenedFrom?

    private struct OpenedFrom {
        let day: String
        let section: CullDaysModel.ListSection
    }

    /// A row's place to scroll to. The same day can have a row in more than one part of the list.
    private struct RowID: Hashable {
        let section: CullDaysModel.ListSection?
        let day: String
    }

    private static let topID = "days-top"

    var body: some View {
        ScrollViewReader { proxy in
            list(proxy)
        }
    }

    private func list(_ proxy: ScrollViewProxy) -> some View {
        @Bindable var days = services.cullDays
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 0).id(Self.topID)
                // Work offline, or the taps waiting while the PC is out of reach.
                CullOfflineBanner(queue: services.cullQueue)
                if showsUnreachable {
                    UnreachableBanner(hasSavedDays: OfflinePreferences.isEnabled)
                }
                content
            }
            .padding(.horizontal, 12)
        }
        .refreshable {
            // A pull asks the PC at once whether it is there, then loads the list.
            await services.link.checkNow()
            await days.refresh()
            services.offline.sync()
        }
        .navigationTitle("Days")
        .searchable(
            text: $days.searchText, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search what, where, when")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { services.showsSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // The web version stays reachable (decision N6).
                Button { openURL(services.serverURL.appending(path: "m/")) } label: {
                    Label("Open in Safari", systemImage: "safari")
                }
            }
        }
        .task {
            await days.load()
            await scrollBack(proxy)
            if LaunchOptions.openSendAll && sendAll == nil { openSendAll() }
        }
        .sheet(item: $sendAll) { launch in
            CullSendAllView(model: launch.model, onSent: {
                await services.cullDays.refresh()
                // What was sent no longer needs keeping, which may make room for other days.
                services.offline.sync()
            })
        }
    }

    /// The PC cannot be reached (and Work offline is off): the list says so, with Try now.
    private var showsUnreachable: Bool {
        let link = services.link
        if link.isWorkingOffline { return false }
        return link.state == .unreachable || (model.isServedOffline && model.phase == .loaded && !link.isOnline)
    }

    // MARK: Coming back

    /// Back from a day, culling may have moved its row (into In progress, or out of it when the
    /// day is finished) while the list kept its old offset, so the day is off screen. Take the
    /// list to the row's new place; a row that did not move leaves the list as it was.
    private func scrollBack(_ proxy: ScrollViewProxy) async {
        guard let from = openedFrom else { return }
        openedFrom = nil
        guard !model.isShowingSearch else { return }
        // The rows are laid out after the load, so let that happen before asking for one.
        await Task.yield()
        switch model.returnTarget(for: from.day, openedFrom: from.section) {
        case .stay: break
        case .top: proxy.scrollTo(Self.topID, anchor: .top)
        case .row(let section): proxy.scrollTo(RowID(section: section, day: from.day), anchor: .center)
        }
    }

    // MARK: Send all

    /// Send to Lightroom for every day with decisions not yet sent; shown when there are some.
    @ViewBuilder
    private var sendAllRow: some View {
        let waiting = model.unsentDays
        if !waiting.isEmpty {
            Button { openSendAll() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send to Lightroom").font(.subheadline.weight(.semibold))
                        Text("\(waiting.count) day" + (waiting.count == 1 ? "" : "s") + " with decisions not sent yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if openingSendAll {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
                .background(CullStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(openingSendAll)
            .padding(.top, 8)
        }
    }

    /// Fresh counts first, so the sheet lists what is really waiting.
    private func openSendAll() {
        openingSendAll = true
        Task {
            await services.cullDays.refresh()
            let link = services.link
            sendAll = CullSendAllLaunch(model: CullSendAllModel(
                days: services.cullDays.unsentDays, client: services.client, queue: services.cullQueue,
                workingOffline: { link.isWorkingOffline }))
            openingSendAll = false
        }
    }

    // MARK: Phases

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        case .loaded:
            if model.isShowingSearch {
                searchResults
            } else {
                loaded
            }
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if let problem = model.refreshError {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        sendAllRow
        if !model.inProgress.isEmpty {
            sectionLabel("In progress")
            rows(model.inProgress, in: .inProgress)
        }
        if !model.onThisDay.isEmpty {
            sectionLabel("On this day · earlier years")
            rows(model.onThisDay, in: .onThisDay)
        }
        ForEach(model.years) { year in
            yearSection(year)
        }
        if model.inProgress.isEmpty && model.onThisDay.isEmpty && model.years.isEmpty {
            Text("No days found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    // MARK: Search

    @ViewBuilder
    private var searchResults: some View {
        let result = model.searchResult
        if model.isSearching {
            HStack(spacing: 8) {
                ProgressView()
                Text("Searching…").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
        }
        if let result {
            Group {
                Text(result.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                }
                rows(result.rows, in: nil)
            }
            // An answer to an older query stays up, dimmed, until the new one arrives.
            .opacity(model.isSearching ? 0.5 : 1)
        }
    }

    // MARK: Years, months, days

    private func yearSection(_ year: CullYear) -> some View {
        let open = model.isYearOpen(year.year)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.toggleYear(year.year) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(year.year).font(.title.weight(.heavy)).monospacedDigit()
                    Text(year.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: open ? "minus" : "plus").foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Open" : "Closed")
            Divider()
            if open {
                ForEach(year.months) { month in
                    sectionLabel(month.title)
                    rows(month.rows, in: .year(year.year))
                }
            }
        }
    }

    /// `section` is where the rows are, so the list can come back to one after its day is open;
    /// nil for a search's hits, which come back as they were.
    private func rows(_ rows: [CullDayRow], in section: CullDaysModel.ListSection?) -> some View {
        // Decisions only on the phone so far, by day: the row says so until the PC has them, and
        // its bar shows them in orange after the PC's green.
        let pending = services.cullQueue.pendingByDay
        let pendingFrames = services.cullQueue.pendingFramesByDay
        return ForEach(rows) { row in
            Button {
                openedFrom = section.map { OpenedFrom(day: row.day.day, section: $0) }
                router.open(row.day.day, match: row.match, services: services)
            } label: {
                CullDayRowView(
                    row: model.row(row, pending: pendingFrames[row.day.day] ?? []),
                    pendingTaps: pending[row.day.day] ?? 0)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            .id(RowID(section: section, day: row.day.day))
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
