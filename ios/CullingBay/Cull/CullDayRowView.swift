import CullingBayCore
import SwiftUI

/// One day in the list (`dayRow` in `app.js`): up to three thumbnails, the title, what is in it,
/// where, the day's summary or why a search found it, how far the culling has got, and a tag.
struct CullDayRowView: View {
    @Environment(AppServices.self) private var services
    let row: CullDayRow

    var body: some View {
        HStack(spacing: 12) {
            mosaic
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.subheadline.weight(.semibold))
                Text(row.meta).font(.caption).foregroundStyle(.secondary)
                if let place = row.place {
                    Text(place).font(.caption).foregroundStyle(Color.accentColor)
                }
                if let why = row.why {
                    Text(why).font(.caption).lineLimit(2)
                } else if let summary = row.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if row.showsBar {
                    ProgressView(value: Double(row.percent), total: 100)
                        .tint(.green)
                        .padding(.top, 3)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let tag = row.tag {
                CullTagView(tag: tag)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    /// The first photo tall on the left, the next two stacked beside it.
    private var mosaic: some View {
        HStack(spacing: 2) {
            if let first = row.thumbs.first {
                thumb(first)
                    .frame(width: 38, height: 60)
                if row.thumbs.count > 1 {
                    VStack(spacing: 2) {
                        ForEach(Array(row.thumbs.dropFirst()), id: \.self) { id in
                            thumb(id)
                        }
                    }
                    .frame(width: 34, height: 60)
                }
            }
        }
        .frame(minWidth: 38, minHeight: 60)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func thumb(_ id: Int) -> some View {
        RemoteImage(url: services.client.imageURL(id: id, size: .thumb))
    }
}

/// `3 conflicts`, `Synced`, `Done`, or the percent decided.
struct CullTagView: View {
    let tag: CullDayRow.Tag

    var body: some View {
        Text(tag.text)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tag.style {
        case .warn: .black
        case .quiet: .secondary
        case .normal: .white
        }
    }

    private var background: Color {
        switch tag.style {
        case .warn: .yellow
        case .quiet: Color(.tertiarySystemFill)
        case .normal: .accentColor
        }
    }
}
