import CullingBayCore
import SwiftUI

/// The Cull tab's front page: search, In progress, On this day, then years that open into
/// months of days. Mirrors `vDays` in `app.js`. A search replaces the list with its hits.
struct CullDaysView: View {
    @Environment(AppServices.self) private var services
    @Environment(CullRouter.self) private var router
    @Environment(\.openURL) private var openURL

    private var model: CullDaysModel { services.cullDays }

    var body: some View {
        @Bindable var days = services.cullDays
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                CullOfflineBanner(queue: services.cullQueue)
                content
            }
            .padding(.horizontal, 12)
        }
        .refreshable { await days.refresh() }
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
        .task { await days.load() }
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
        if !model.inProgress.isEmpty {
            sectionLabel("In progress")
            rows(model.inProgress)
        }
        if !model.onThisDay.isEmpty {
            sectionLabel("On this day · earlier years")
            rows(model.onThisDay)
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
                rows(result.rows)
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
                    rows(month.rows)
                }
            }
        }
    }

    private func rows(_ rows: [CullDayRow]) -> some View {
        ForEach(rows) { row in
            Button { router.open(row.day.day, match: row.match, services: services) } label: {
                CullDayRowView(row: row)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
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
