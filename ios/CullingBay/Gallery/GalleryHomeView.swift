import CullingBayCore
import SwiftUI

/// The Gallery's front page: search, On this day, then years that open into months that open
/// into days. Mirrors `renderHome` in `gallery.js`.
struct GalleryHomeView: View {
    @Environment(AppServices.self) private var services
    @Environment(GalleryRouter.self) private var router
    @State private var query = ""

    private var model: HomeModel { services.home }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content(proxy)
                }
                .padding(.horizontal, 12)
            }
            .refreshable { await model.refresh() }
        }
        .navigationTitle("Gallery")
        .searchable(
            text: $query, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search what, where, when")
        .onSubmit(of: .search) { submitSearch() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { services.showsSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .task { await model.load() }
    }

    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { router.push(.search(text)) }
    }

    // MARK: Phases

    @ViewBuilder
    private func content(_ proxy: ScrollViewProxy) -> some View {
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
            loaded(proxy)
        }
    }

    @ViewBuilder
    private func loaded(_ proxy: ScrollViewProxy) -> some View {
        if let problem = model.refreshError {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        if model.index.years.count > 1 {
            yearBar(proxy)
        }
        if !model.onThisDay.isEmpty {
            onThisDay
        }
        ForEach(model.index.years) { year in
            yearSection(year)
        }
        if model.index.years.isEmpty {
            Text("No photos found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    // MARK: Year bar

    private func yearBar(_ proxy: ScrollViewProxy) -> some View {
        let largest = max(model.index.years.map(\.photoCount).max() ?? 1, 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.index.years) { year in
                    // Square root, so a small year still shows a bar.
                    let bar = max(8, 36 * (Double(year.photoCount) / Double(largest)).squareRoot())
                    Button { jump(to: year.year, proxy) } label: {
                        VStack(spacing: 3) {
                            Text(year.year).font(.subheadline.weight(.semibold)).monospacedDigit()
                            Capsule().fill(Color.accentColor).frame(width: bar, height: 3)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to \(year.year), \(GalleryFormat.photoCount(year.photoCount))")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func jump(to year: String, _ proxy: ScrollViewProxy) {
        if !model.isYearOpen(year) { model.toggleYear(year) }
        withAnimation { proxy.scrollTo("year-\(year)", anchor: .top) }
    }

    // MARK: On this day

    private var onThisDay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On this day").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.onThisDay) { item in
                        Button { router.push(.day(item.day.day)) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                RemoteImage(url: thumbURL(item.thumb))
                                    .frame(width: 140, height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(item.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 140, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Years, months, days

    private func yearSection(_ year: LibraryIndex.Year) -> some View {
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
            .id("year-\(year.year)")
            .accessibilityValue(open ? "Open" : "Closed")
            Divider()
            if open {
                ForEach(year.months) { month in
                    monthSection(month)
                }
            }
        }
    }

    private func monthSection(_ month: LibraryIndex.Month) -> some View {
        let open = model.isMonthOpen(month.key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.toggleMonth(month.key) }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(month.name).font(.headline)
                        Text(month.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: open ? "minus" : "plus").foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Open" : "Closed")
            if open {
                ForEach(month.days) { day in
                    dayRow(day)
                }
            } else {
                strip(month)
            }
        }
        .padding(.leading, 4)
    }

    /// A closed month's photos, so it can be recognised before it is opened.
    private func strip(_ month: LibraryIndex.Month) -> some View {
        let ids = month.strip
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.toggleMonth(month.key) }
        } label: {
            HStack(spacing: 3) {
                ForEach(Array(ids.enumerated()), id: \.offset) { _, id in
                    RemoteImage(url: thumbURL(id))
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                ForEach(0..<max(0, 6 - ids.count), id: \.self) { _ in
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private func dayRow(_ day: Day) -> some View {
        Button { router.push(.day(day.day)) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(GalleryFormat.longDate(day.date)).font(.subheadline.weight(.semibold))
                    Text(day.rowSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    ForEach(day.thumbs, id: \.self) { id in
                        RemoteImage(url: thumbURL(id))
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func thumbURL(_ id: Int) -> URL {
        services.client.imageURL(id: id, size: .thumb)
    }
}
